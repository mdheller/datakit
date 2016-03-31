open Lwt.Infix
open Result

let src_9p = Logs.Src.create "9p" ~doc:"9p protocol library"
module Log9p = (val Logs.src_log src_9p)
module Server = Fs9p.Make(Log9p)(Flow_lwt_unix)

let src = Logs.Src.create "Datakit" ~doc:"Datakit 9p server"
module Log = (val Logs.src_log src : Logs.LOG)

let error fmt = Printf.ksprintf (fun s ->
    Log.err (fun l -> l  "error: %s" s);
    Error (`Msg s)
  ) fmt

let max_chunk_size = Int32.of_int (100 * 1024)

let make_task msg =
  let date = Int64.of_float (Unix.gettimeofday ()) in
  Irmin.Task.create ~date ~owner:"irmin9p" msg

let token () =
  let cookie = "datakit" in
  Lwt_unix.run (
    let open Lwt.Infix in
    Github_cookie_jar.init () >>= fun jar ->
    Github_cookie_jar.get jar ~name:cookie >|= function
    | Some t -> Github.Token.of_string t.Github_t.auth_token
    | None   ->
      Printf.eprintf "Missing cookie: use git-jar to create cookie `%s`.\n%!"
        cookie;
      exit 1
  )

let subdirs = [Vgithub.create token]

module Git_fs_store = struct
  open Irmin
  module Store =
    Irmin_git.FS(Ir_io.Sync)(Ir_io.Zlib)(Ir_io.Lock)(Ir_io.FS)
      (Contents.String)(Ref.String)(Hash.SHA1)
  type t = Store.Repo.t
  module Filesystem = I9p.Make(Store)
  let listener = lazy (Ir_io.Poll.install_dir_polling_listener 1.0)
  let connect ~bare path =
    Lazy.force listener;
    Log.debug (fun l -> l "Using Git-format store %S" path);
    let config = Irmin_git.config ~root:path ~bare () in
    Store.Repo.create config >|= fun repo ->
    fun () -> Filesystem.create make_task repo ~subdirs
end

module In_memory_store = struct
  open Irmin
  module Store = Irmin_mem.Make(Contents.String)(Ref.String)(Hash.SHA1)
  type t = Store.Repo.t
  module Filesystem = I9p.Make(Store)
  let connect () =
    Log.debug (fun l ->
        l "Using in-memory store (use --git for a disk-backed store)");
    let config = Irmin_mem.config () in
    Store.Repo.create config >|= fun repo ->
    fun () -> Filesystem.create make_task repo ~subdirs
end

let handle_flow ~make_root flow =
  Log.debug (fun l -> l "New client");
  (* Re-build the filesystem for each client because command files
     need per-client state. *)
  let root = make_root () in
  Server.accept ~root flow >|= function
  | Error (`Msg msg) ->
    Log.debug (fun l -> l "Error handling client connection: %s" msg)
  | Ok () -> ()

let default d = function
  | Some x -> x
  | None -> d

let make_unix_socket path =
  Lwt.catch
    (fun () -> Lwt_unix.unlink path)
    (function
      | Unix.Unix_error(Unix.ENOENT, _, _) -> Lwt.return ()
      | e -> Lwt.fail e)
  >>= fun () ->
  let s = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
  Lwt_unix.bind s (Lwt_unix.ADDR_UNIX path);
  Lwt.return s

let start url sandbox git ~bare =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ ->
      Log.debug (fun l -> l "Caught SIGTERM, will exit");
      exit 1
    ));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
      Log.debug (fun l -> l "Caught SIGINT, will exit");
      exit 1
    ));
  Log.app (fun l -> l "Starting com.docker.db...");
  let prefix = if sandbox then "." else "" in
  begin match git with
    | None -> In_memory_store.connect ()
    | Some path -> Git_fs_store.connect ~bare (prefix ^ path)
  end >>= fun make_root ->
  let url = url |> default "file:///var/tmp/com.docker.db.socket" in
  Lwt.catch
    (fun () ->
       let uri = Uri.of_string url in
       match Uri.scheme uri with
       | Some "file" ->
         make_unix_socket (prefix ^ Uri.path uri)
       | Some "tcp" ->
         let host = Uri.host uri |> default "127.0.0.1" in
         let port = Uri.port uri |> default 5640 in
         let addr = Lwt_unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
         let socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
         Lwt_unix.bind socket addr;
         Lwt.return socket
       | _ ->
         Printf.fprintf stderr
           "Unknown URL schema. Please use file: or tcp:\n";
         exit 1
    )
    (fun ex ->
       Printf.fprintf stderr
         "Failed to set up server socket listening on %S: %s\n%!"
         url (Printexc.to_string ex);
       exit 1
    )
  >>= fun socket ->
  Lwt_unix.listen socket 5;
  let rec aux () =
    Lwt_unix.accept socket >>= fun (client, _addr) ->
    let flow = Flow_lwt_unix.connect client in
    Lwt.async (fun () ->
        Lwt.catch
          (fun () ->handle_flow ~make_root flow)
          (fun e ->
             Log.err (fun l ->
                 l "Caught %s: closing connection" (Printexc.to_string e));
             Lwt.return ()
          )
      );
    aux () in
  Log.debug (fun l -> l "Waiting for connections on socket %S" url);
  aux ()

let start () url sandbox git bare = Lwt_main.run (start url sandbox git ~bare)

open Cmdliner

let pad n x =
  if String.length x > n then x else x ^ String.make (n - String.length x) ' '

let reporter () =
  let report src level ~over k msgf =
    let k _ = over (); k () in
    let ppf = match level with Logs.App -> Fmt.stdout | _ -> Fmt.stderr in
    let with_stamp h _tags k fmt =
      let dt = Mtime.to_us (Mtime.elapsed ()) in
      Fmt.kpf k ppf ("\r%0+04.0fus %a %a @[" ^^ fmt ^^ "@]@.")
        dt
        Fmt.(styled `Magenta string) (pad 10 @@ Logs.Src.name src)
        Logs_fmt.pp_header (level, h)
    in
    msgf @@ fun ?header ?tags fmt ->
    with_stamp header tags k fmt
  in
  { Logs.report = report }

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (reporter ());
  ()

let setup_log =
  Term.(const setup_log $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let git =
  let doc =
    Arg.info ~doc:"The path of an existing Git repository to serve" ["git"]
  in
  Arg.(value & opt (some string) None doc)

let url =
  let doc =
    Arg.info ~doc:
      "The URL to listen on of the for file:///var/tmp/foo or \
       tcp://host:port" ["url"]
  in
  Arg.(value & opt (some string) None doc)

let sandbox =
  let doc =
    Arg.info ~doc:
      "Assume we're running inside an OSX sandbox but not a chroot. \
       All paths will be manually rewritten to be relative \
       to the current directory." ["sandbox"]
  in
  Arg.(value & flag & doc)

let bare =
  let doc =
    Arg.info ~doc:"Use a bare Git repository (no working directory)" ["bare"]
  in
  Arg.(value & flag & doc)

let term =
  let doc = "A git-like database with a 9p interface." in
  let man = [
    `S "DESCRIPTION";
    `P "$(i, com.docker.db) is a Git-like database with a 9p interface.";
  ] in
  Term.(pure start $ setup_log $ url $ sandbox $ git $ bare),
  Term.info (Filename.basename Sys.argv.(0)) ~version:Version.v ~doc ~man

let () = match Term.eval term with
  | `Error _ -> exit 1
  | _        -> ()