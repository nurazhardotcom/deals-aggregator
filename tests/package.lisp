;;;; Test package: CL and FiveAM, with short nicknames for the program under
;;;; test and the socket client the web suite drives the server with.

(defpackage #:deal-aggregator/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:da #:deal-aggregator)
                    (#:ppcre #:cl-ppcre)
                    (#:us #:usocket))
  (:export #:run-tests))
