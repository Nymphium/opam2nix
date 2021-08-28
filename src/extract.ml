module JSON = Yojson.Safe
open Util
module Name = OpamPackage.Name
module Version = OpamPackage.Version
module OPAM = OpamFile.OPAM

type package_name = OpamPackage.Name.t
let package_name_of_yojson j = [%of_yojson: string] j |> Result.map OpamPackage.Name.of_string

type package_version = OpamPackage.Version.t
let package_version_of_yojson j = [%of_yojson: string] j |> Result.map OpamPackage.Version.of_string

type _package_raw = { name : string; version: string; } [@@deriving yojson]
type package = OpamPackage.t
let package_of_yojson j = _package_raw_of_yojson j |> Result.map (fun { name; version } ->
	OpamPackage.create (OpamPackage.Name.of_string name) (OpamPackage.Version.of_string version)
)

type package_set = OpamPackage.Set.t
let package_set_of_yojson = function
	| `List items ->
		List.fold_left (fun acc p ->
			Result.bind (fun acc ->
				(package_of_yojson p) |> Result.map (fun p -> p :: acc)
			) acc
		) (Ok []) items
		|> Result.map OpamPackage.Set.of_list
	| other -> Error ("Expected list of packages, got " ^ JSON.to_string other)

type repository = {
	repository_id: string [@key "id"];
	local_path: string [@key "path"];
} [@@deriving yojson]

type package_constraint = {
	c_op: string [@key "op"];
	c_value: string [@key "value"];
}

let package_constraint_of_yojson j = j
	|> [%of_yojson: string * string]
	|> Result.map (fun (c_op, c_value) -> { c_op; c_value })

type package_definition =
	| From_repository
	(* path may be either an opam file or containing directory *)
	| Direct of string
	
let package_definition_of_yojson j =
	[%of_yojson: string option] j |> Result.map (function
		| None -> From_repository
		| Some s -> Direct s
	)

type package_spec = {
	s_name: package_name [@key "name"];
	s_definition: package_definition [@key "definition"] [@default From_repository];
	constraints: package_constraint list [@default []];
} [@@deriving of_yojson]

type selected_package = {
	sel_name: package_name [@key "name"];
	sel_version: package_version [@key "version"];
	sel_definition: package_definition [@key "definition"] [@default From_repository];
} [@@deriving of_yojson]

let package_of_selected { sel_name; sel_version; _ } =
	OpamPackage.create sel_name sel_version

type selected_package_map = selected_package OpamPackage.Name.Map.t

let selected_package_map_of_yojson j = j
	|> [%of_yojson: selected_package list]
	|> Result.map (fun selected ->
		selected
		|> List.map (fun sel -> sel.sel_name, sel)
		|> OpamPackage.Name.Map.of_list
	)

type solve_ctx = {
	c_lookup_var: OpamPackage.t -> OpamVariable.Full.t -> OpamVariable.variable_contents option;
	c_constraints: OpamFormula.version_constraint option OpamPackage.Name.Map.t;
	c_repo_paths: string list;
	c_inputs: package_definition OpamPackage.Name.Map.t;
	c_packages : (Repo.lookup_result, Solver.error) result OpamPackage.Map.t ref;
}

type selection =
	| Solve of package_spec list
	| Exact of selected_package_map

type request_json = {
	rj_repositories: repository list [@key "repositories"];
	rj_spec: package_spec list option [@key "spec"][@default None];
	rj_selection: selected_package_map option [@key "selection"][@default None];
} [@@deriving of_yojson]

type request = {
	req_repositories: repository list;
	req_selection: selection;
}

type spec = {
	spec_repositories: repository list [@key "repositories"];
	spec_packages: selected_package_map [@key "packages"];
}

type buildable = {
	name: string;
	version: string;
	repository: string option;
	src: Opam_metadata.url option;
	build_commands: string list list;
	install_commands: string list list;
} [@@deriving to_yojson]

let parse_request : JSON.t -> request = fun json ->
	request_json_of_yojson json |> Result.bind (fun { rj_repositories = req_repositories; rj_spec; rj_selection } ->
		match (rj_selection, rj_spec) with
			| (None, Some spec) -> Ok { req_repositories; req_selection = Solve spec }
			| (Some selection, None) -> Ok { req_repositories; req_selection = Exact selection }
			| _other -> Error "exactly one of spec or selection required"
	) |> Result.get_exn identity

let init_variables () = Opam_metadata.init_variables ()
	(* TODO don't add this in the first place *)
	(* TODO accept k/v pairs in request *)
	|> OpamVariable.Full.Map.remove (OpamVariable.Full.global (OpamVariable.of_string "jobs"))
	
let load_direct ~name path : Repo.lookup_result =
	let opam_path = if Sys.is_directory path
		then Filename.concat path "opam"
		else path
	in
	let fallback_version () =
		(* If the path happens to be a directory named foo.1.2.3, treat that
		as the fallback version *)
		let base = Filename.basename path in
		let prefix = (Name.to_string name) ^ "." in
		let stripped = OpamStd.String.remove_prefix ~prefix base in
		Version.of_string (
			if stripped <> base then
				OpamStd.String.remove_suffix ~suffix:".opam" stripped
			else "dev"
		)
	in
	let fallback_url () = Repo.load_url (Filename.concat path "url") in
	let opam = Opam_metadata.load_opam (opam_path) in
	let version = OPAM.version_opt opam |> Option.default_fn fallback_version in
	Repo.{
		p_package = OpamPackage.create name version;
		p_rel_path = opam_path; (* it's not relative but that's OK, extract doesn't need relative paths *)
		p_opam = opam;
		p_url = OPAM.url opam |> Option.or_else_fn fallback_url;
	}

module Zi = Opam_0install
module Context : Zi.S.CONTEXT with type t = solve_ctx = struct
	open Repo
	type t = solve_ctx
	type rejection = Solver.error

	(* TODO reuse Solver.pp_rejection *)
	let pp_rejection f = function
		| `unavailable s -> Fmt.pf f "Unavailable: %s" s
		| `unsupported_archive s -> Fmt.pf f "Unsupported archive: %s" s
		
	let check_url pkg : (Opam_metadata.url option, rejection) Stdlib.result =
		pkg.p_url
			|> Option.map Opam_metadata.url
			|> Option.sequence_result

	let candidates : t -> OpamPackage.Name.t -> (OpamPackage.Version.t * (OpamFile.OPAM.t, rejection) Stdlib.result) list
	= fun ctx name ->
		let name_str = Name.to_string name in
		(* TODO is this caching actually useful? ZI probably does it *)
		let version loaded = OpamPackage.version loaded.p_package in
		match OpamPackage.Name.Map.find_opt name ctx.c_inputs with
			| Some (Direct s) ->
				let loaded = load_direct ~name s in
				[ version loaded, (Ok loaded.p_opam) ]

			| None | Some (From_repository) ->
				let seen = ref Version.Set.empty in
				ctx.c_repo_paths
					|> List.concat_map (fun repo -> Repo.lookup_package_versions repo name_str)
					|> List.filter_map (fun loaded ->
						(* Drop duplicates from multiple repos *)
						if (Version.Set.mem (version loaded) !seen) then None else (
							let opam = check_url loaded |> Result.bind (fun _ ->
								Solver.is_available ~lookup_var:(ctx.c_lookup_var) ~opam:loaded.p_opam ~package:loaded.p_package
							) |> Result.map (fun () ->
								(* only mark a package as seen if it's available *)
								seen := Version.Set.add (version loaded) !seen;
								loaded.p_opam
							) in
							Some (version loaded, opam)
						)
					)
					|> List.sort (fun (va, _) (vb, _) -> Version.compare vb va)
		
	let user_restrictions : t -> OpamPackage.Name.t -> OpamFormula.version_constraint option
	= fun ctx name -> OpamPackage.Name.Map.find name ctx.c_constraints

	let filter_deps : t -> OpamPackage.t -> OpamTypes.filtered_formula -> OpamTypes.formula
	= fun ctx pkg f ->
		f
		|> OpamFilter.partial_filter_formula (ctx.c_lookup_var pkg)
		|> OpamFilter.filter_deps ~build:true ~post:true ~test:false ~doc:false ~dev:false ~default:false
end

let solve : request -> spec = fun { req_repositories; req_selection } ->
	match req_selection with
		| Exact pmap -> { spec_repositories = req_repositories; spec_packages = pmap }
		| Solve specs ->
			Printf.eprintf "Solving ...\n";
			flush stderr;
			let module Solver = Zi.Solver.Make(Context) in

			let lookup_var package =
				Vars.(lookup_partial {
					(* TODO ocaml package ? *)
					p_packages = OpamPackage.Name.Map.empty;
					p_vars = init_variables ();
				}) (OpamPackage.name package)
			in
			let definition_map = specs
				|> List.map (fun spec -> spec.s_name, spec.s_definition)
				|> OpamPackage.Name.Map.of_list
			in
			let package_names = specs |> List.map (fun spec -> spec.s_name) in
			let ctx = {
				c_repo_paths = req_repositories |> List.map (fun r -> r.local_path);
				c_inputs = definition_map;
				c_packages = ref OpamPackage.Map.empty;
				c_constraints = OpamPackage.Name.Map.empty; (* TODO *)
				c_lookup_var = lookup_var;
			} in
			(match Solver.solve ctx package_names with
				| Error e -> (
					prerr_endline (Solver.diagnostics e);
					exit 1
				)
				| Ok solution ->
					let installed = Solver.packages_of_result solution in
					Printf.eprintf "Selected packages:\n";
					installed |> List.iter (fun pkg -> Printf.eprintf "- %s\n" (OpamPackage.to_string pkg));
					flush stderr;
					{
						spec_repositories = req_repositories;
						spec_packages = installed |>
							List.map (fun p ->
								let sel_name = OpamPackage.name p in
								let sel_definition = definition_map
									|> OpamPackage.Name.Map.find_opt sel_name
									|> Option.default From_repository
								in
								(sel_name, {
									sel_name;
									sel_version = OpamPackage.version p;
									sel_definition;
								})
							)
							|> OpamPackage.Name.Map.of_list
					}
			)

let find_impl : selected_package -> repository list -> repository option * Repo.lookup_result = fun pkg ->
	match pkg.sel_definition with
		| Direct path -> fun _ -> (None, load_direct ~name:pkg.sel_name path)
		| From_repository -> (
			let lookup : selected_package -> repository -> Repo.lookup_result option = fun pkg repo ->
				Repo.lookup repo.local_path (package_of_selected pkg)
			in
			let rec search = function
				| [] -> failwith ("Package not found in any repository: " ^ (OpamPackage.to_string (package_of_selected pkg)))
				| repository::tail -> (match lookup pkg repository with
					| Some found -> (Some repository, found)
					| None -> search tail
				)
			in search
		)
	
let buildable : selected_package_map -> selected_package -> (repository option * Repo.lookup_result) -> buildable = fun installed pkg (repo, loaded) ->
	let url = loaded.Repo.p_url
		|> Option.map Opam_metadata.url
		|> Option.map (Result.get_exn Opam_metadata.string_of_unsupported_archive)
	in
	let vars = Vars.{
		p_packages = installed |> OpamPackage.Name.Map.map package_of_selected;
		p_vars = init_variables ();
	} in
	let opam = loaded.Repo.p_opam in
	let lookup_var = Vars.lookup_partial vars pkg.sel_name in
	let resolve_commands =
		let open OpamFilter in
		let open OpamTypes in

		let arguments env (a,f) =
			if opt_eval_to_bool env f then
				let str = match a with
					| CString s -> s
					| CIdent i -> "%{"^i^"}%"
				in
				Util.debug "expanding string: %s\n" str;
				[expand_string ~partial:true env str]
			else
				[]
		in
		let command env (l, f) =
			if opt_eval_to_bool env f then
				match List.concat (List.map (arguments env) l) with
				| [] -> None
				| l  -> Some l
			else
				None
		in
		let commands env l = OpamStd.List.filter_map (command env) l in
		commands lookup_var
	in
	{
		name = OpamPackage.Name.to_string pkg.sel_name;
		version = OpamPackage.Version.to_string pkg.sel_version;
		repository = repo |> Option.map (fun repo -> repo.repository_id);
		src = url;
		build_commands =
			OpamFile.OPAM.build opam |> resolve_commands;
		install_commands =
			OpamFile.OPAM.install opam |> resolve_commands;
	}

let dump : spec -> JSON.t = fun { spec_repositories; spec_packages } ->
	let buildable = spec_packages
		|> OpamPackage.Name.Map.values
		|> List.map (fun (pkg: selected_package) -> buildable spec_packages pkg (find_impl pkg spec_repositories))
		|> List.sort (fun a b -> String.compare a.name b.name)
	in
	`Assoc (buildable |> List.map (fun buildable ->
		(buildable.name, buildable_to_yojson buildable)
	))

let run () =
	let%lwt json_s = Lwt_io.read Lwt_io.stdin in
	json_s
		|> JSON.from_string
		|> parse_request
		|> solve
		|> dump
		|> JSON.pretty_to_string
		|> Lwt_io.printf "%s\n"

let main _idx _args = Lwt_main.run (run ())
