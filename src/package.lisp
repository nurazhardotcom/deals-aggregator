;;;; Package definition for the whole application. One package keeps the layer
;;;; boundaries at the file level, which is enough for a program of this size.

(defpackage #:deal-aggregator
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:ppcre #:cl-ppcre))
  (:export #:main
           #:start-server
           #:stop-server
           #:start-scheduler
           #:stop-scheduler
           #:run-refresh
           #:refresh-in-progress-p
           #:board-state
           #:health-report
           #:open-store
           #:close-store
           #:canonical-url
           #:classify-title
           #:category-label
           #:category-id
           #:parse-source
           #:fetch-source
           #:stale-p
           #:expiring-soon-p
           #:parse-timestamp-ms
           #:format-beijing
           #:now-ms))
