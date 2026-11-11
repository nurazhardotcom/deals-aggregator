;;;; Development helper: load the system from this checkout.
(require :asdf)
(load (or (uiop:getenv "QUICKLISP_SETUP") "/home/nurazhar/quicklisp/setup.lisp"))
(push (uiop:pathname-directory-pathname (merge-pathnames "../" *load-truename*))
      asdf:*central-registry*)
(ql:quickload "deal-aggregator" :silent t)
(format t "~&deal-aggregator loaded~%")
