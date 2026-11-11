;;;; ASDF system definition for deal-aggregator.

(asdf:defsystem "deal-aggregator"
  :version "1.0.0"
  :description "Self-hosted deals aggregator: fixed public feeds into SQLite, served as a board and a JSON API."
  :author "nurazhardotcom"
  :license "MIT"
  :depends-on ("alexandria"
               "bordeaux-threads"
               "cl-ppcre"
               "dexador"
               "hunchentoot"
               "ironclad"
               "local-time"
               "plump"
               "quri"
               "sqlite"
               "yason")
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "config")
               (:file "conditions")
               (:file "util")
               (:file "url")
               (:file "text")
               (:file "classify")
               (:file "retention")
               (:file "db")
               (:file "sources")
               (:file "fetch")
               (:module "parse"
                :serial t
                :components ((:file "feed")
                             (:file "epic")
                             (:file "linuxdo")
                             (:file "dispatch")))
               (:file "board")
               (:file "health")
               (:file "refresh")
               (:file "scheduler")
               (:file "auth")
               (:file "render")
               (:file "web")
               (:file "main"))
  :in-order-to ((asdf:test-op (asdf:test-op "deal-aggregator/tests"))))

(asdf:defsystem "deal-aggregator/tests"
  :description "FiveAM suite for deal-aggregator. Offline: fixtures only, never the real data directory."
  :depends-on ("deal-aggregator" "fiveam" "usocket")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "core-tests")
               (:file "parse-tests")
               (:file "store-tests")
               (:file "round-tests")
               (:file "web-tests"))
  :perform (asdf:test-op (op system)
             (declare (ignore op system))
             (uiop:symbol-call :deal-aggregator/tests :run-tests)))
