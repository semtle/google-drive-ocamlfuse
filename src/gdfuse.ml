open GapiUtils.Infix
open GapiLens.Infix
open GapiLens.StateInfix

let default_fs_label = "default"

let client_id = "564921029129.apps.googleusercontent.com"
let redirect_uri = GaeProxy.gae_proxy_url ^ "/oauth2callback"
let scope = [GdataDocumentsV3Service.all_scopes]

(* Authorization *)
let get_authorization_url request_id =
  GapiOAuth2.authorization_code_url
    ~redirect_uri
    ~scope
    ~state:request_id
    ~response_type:"code"
    client_id

let start_browser request_id =
  let start_process browser url =
    let command = Printf.sprintf "%s \"%s\"" browser url in
    let () = Utils.log_message "Starting web browser with command: %s..."
               command in
    let ch = Unix.open_process_in command in
    let status = Unix.close_process_in ch in
      if status = (Unix.WEXITED 0) then begin
        Utils.log_message "done\n%!";
        true
      end else begin
        Utils.log_message "fail\n%!";
        false
      end
  in
  let url = get_authorization_url request_id in
  let browsers = ["xdg-open"; "firefox"; "google-chrome"] in
  let status =
    List.fold_left
      (fun result browser ->
         if result then
           result
         else
           start_process browser url)
      false
      browsers
  in
    if not status then
      failwith ("Error opening URL:" ^ url)
(* END Authorization *)

(* Setup *)
let rng =
  let open Cryptokit.Random in
  let dev_rng = device_rng "/dev/urandom" in
    string dev_rng 20 |> pseudo_rng

(* Application configuration *)
let create_default_config_store debug app_dir =
  let config =
    if debug then Config.default_debug
    else Config.default in
  (* Save configuration file *)
  let config_store = {
    Context.ConfigFileStore.path = app_dir |. AppDir.config_path;
    data = config
  }
  in
    Context.save_config_store config_store;
    config_store

let get_config_store debug app_dir =
  let config_path = app_dir |. AppDir.config_path in
    try
      Utils.log_with_header "Loading configuration from %s..." config_path;
      let config_store = Context.ConfigFileStore.load config_path in
        Utils.log_message "done\n";
        config_store
    with KeyValueStore.File_not_found ->
      Utils.log_message "not found.\n";
      create_default_config_store debug app_dir
(* END Application configuration *)

(* Application state *)
let generate_request_id () =
  Cryptokit.Random.string rng 32 |> Base64.str_encode

let create_empty_state_store app_dir =
  let request_id = generate_request_id () in
  let state = State.empty |> State.auth_request_id ^= request_id in
  let state_store = {
    Context.StateFileStore.path = app_dir |. AppDir.state_path;
    data = state
  }
  in
    Context.save_state_store state_store;
    state_store

let get_state_store app_dir =
  let state_path = app_dir |. AppDir.state_path in
    try
      Utils.log_with_header "Loading application state from %s..." state_path;
      let state_store = Context.StateFileStore.load state_path in
        Utils.log_message "done\n";
        state_store
    with KeyValueStore.File_not_found ->
      Utils.log_message "not found.\n";
      create_empty_state_store app_dir
(* END Application state *)

let setup_application debug fs_label mountpoint =
  let get_auth_tokens_from_server () =
    let context = Context.get_ctx () in
    let request_id =
      let rid = context |. Context.request_id_lens in
        if rid = "" then generate_request_id ()
        else rid
    in
      context
        |> Context.request_id_lens ^= request_id
        |> Context.save_state_from_context;
      try
        start_browser request_id;
        GaeProxy.start_server_polling ()
      with
          GaeProxy.ServerError e ->
            Utils.log_with_header "Removing invalid request_id=%s\n%!"
              request_id;
            context
              |> Context.request_id_lens ^= ""
              |> Context.save_state_from_context;
            Printf.eprintf "Cannot retrieve auth tokens: %s\n%!" e;
            exit 1
        | e ->
            prerr_endline "Cannot retrieve auth tokens.";
            Printexc.to_string e |> prerr_endline;
            exit 1
  in

  Utils.log_message "Starting application setup (label=%s).\n%!" fs_label;
  let app_dir = AppDir.create fs_label in
  let () = AppDir.create_directories app_dir in
  let app_log_path = app_dir |. AppDir.app_log_path in
  Utils.log_message "Opening log file: %s\n%!" app_log_path;
  let log_channel = open_out app_log_path in
  Utils.log_channel := log_channel;
  Utils.log_with_header "Setting up %s filesystem...\n" fs_label;
  let config_store = get_config_store debug app_dir in
  let config_store = config_store
    |> Context.ConfigFileStore.data
    ^%= Config.debug ^= debug in
  let config = config_store |. Context.ConfigFileStore.data in
  let gapi_config =
    Config.create_gapi_config
      config
      app_dir in
  Utils.log_message "Setting up cache db...";
  let cache = Cache.create_cache app_dir config in
  Cache.setup_db cache;
  Utils.log_message "done\n";
  let state_store = get_state_store app_dir in
  Utils.log_message "Setting up CURL...";
  let curl_state = GapiCurl.global_init () in
  Utils.log_message "done\n";
  let context = {
    Context.app_dir;
    config_store;
    gapi_config;
    state_store;
    cache;
    curl_state;
    mountpoint_stats = Unix.LargeFile.stat mountpoint;
    metadata = None;
  } in
  Context.set_ctx context;
  let refresh_token = context |. Context.refresh_token_lens in
    if refresh_token = "" then
      get_auth_tokens_from_server ()
    else
      Utils.log_message "Refresh token already present.\n%!"
(* END setup *)

(* FUSE bindings *)
let handle_exception e label param =
  match e with
      Docs.File_not_found ->
        Utils.log_message "File not found: %s %s\n%!" label param;
        raise (Unix.Unix_error (Unix.ENOENT, label, param))
    | Docs.Permission_denied ->
        Utils.log_message "Permission denied: %s %s\n%!" label param;
        raise (Unix.Unix_error (Unix.EACCES, label, param))
    | Docs.Resource_busy ->
        Utils.log_message "Resource busy: %s %s\n%!" label param;
        raise (Unix.Unix_error (Unix.EBUSY, label, param))
    | e ->
        Utils.log_exception e;
        raise (Unix.Unix_error (Unix.EBUSY, label, param))

let init_filesystem () =
  Utils.log_with_header "init_filesystem\n%!"

let statfs path =
  Utils.log_with_header "statfs %s\n%!" path;
  try
    Docs.statfs ()
  with e ->
    Utils.log_exception e;
    raise (Unix.Unix_error (Unix.EBUSY, "statfs", path))

let getattr path =
  Utils.log_with_header "getattr %s\n%!" path;
  try
    Docs.get_attr path
  with e -> handle_exception e "stat" path

let readdir path hnd =
  Utils.log_with_header "readdir %s %d\n%!" path hnd;
  let dir_list =
    try
      Docs.read_dir path
    with e -> handle_exception e "readdir" path
  in
    Filename.current_dir_name :: Filename.parent_dir_name :: dir_list

let fopen path flags =
  Utils.log_with_header "fopen %s %s\n%!" path (Utils.flags_to_string flags);
  try
    Docs.fopen path flags
  with e -> handle_exception e "fopen" path

let read path buf offset file_descr =
  Utils.log_with_header "read %s buf %Ld %d\n%!" path offset file_descr;
  try
    Docs.read path buf offset file_descr
  with e -> handle_exception e "read" path

let start_filesystem mountpoint fuse_args =
  if not (Sys.file_exists mountpoint && Sys.is_directory mountpoint) then
    failwith ("Mountpoint " ^ mountpoint ^ " should be an existing directory.");
  Utils.log_with_header "Starting filesystem %s\n%!" mountpoint;
  let fuse_argv =
    Sys.argv.(0) :: (fuse_args @ [mountpoint])
    |> Array.of_list
  in
    Fuse.main fuse_argv {
      Fuse.default_operations with
          Fuse.init = init_filesystem;
          statfs;
          getattr;
          readdir;
          (*
          opendir = (fun path flags -> Unix.close (Unix.openfile path flags 0);None);
          releasedir = (fun path mode hnd -> ());
          fsyncdir = (fun path ds hnd -> Printf.printf "sync dir\n%!");
          readlink = Unix.readlink;
          utime = Unix.utimes;
           *)
          fopen;
          read;
(*
          write = xmp_write;
          mknod = (fun path mode -> close (openfile path [O_CREAT;O_EXCL] mode));
          mkdir = Unix.mkdir;
          unlink = Unix.unlink;
          rmdir = Unix.rmdir;
          symlink = Unix.symlink;
          rename = Unix.rename;
          link = Unix.link;
          chmod = Unix.chmod;
          chown = Unix.chown;
          truncate = Unix.LargeFile.truncate;
          release = (fun path mode hnd -> Unix.close (retrieve_descr hnd));
          flush = (fun path hnd -> ());
          fsync = (fun path ds hnd -> Printf.printf "sync\n%!");
          listxattr = (fun path -> init_attr xattr path;lskeys (Hashtbl.find xattr path));
          getxattr = (fun path attr ->
                        with_xattr_lock (fun () ->
                                           init_attr xattr path;
                                           try
                                             Hashtbl.find (Hashtbl.find xattr path) attr
                                           with Not_found -> raise (Unix.Unix_error (EUNKNOWNERR 61 (* TODO: this is system-dependent *),"getxattr",path)))());
          setxattr = (fun path attr value flag -> (* TODO: This currently ignores flags *)
                        with_xattr_lock (fun () ->
                                           init_attr xattr path;
                                           Hashtbl.replace (Hashtbl.find xattr path) attr value) ());
          removexattr = (fun path attr ->
                           with_xattr_lock (fun () ->
                                              init_attr xattr path;
                                              Hashtbl.remove (Hashtbl.find xattr path) attr) ());
           *)
    }
(* END FUSE bindings *)

(* Main program *)
let () =
  let fs_label = ref "default" in
  let mountpoint = ref "" in
  let fuse_args = ref [] in
  let debug = ref false in
  let program = Filename.basename Sys.executable_name in
  let usage =
    Printf.sprintf
      "Usage: %s [-verbose] [-debug] [-label fslabel] [-f] [-d] [-s] mountpoint"
      program in
  let arg_specs =
    Arg.align (
      ["-verbose",
       Arg.Set Utils.verbose,
       " Enable verbose logging on stdout. Default is false.";
       "-debug",
       Arg.Unit (fun () ->
                   debug := true;
                   Utils.verbose := true;
                   fuse_args := "-f" :: !fuse_args),
       " Enable debug mode (implies -verbose, -f). Default is false.";
       "-label",
       Arg.Set_string fs_label,
       " Use a specific label to identify the filesystem. \
        Default is \"default\".";
       "-f",
       Arg.Unit (fun _ -> fuse_args := "-f" :: !fuse_args),
       " keep the process in foreground.";
       "-d",
       Arg.Unit (fun _ -> fuse_args := "-d" :: !fuse_args),
       " enable FUSE debug output (implies -f).";
       "-s",
       Arg.Unit (fun _ -> fuse_args := "-s" :: !fuse_args),
       " disable multi-threaded operation.";
      ]) in
  let () =
    Arg.parse
      arg_specs
      (fun s -> mountpoint := s)
      usage in
  let quit error_message =
    Printf.eprintf "Error: %s\n" error_message;
    exit 1
  in

    try
      if !mountpoint = "" then begin
        setup_application !debug !fs_label ".";
      end else begin
        setup_application !debug !fs_label !mountpoint;
        at_exit
          (fun () ->
             Utils.log_with_header "Exiting.\n";
             let context = Context.get_ctx () in
             Utils.log_message "CURL cleanup...";
             ignore (GapiCurl.global_cleanup context.Context.curl_state);
             Utils.log_message "done\nClearing context...";
             Context.clear_ctx ();
             Utils.log_message "done\n%!");
        start_filesystem !mountpoint !fuse_args
      end
    with
        Failure error_message -> quit error_message
      | e ->
          let error_message = Printexc.to_string e in
            quit error_message
(* END Main program *)

