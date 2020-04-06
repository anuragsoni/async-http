open Core
open Async
open Httpaf
module Unix = Core.Unix

let write_iovecs writer iovecs =
  match Writer.is_closed writer with
  (* schedule_iovecs will throw if the writer is closed. Checking
     for the writer status here avoids that and allows to report the
     closed status to httpaf. *)
  | true -> return `Closed
  | false ->
    let iovec_queue = Queue.create ~capacity:(List.length iovecs) () in
    let total_bytes =
      List.fold iovecs ~init:0 ~f:(fun acc { Faraday.buffer; off; len } ->
          Queue.enqueue iovec_queue (Unix.IOVec.of_bigstring buffer ~pos:off ~len);
          acc + len)
    in
    Writer.schedule_iovecs writer iovec_queue;
    (* It is not safe to reuse the underlying bigstrings
       until the writer is flushed or closed. *)
    Writer.flushed writer >>| fun () -> `Ok total_bytes
;;

module Server = struct
  let default_error_handler ?request:_ error start_response =
    let message =
      match error with
      | `Exn e ->
        Logger.error !"%{sexp: Exn.t}" e;
        Status.default_reason_phrase `Internal_server_error
      | (#Status.server_error | #Status.client_error) as error ->
        Status.default_reason_phrase error
    in
    let len = Int.to_string (String.length message) in
    let headers = Headers.of_list [ "content-length", len ] in
    let body = start_response headers in
    Body.write_string body message;
    Body.close_writer body
  ;;

  let create_connection_handler
      ~request_handler
      ?config
      ?(error_handler = default_error_handler)
      addr
      reader
      writer
    =
    let request_handler = request_handler addr in
    let error_handler = error_handler in
    let read_complete = Ivar.create () in
    let write_complete = Ivar.create () in
    let conn = Server_connection.create ?config ~error_handler request_handler in
    let read_eof conn buf =
      ignore
        (Server_connection.read_eof
           conn
           (Bigstring.of_string buf)
           ~off:0
           ~len:(String.length buf)
          : int)
    in
    let rec reader_thread () =
      match Server_connection.next_read_operation conn with
      | `Read ->
        Reader.read_one_chunk_at_a_time reader ~handle_chunk:(fun buf ~pos ~len ->
            let c = Server_connection.read conn buf ~off:pos ~len in
            return (`Consumed (c, `Need_unknown)))
        >>> (function
        | `Stopped () -> assert false
        | `Eof ->
          read_eof conn "";
          reader_thread ()
        | `Eof_with_unconsumed_data buf ->
          read_eof conn buf;
          reader_thread ())
      | `Close ->
        Ivar.fill read_complete ();
        ()
      | `Yield -> Server_connection.yield_reader conn reader_thread
    in
    let rec writer_thread () =
      match Server_connection.next_write_operation conn with
      | `Write iovecs ->
        write_iovecs writer iovecs
        >>> fun result ->
        Server_connection.report_write_result conn result;
        writer_thread ()
      | `Close _ ->
        Ivar.fill write_complete ();
        ()
      | `Yield -> Server_connection.yield_writer conn writer_thread
    in
    let monitor = Monitor.create ~here:[%here] ~name:"AsyncHttpServer" () in
    Monitor.detach_and_iter_errors monitor ~f:(fun e ->
        (* TODO: verify that this doesn't cause any issues.
           In situations where the exception happens before reader is finished,
           we want to "fill" the reader ivar. We use [Async_unix.Tcp.create] which
           expects the deferred to be fulfilled to close the reader/writer pair.
        *)
        Ivar.fill_if_empty read_complete ();
        Server_connection.report_exn conn e);
    Scheduler.within ~monitor reader_thread;
    Scheduler.within ~monitor writer_thread;
    let read_write_finished =
      Deferred.all_unit [ Ivar.read write_complete; Ivar.read read_complete ]
    in
    read_write_finished
  ;;
end

module Client = struct
  let request ?config ~response_handler ~error_handler request reader writer =
    let body, conn =
      Client_connection.request ?config request ~error_handler ~response_handler
    in
    let read_eof conn buf =
      ignore
        (Client_connection.read_eof
           conn
           (Bigstring.of_string buf)
           ~off:0
           ~len:(String.length buf)
          : int)
    in
    let rec reader_thread () =
      match Client_connection.next_read_operation conn with
      | `Read ->
        Reader.read_one_chunk_at_a_time reader ~handle_chunk:(fun buf ~pos ~len ->
            let c = Client_connection.read conn buf ~off:pos ~len in
            return (`Consumed (c, `Need_unknown)))
        >>> (function
        | `Stopped () -> assert false
        | `Eof ->
          read_eof conn "";
          reader_thread ()
        | `Eof_with_unconsumed_data buf ->
          read_eof conn buf;
          reader_thread ())
      | `Close -> ()
    in
    let rec writer_thread () =
      match Client_connection.next_write_operation conn with
      | `Write iovecs ->
        write_iovecs writer iovecs
        >>> fun result ->
        Client_connection.report_write_result conn result;
        writer_thread ()
      | `Yield -> Client_connection.yield_writer conn writer_thread
      | `Close _ -> ()
    in
    let monitor = Monitor.create ~here:[%here] ~name:"AsyncHttpClient" () in
    Scheduler.within ~monitor reader_thread;
    Scheduler.within ~monitor writer_thread;
    Monitor.detach_and_iter_errors monitor ~f:(fun exn ->
        Client_connection.report_exn conn exn);
    body
  ;;
end
