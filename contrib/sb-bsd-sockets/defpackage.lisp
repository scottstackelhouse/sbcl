(defpackage "SB-BSD-SOCKETS-INTERNAL"
  (:nicknames "SOCKINT")
  (:shadow close listen)
  (:shadowing-import-from "SB-KERNEL" with-array-data)
  (:use "COMMON-LISP" "SB-ALIEN" "SB-EXT"))

(defpackage "SB-BSD-SOCKETS"
  (:export socket local-socket local-abstract-socket inet-socket inet6-socket
           make-inet-socket ; deprecated
           socket-bind socket-accept socket-connect
           socket-send socket-receive
           socket-name socket-peername socket-listen
           socket-close socket-shutdown socket-file-descriptor
           socket-family socket-protocol socket-open-p
           socket-type socket-make-stream get-protocol-by-name

           get-host-by-name get-host-by-address
           host-ent
           host-ent-address-type host-ent-addresses host-ent-address
           host-ent-aliases host-ent-name
           name-service-error
           ;; not sure if these are really good names or not
           netdb-internal-error
           netdb-success-error
           host-not-found-error
           try-again-error
           no-recovery-error

           unknown-protocol

           ;; all socket options are also exported, by code in
           ;; sockopt.lisp

           socket-error

           ;; other errno-based socket errors are exported by code in
           ;; sockets.lisp

           make-inet-address
           make-inet6-address

           non-blocking-mode)
  (:use "COMMON-LISP" "SB-BSD-SOCKETS-INTERNAL")
  (:import-from "SB-INT" "UNSUPPORTED-OPERATOR" "FEATUREP")
  (:documentation
   "A thinly-disguised BSD socket API for SBCL.  Ideas stolen from the BSD
socket API for C and Graham Barr's IO::Socket classes for Perl.

We represent sockets as CLOS objects, and rename a lot of methods and
arguments to fit Lisp style more closely."))

;;; gethostbyname/gethostbyaddr are generally not thread safe. POSIX
;;; 1003.1-2003 defines an alternative API, which is specified in the
;;; RFC to be thread-safe. If it seems to be available, use it.
;;;
;;; Unfortunately the manual page claims that these functions are not
;;; thread-safe on OS X, but they probably can't be any worse than
;;; gethostbyname and gethostbyaddr.
;;;
;;; CLH: getaddrinfo seems to be broken on x86-64/darwin
#-(or win32 (and x86-64 darwin))
(let ((addr (sb-alien::find-dynamic-foreign-symbol-address "getaddrinfo")))
  (when addr
    (pushnew :sb-bsd-sockets-addrinfo *features*)))
