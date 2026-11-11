;;;; Health report for /api/health: a small status payload. Deal titles stay on
;;;; /api/deals.

(in-package #:deal-aggregator)

(defun health-report (board)
  "Serialisable status report derived from BOARD."
  (json-object
   "ok" t
   "fetchedAt" (iso-string (board-last-updated-at board))
   "fetchedAtBeijing" (board-last-updated-label board)
   "sourceHealth" (json-object "ok" (board-source-health-ok board)
                               "total" (board-source-health-total board))
   "failures" (json-array (mapcar (lambda (failure)
                                    (json-object "sourceId" (failure-source-id failure)
                                                 "sourceName" (failure-source-name failure)
                                                 "error" (failure-error failure)))
                                  (board-failures board)))
   "sources" (json-array (mapcar #'source-status->json (board-sources board)))
   "refreshInProgress" (and (board-refresh-in-progress-p board) t)
   "activeCount" (board-active-count board)
   "newCount" (board-new-count board)
   "nextRefreshAt" (iso-string (board-next-refresh-at board))
   "nextRefreshLabelBeijing" (board-next-refresh-label board)
   "freshness" (freshness->json (board-freshness board))
   "anomalies" (string-array->json (board-anomalies board))))
