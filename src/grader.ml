type cfg = {
  cfg_sf_path : string option
}

type options = {
  sf_path : string;
  submission : string;
  result_dir : string
}

let (/) = Filename.concat

let workdir = ".sf-grader.tmp"

let cfg =
  let cfg_path = Sys.getenv "HOME" / ".sf-grader" in
  let pairs = Hashtbl.create 10 in
  let re = Str.regexp "\\([^ =]*\\) *= *\\([^ =]*\\)" in
  begin
    try
      let ic = open_in cfg_path in
      let rec read () =
        try
          let line = input_line ic in
          if Str.string_match re line 0 then
            let name = Str.matched_group 1 line in
            let value = Str.matched_group 2 line in
            Hashtbl.add pairs name value
          else
            Printf.printf "Just read line %s" line;
          read ()
        with End_of_file -> close_in ic in
      read ();
    with Sys_error _ ->
    (* File probably doesn't exist; simply leave option table empty *)
      ()
  end;
  let cfg_sf_path =
    try Some (Hashtbl.find pairs "sf-path")
    with Not_found -> None in
  { cfg_sf_path = cfg_sf_path }

let usage () : 'a =
  List.iter print_endline [
    "USAGE: grader [OPTIONS] SUBMISSION";
    "Grade submissions of Software Foundations exercises";
    "";
    "OPTIONS";
    "  --sf-path - The path to the Software Foundations sources";
    "  -o        - Where to output grading results (default: submissions)";
  ];
  exit 0

let read_options () : options =
  let sf_path = ref None in
  let submission = ref None in
  let result_dir = ref None in
  let read_option o r args =
    match args with
    | v :: args ->
      if !r <> None then begin
        Printf.printf "Error: option %s given multiple times\n\n" o;
        usage ()
      end else begin
        r := Some v;
        args
      end
    | [] ->
      Printf.printf "Error: option %s requires an argument\n\n" o;
      usage () in
  let rec process args =
    begin match args with
    | "--help" :: _ -> usage ()
    | "--sf-path" :: args -> process @@ read_option "--sf-path" sf_path args
    | "-o" :: args -> process @@ read_option "-o" result_dir args
    | path :: args ->
      if !submission == None then
        (submission := Some path;
         process args)
      else usage ()
    | [] -> ()
    end in
  let args = Array.to_list Sys.argv in
  process @@ List.tl args;
  let sf_path =
    match !sf_path, cfg.cfg_sf_path with
    | Some sf_path, _
    | None, Some sf_path -> sf_path
    | _, _ ->
      Printf.printf "Error: Don't know where to find SF files.\n\n";
      usage () in
  let submission =
    match !submission with
    | Some submission -> submission
    | _ ->
      Printf.printf "Error: No submission file given.\n\n";
      usage () in
  { result_dir =
      begin match !result_dir with
      | Some rf -> rf
      | None -> "submissions"
      end;
    sf_path = sf_path; submission = submission }

let o = read_options ()

let translate_file_name name =
  let file_format = Str.regexp "\\([^-]*\\)--\\([^_]*\\)_[^_]*_[^_]*_\\(.*\\)" in
  if not @@ Str.string_match file_format name 0 then
    failwith @@ Printf.sprintf "Don't know what to do with file %s" name;
  let last_name = Str.matched_group 1 name in
  let first_name = Str.matched_group 2 name in
  let file_name = Str.matched_group 3 name in
  let first_name =
    (* Strip "-late" prefix, if present *)
    if Str.string_match (Str.regexp "\\(.*\\)-late$") first_name 0 then begin
      Str.matched_group 1 first_name
    end
    else first_name in
  (Printf.sprintf "%s-%s" last_name first_name, file_name)

let ensure_dir_exists dir =
  if not @@ Sys.file_exists dir then Unix.mkdir dir 0o744

let cp source dest =
  ignore @@ Sys.command @@ Printf.sprintf "cp %s %s" source dest

let plugin_loader_com = "Declare ML Module \"graderplugin\".\n"

let grade_sub path : unit =
  let assignment = Filename.chop_extension @@ Filename.basename path in
  let ass_copy = workdir / "Submission.v" in
  cp path ass_copy;
  print_string path;
  let res = Sys.command @@ Printf.sprintf "coqc -I %s %s > %s.out 2>&1" o.sf_path ass_copy path in
  if res <> 0 then
    print_endline " compilation error"
  else begin
    print_endline " ok";
    let env = Array.append [|"SFGRADERRESULT=" ^ path ^ ".res";
                             "SFGRADERSFPATH=" ^ o.sf_path;
                             "SFGRADERASSIGNMENT=" ^ assignment |] @@
      Unix.environment () in
    let coqcom =
      Printf.sprintf
        "coqtop -I %s -I %s -I src -require %s -require Submission > .sf-grader.out 2>&1"
        o.sf_path workdir assignment in
    let proc = Unix.open_process_full coqcom env in
    let input, output, _ = proc in
    output_string output plugin_loader_com;
    flush output
  end

let grade_subs path =
  let com = Printf.sprintf "unzip -qq %s -d %s" path workdir in
  ignore @@ Sys.command com;
  let files = Sys.readdir workdir in
  ensure_dir_exists o.result_dir;
  Array.iter (fun file ->
    let name, file' = translate_file_name file in
    let dir = o.result_dir / name in
    let path = dir / file' in
    ensure_dir_exists dir;
    cp (workdir/file) path;
    grade_sub path
  ) files

let _ =
  if Sys.file_exists workdir then Sys.remove workdir;
  Unix.mkdir workdir 0o744;
  if Filename.check_suffix o.submission ".zip" then
    grade_subs o.submission
  else if Filename.check_suffix o.submission ".v" then
    grade_sub o.submission
  else
    Printf.printf "Don't know what to do with file %s\n" o.submission;
    exit 1
