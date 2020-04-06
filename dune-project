(lang dune 1.11)

(name async-http)

(generate_opam_files true)

(source
 (uri "git+https://gitlab.com/anuragsoni/async-http.git"))

(bug_reports "https://gitlab.com/anuragsoni/async-http/issues")

(homepage "https://gitlab.com/anuragsoni/async-http.git")

(authors "Anurag Soni <anurag@sonianurag.com>")

(maintainers "Anurag Soni <anurag@sonianurag.com>")

(license MIT)

(package
 (name async-connection)
 (synopsis "Async connections")
 (depends
  (ocaml
   (>= 4.06.1))
  (dune
   (>= 1.11))
  (core
   (>= 0.11))
  (async
   (>= 0.11))
  (ppx_jane
   (>= 0.11))
  (async_ssl
   (>= 0.11))))

(package
 (name async-http)
 (synopsis "Async web toolkit")
 (tags
  (http-server http-client http async ocaml))
 (depends
  (ocaml
   (>= 4.06.1))
  (dune
   (>= 1.11))
  (core
   (>= 0.11))
  (async
   (>= 0.11))
  ppx_jane
  httpaf
  faraday
  magic-mime
  (async_ssl
   (>= 0.11))
  uri))
