open Core
open Async

module Headers : sig
  type t [@@deriving sexp]
  (** Headers are a collection of key,value pairs where
      both key and values are strings. One difference compared to
      a regular [String.Map.t] is that all comparison operations
      on the key are case-insensitive. *)

  val empty : t
  (** [empty] Creates an empty collection of headers. *)

  val of_list : (string * string) list -> t
  (** [of_list] converts an association list to a collection of headers.
      The original case for the header key will be preserved, but internally
      any further comparisons will be case-insensitive. *)

  val add : string -> string -> t -> t
  (** [add k v t] returns a new header collection containing the same
      items as the original, plus a new key/value pair from [k] to [v].
      If [k] already existed in the collection, the updated entry in the headers
      will associate [k] with a list containing the existing values in addition to [v]. *)

  val exists : string -> t -> bool
  (** [exists k t] = true if there is a header with key equal to k. *)

  val get : string -> t -> string list
  (** [get k t] returns the list of values associated the input header key. *)

  val add_if_missing : string -> string -> t -> t
  (** [add_if_missing] only adds a value to the header collection if the key
      doesn't already exist. Otherwise this results in a no-op. *)

  val remove : string -> t -> t
  (** [remove k t] returns a new header collection with the key k removed. *)

  val pp : Format.formatter -> t -> unit
  val pp_hum : Format.formatter -> t -> unit [@@ocaml.toplevel_printer]
end

module Body : sig
  type t [@@deriving sexp_of]
  (** The body type is constructed as a wrapper around a value that's either
      a fixed lenth encoded string style body, or a streaming body that is
      represented as [Async_kernel.Pipe.t]. Some basic converters are provided
      that allow creating bodies from strings/bigstrings/pipes etc, and convert
      a body to an Async pipe which the user can then consume by using all
      async operations that are already available on a Pipe. *)

  val length : t -> Int64.t option
  (** [length t] returns the length of the body if known. If the body was
      created via a fixed length encoded HTTP body then the length is known.
      But when dealing with chunk encoded bodies, if the headers don't
      contain information about the actual length, then our body type
      will still be able to parse the entire content, but it won't store
      the length. *)

  val drain : t -> unit Deferred.t
  (** [drain t] will repeatedly read values from the body pipe
      and discard them. *)

  val to_string : t -> string Deferred.t
  (** [to_string t] returns a deferred value that will eventually be fulfilled to a
      string representation of the body. If dealing with streaming bodies,
      be careful when using this, as the deferred will not be fulfilled until the entire
      body is available. It is recommended to use the pipe operations [to_pipe]
      so one can start consuming content incrementally using the functionality
      available in [Async_kernel.Pipe]. *)

  val to_pipe : t -> string Pipe.Reader.t
  (** [to_pipe t] converts the body into an async pipe. *)

  val empty : t
  (** [empty] represents the empty body of size 0L. *)

  val of_string : string -> t
  (** [of_string] creates a fixed length body from a string. *)

  val of_bigstring : Bigstring.t -> t
  (** [of_bigstring] creates a fixed length body from a bigstring. *)

  val of_pipe : ?length:Int64.t -> string Pipe.Reader.t -> t
  (** [of_pipe] takes a string pipe and uses that to create a streaming body.
      If length is provided, the value will be used to create the content-length header. *)
end

module Request : sig
  type t = private
    { target : string
    ; state : Univ_map.t
    ; headers : Headers.t
    ; body : Body.t
    ; meth : Httpaf.Method.t
    }
  [@@deriving sexp_of, fields]
  (** A request consists of a [string] target url, a collection of headers,
      a request body that can be empty and the HTTP verb that was requested.
      In addition to that there is a [state] that is represented as a
      heterogenous value map. The state can be useful when writing "middlewares",
      with the idea that a middleware can stash items in there to forward something
      down the chain of middlewares. The middleware creating the entry can encapsulate
      the key to the state, so any consumer will have to access it via the public API
      and ensure that even though different parts of the request lifecycle
      could potentially access entries (in a type safe manner), they won't be able
      to modify/mess with a middleware's data. *)

  val make : ?headers:Headers.t -> ?body:Body.t -> Httpaf.Method.t -> string -> t
end

module Response : sig
  type t = private
    { status : Httpaf.Status.t
    ; headers : Headers.t
    ; body : Body.t
    ; state : Univ_map.t
    }
  [@@deriving sexp_of, fields]
  (** Similar to [Request] the response contains a state represented as
      a heterogenous value map. In addition to that there is a response body,
      a HTTP status and the response headers. When creating response bodies
      if the Content-type header isn't provided, the library will attempt
      to create one if the length of the body can be determined. *)

  val of_file
    :  ?headers:Headers.t
    -> ?status:Httpaf.Status.t
    -> string
    -> t Deferred.t
  (** [of_file] expects a fully qualified path to a file. Its contents are then
      read and a streaming response is created that is used to create the response.
      The library will attempt to populate the correct content-type headers by using
      the file extension to create a MIME type. In addition to this, [of_file]
      will verify if the input name is indeed a file before attempting to create
      a response. *)

  val create : ?headers:Headers.t -> ?status:Httpaf.Status.t -> Body.t -> t Deferred.t
end

module Service : sig
  type t = Request.t -> Response.t Deferred.t
end

module Server : sig
  type error_handler =
    Headers.t -> Httpaf.Server_connection.error -> (Headers.t * Body.t) Deferred.t
  (** [error_handler] is used to handle any exceptions that occur during the lifecycle
      of a http request handler. There is a default error_handler that will be used
      if the user doesn't provide one, but users are encouraged to provide an error handler
      if they'd like to customize the error response body. *)

  val create_connection_handler
    :  ?error_handler:error_handler
    -> Service.t
    -> ?config:Httpaf.Config.t
    -> 'a
    -> Reader.t
    -> Writer.t
    -> unit Deferred.t
  (** [create_connection_handler] accepts a [Service.t]
      and converts that into a handler that can then be forwarded
      as the callback for [Async_connection.Server.create] or
      [Async.Tcp.Server.create] *)
end

module Client : sig
  val request
    :  ?ssl_options:Async_connection.Client.ssl_options
    -> ?headers:Headers.t
    -> ?body:Body.t
    -> Httpaf.Method.standard
    -> Uri.t
    -> Response.t Deferred.Or_error.t
  (** [request] can be used to create a HTTP client call. The uri
      is used to decide whether to make a regular tcp connection
      or an encrypted connection using async_ssl. *)

  val head
    :  ?ssl_options:Async_connection.Client.ssl_options
    -> ?headers:Headers.t
    -> Uri.t
    -> Response.t Deferred.Or_error.t

  val get
    :  ?ssl_options:Async_connection.Client.ssl_options
    -> ?headers:Headers.t
    -> Uri.t
    -> Response.t Deferred.Or_error.t

  val delete
    :  ?ssl_options:Async_connection.Client.ssl_options
    -> ?headers:Headers.t
    -> ?body:Body.t
    -> Uri.t
    -> Response.t Deferred.Or_error.t

  val post
    :  ?ssl_options:Async_connection.Client.ssl_options
    -> ?headers:Headers.t
    -> ?body:Body.t
    -> Uri.t
    -> Response.t Deferred.Or_error.t

  val put
    :  ?ssl_options:Async_connection.Client.ssl_options
    -> ?headers:Headers.t
    -> ?body:Body.t
    -> Uri.t
    -> Response.t Deferred.Or_error.t
end
