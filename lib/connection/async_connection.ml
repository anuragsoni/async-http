open Core
open Async
open Async_ssl

let log_src = Logs.Src.create "async_connection"

module Logger = (val Logs.src_log log_src : Logs.LOG)

module Server = struct
  let create_ssl handler ~crt_file ~key_file r w =
    let net_to_ssl = Reader.pipe r in
    let ssl_to_net = Writer.pipe w in
    let app_to_ssl, app_writer = Pipe.create () in
    let app_reader, ssl_to_app = Pipe.create () in
    match%bind
      Ssl.server ~crt_file ~key_file ~net_to_ssl ~ssl_to_net ~ssl_to_app ~app_to_ssl ()
    with
    | Error e ->
      Logger.err (fun m -> m !"%{sexp: Error.t}" e);
      return ()
    | Ok conn ->
      let%bind reader =
        Reader.of_pipe (Info.of_string "async_connection.ssl.reader") app_reader
      in
      let%bind writer, `Closed_and_flushed_downstream flush =
        Writer.of_pipe (Info.of_string "async_connection.ssl.writer") app_writer
      in
      let shutdown () =
        let%bind () = Writer.close writer in
        let%bind () = flush in
        (* [Ssl.Connection.close] will cleanup and shutdown all the pipes
           provided to [Ssl.server]. *)
        Ssl.Connection.close conn;
        let%bind () =
          match%map Ssl.Connection.closed conn with
          | Ok _ -> ()
          | Error e -> Logger.err (fun m -> m !"%{sexp: Error.t}" e)
        in
        Reader.close reader
      in
      Monitor.protect
        ~here:[%here]
        ~name:"async_connection.ssl.server"
        ~finally:shutdown
        (fun () -> handler reader writer)
  ;;

  let create
      ?crt_file
      ?key_file
      ?buffer_age_limit
      ?max_connections
      ?max_accepts_per_batch
      ?backlog
      ?socket
      ~on_handler_error
      where_to_listen
      handle_client
    =
    Tcp.Server.create
      ?buffer_age_limit
      ?max_connections
      ?max_accepts_per_batch
      ?backlog
      ?socket
      ~on_handler_error
      where_to_listen
      (fun addr r w ->
        match crt_file, key_file with
        | Some crt_file, Some key_file ->
          create_ssl (handle_client addr) ~crt_file ~key_file r w
        | _ -> handle_client addr r w)
  ;;
end

module Client = struct
  type ssl_options =
    { version : Version.t option
    ; options : Opt.t list option
    ; name : string option
    ; hostname : string option
    ; allowed_ciphers : [ `Only of string list | `Openssl_default | `Secure ] option
    ; ca_file : string option
    ; ca_path : string option
    ; crt_file : string option
    ; key_file : string option
    ; verify_modes : Verify_mode.t list option
    ; session : (Ssl.Session.t[@sexp.opaque]) option
    ; verify_peer : Ssl.Connection.t -> unit Or_error.t
    }
  [@@deriving sexp_of, fields]

  let create_ssl_options
      ?version
      ?options
      ?name
      ?hostname
      ?allowed_ciphers
      ?ca_file
      ?ca_path
      ?crt_file
      ?key_file
      ?verify_modes
      ?session
      ?(verify_peer = fun _ -> Or_error.return ())
      ()
    =
    { version
    ; options
    ; name
    ; hostname
    ; allowed_ciphers
    ; ca_file
    ; ca_path
    ; crt_file
    ; key_file
    ; verify_modes
    ; session
    ; verify_peer
    }
  ;;

  type mode =
    | Secure of ssl_options
    | Regular
  [@@deriving sexp_of]

  let ssl_connect opts handler r w =
    let net_to_ssl = Reader.pipe r in
    let ssl_to_net = Writer.pipe w in
    let app_to_ssl, app_writer = Pipe.create () in
    let app_reader, ssl_to_app = Pipe.create () in
    match%bind
      Ssl.client
        ?version:opts.version
        ?options:opts.options
        ?name:opts.name
        ?hostname:opts.hostname
        ?allowed_ciphers:opts.allowed_ciphers
        ?ca_file:opts.ca_file
        ?ca_path:opts.ca_path
        ?crt_file:opts.crt_file
        ?key_file:opts.key_file
        ?verify_modes:opts.verify_modes
        ?session:opts.session
        ~app_to_ssl
        ~ssl_to_app
        ~net_to_ssl
        ~ssl_to_net
        ()
    with
    | Error err -> Error.raise err
    | Ok conn ->
      let () = opts.verify_peer conn |> Or_error.ok_exn in
      let%bind reader =
        Reader.of_pipe (Info.of_string "async_connection.ssl.client.reader") app_reader
      in
      let%bind writer, `Closed_and_flushed_downstream flush =
        Writer.of_pipe (Info.of_string "async_connection.ssl.client.writer") app_writer
      in
      let shutdown () =
        let%bind () = Writer.close writer in
        let%bind () = flush in
        (* [Ssl.Connection.close] will cleanup and shutdown all the pipes
           provided to [Ssl.server]. *)
        Ssl.Connection.close conn;
        let%bind () =
          match%map Ssl.Connection.closed conn with
          | Ok _ -> ()
          | Error e -> Logger.err (fun m -> m !"%{sexp: Error.t}" e)
        in
        Reader.close reader
      in
      Monitor.protect
        ~here:[%here]
        ~name:"async_connection.ssl.client"
        ~finally:shutdown
        (fun () -> handler reader writer)
  ;;

  let with_connection
      mode
      ?buffer_age_limit
      ?interrupt
      ?reader_buffer_size
      ?writer_buffer_size
      ?timeout
      where_to_connect
      handler
    =
    Tcp.with_connection
      ?buffer_age_limit
      ?interrupt
      ?reader_buffer_size
      ?writer_buffer_size
      ?timeout
      where_to_connect
      (fun addr reader writer ->
        match mode with
        | Regular -> handler addr reader writer
        | Secure opts -> ssl_connect opts (handler addr) reader writer)
  ;;
end
