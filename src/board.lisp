;;;; The board view: active deals, per-source status, freshness, anomalies and
;;;; pagination. Everything here is derived from what the last finished round
;;;; stored; a board read never touches the network.

(in-package #:deal-aggregator)

;;; ------------------------------------------------------------------
;;; View types

(defstruct (deal-dto (:constructor make-deal-dto))
  id
  url
  canonical-url
  title
  summary
  category
  category-label
  source-id
  source-name
  published-at
  expires-at
  published-label
  expires-label
  expires-soon-p
  new-p)

(defstruct (source-quality (:constructor make-source-quality))
  (consecutive-failures 0)
  count-drop-p
  structure-anomaly-p
  warning)

(defstruct (source-status (:constructor make-source-status))
  id
  name
  (active-count 0)
  last-ok
  last-error
  last-fetched
  last-inserted
  last-final-url
  quality
  diagnostic)

(defstruct (freshness (:constructor make-freshness))
  last-round-age-ms
  stale-p
  severe-p)

(defstruct (failure (:constructor make-failure))
  source-id
  source-name
  error)

(defstruct (board (:constructor %make-board))
  generated-at
  last-updated-at
  last-updated-label
  next-refresh-at
  next-refresh-label
  (source-health-ok 0)
  (source-health-total 0)
  (active-count 0)
  (new-count 0)
  refresh-in-progress-p
  round-status
  (failures '())
  (sources '())
  (deals '())
  (anomalies '())
  (freshness (make-freshness))
  (stats (make-hash-table :test #'equal))
  pagination)

;;; ------------------------------------------------------------------
;;; Derivation

(defun source-quality-for (store source-id)
  (let* ((runs (recent-source-runs store source-id :limit 8))
         (consecutive 0))
    (loop for run in runs
          while (not (source-run-ok run))
          do (incf consecutive))
    (let* ((current (first runs))
           (previous (second runs))
           (count-drop (and current previous
                            (source-run-ok current)
                            (source-run-ok previous)
                            (plusp (source-run-fetched-count previous))
                            (<= (source-run-fetched-count current)
                                (/ (source-run-fetched-count previous) 2))))
           (structure-anomaly (and current
                                   (not (source-run-ok current))
                                   (eq (run-error-kind current) :structure)))
           (warnings '()))
      (when (>= consecutive 3)
        (push (format nil "~d consecutive failures" consecutive) warnings))
      (when count-drop
        (push (format nil "item count dropped to ~d" (source-run-fetched-count current))
              warnings))
      (when structure-anomaly
        (push "parse structure anomaly" warnings))
      (make-source-quality
       :consecutive-failures consecutive
       :count-drop-p (and count-drop t)
       :structure-anomaly-p (and structure-anomaly t)
       :warning (and warnings (format nil "~{~a~^; ~}" (nreverse warnings)))))))

(defparameter +structure-error-markers+
  '("could not parse RSS/Atom"
    "response is a web page, not a feed"
    "Epic response is not JSON"
    "Epic response has no product list"
    "Epic product list is empty"
    "Epic product list structure is invalid"
    "Epic promotion structure is invalid"
    "Epic product link structure is invalid"
    "Epic product title is empty"
    "response is not the LINUX DO welfare list"
    "no items parsed from the LINUX DO Markdown")
  "Messages that mean the upstream body changed shape, not that the network failed.")

(defun structure-error-text-p (text)
  (and text
       (some (lambda (marker) (search marker text)) +structure-error-markers+)
       t))

(defun run-error-kind (run)
  (let ((error (source-run-error run)))
    (cond ((null error) nil)
          ((structure-error-text-p error) :structure)
          ((search "HTTP 429" error) :rate-limited)
          (t :http))))

(defun diagnostic-for (source status)
  (let ((error (source-status-last-error status)))
    (cond ((and error (search "circuit_open" error)) "circuit_open")
          ((and error (or (search "HTTP 429" error) (search "rate_limited" error)))
           "rate_limited")
          ((source-quality-structure-anomaly-p (source-status-quality status))
           "structure_anomaly")
          (t nil))))

(defun deal-dto-from (deal now)
  (let* ((category-id (if (stored-categories-p)
                          (category-id (deal-category deal))
                          (classify-title (deal-title deal) (deal-source-id deal)))))
    (make-deal-dto
     :id (deal-id deal)
     :url (deal-url deal)
     :canonical-url (deal-canonical-url deal)
     :title (to-plain (deal-title deal))
     :summary (to-plain (deal-summary deal))
     :category category-id
     :category-label (category-label category-id)
     :source-id (deal-source-id deal)
     :source-name (source-name (deal-source-id deal))
     :published-at (deal-published-at deal)
     :expires-at (deal-expires-at deal)
     :published-label (format-beijing (deal-published-at deal))
     :expires-label (format-beijing (deal-expires-at deal))
     :expires-soon-p (and (expiring-soon-p (deal-expires-at deal) now) t)
     :new-p nil)))

(defun board-state (store &key (now (now-ms)))
  "Build the board from stored state. Reads only; never fetches."
  (recover-dangling-rounds store now)
  (let* ((round (latest-finished-round store))
         (runs (if round (list-source-runs store (round-row-id round)) '()))
         (run-by-source (make-hash-table :test #'equal))
         (active '()))
    (dolist (run runs)
      (setf (gethash (source-run-source-id run) run-by-source) run))
    (dolist (deal (list-deals store))
      (unless (stale-p (deal-published-at deal) (deal-first-seen-at deal)
                       (deal-expires-at deal) now)
        (push deal active)))
    (setf active (nreverse active))
    (let* ((deals (mapcar (lambda (deal) (deal-dto-from deal now)) active))
           (round-id (and round (round-row-id round))))
      ;; is-new: first seen in the latest finished round.
      (dolist (deal deals)
        (let ((row (find (deal-dto-id deal) active :key #'deal-id)))
          (setf (deal-dto-new-p deal)
                (and round-id row (= (deal-first-seen-round-id row) round-id)))))
      (let ((sources
              (mapcar
               (lambda (source)
                 (let* ((run (gethash (source-id source) run-by-source))
                        (quality (source-quality-for store (source-id source)))
                        (status (make-source-status
                                 :id (source-id source)
                                 :name (source-name source)
                                 :active-count (count-if (lambda (deal)
                                                           (string= (deal-dto-source-id deal)
                                                                    (source-id source)))
                                                         deals)
                                 :last-ok (and run (source-run-ok run))
                                 :last-error (and run (source-run-error run))
                                 :last-fetched (and run (source-run-fetched-count run))
                                 :last-inserted (and run (source-run-inserted-count run))
                                 :last-final-url (and run (source-run-final-url run))
                                 :quality quality)))
                   (setf (source-status-diagnostic status) (diagnostic-for source status))
                   status))
               *sources*))
            (failures
              (loop for status in sources
                    when (eq (source-status-last-ok status) nil)
                      collect (make-failure :source-id (source-status-id status)
                                            :source-name (source-status-name status)
                                            :error (or (source-status-last-error status)
                                                       "fetch failed"))))
            (ok-count (count-if (lambda (status) (eq (source-status-last-ok status) t))
                                sources))
            (next-raw (get-meta store "next_refresh_at"))
            (next-refresh (and next-raw (ignore-errors (parse-integer next-raw))))
            (last-updated (and round (round-row-finished-at round)))
            (age (and last-updated (max 0 (- now last-updated))))
            (freshness (make-freshness
                        :last-round-age-ms age
                        :stale-p (and age (> age +stale-after-ms+))
                        :severe-p (and age (> age +severe-after-ms+))))
            (anomalies (anomalies-for store round sources freshness)))
        (let ((board (%make-board
                      :generated-at now
                      :last-updated-at last-updated
                      :last-updated-label (format-beijing last-updated)
                      :next-refresh-at next-refresh
                      :next-refresh-label (format-beijing next-refresh)
                      :source-health-ok ok-count
                      :source-health-total (length sources)
                      :active-count (length deals)
                      :new-count (count-if #'deal-dto-new-p deals)
                      :refresh-in-progress-p (refresh-in-progress-p)
                      :round-status (and round (round-row-status round))
                      :failures failures
                      :sources sources
                      :deals deals
                      :anomalies anomalies
                      :freshness freshness)))
          (setf (board-stats board) (board-stats-for deals sources))
          board)))))

(defun board-stats-for (deals sources)
  (let ((stats (make-hash-table :test #'equal))
        (categories (make-hash-table :test #'equal))
        (by-source (make-hash-table :test #'equal))
        (expiring 0))
    (dolist (deal deals)
      (incf (gethash (symbol-name (deal-dto-category deal)) categories 0))
      (incf (gethash (deal-dto-source-id deal) by-source 0))
      (when (deal-dto-expires-soon-p deal) (incf expiring)))
    (setf (gethash "active" stats) (length deals)
          (gethash "categories" stats) categories
          (gethash "sources" stats) by-source
          (gethash "expiringSoon" stats) expiring
          (gethash "sourceCount" stats) (length sources))
    stats))

(defun anomalies-for (store round sources freshness)
  (let ((messages '()))
    (cond ((null round)
           (push "no fetch round has finished yet; this list is not current" messages))
          ((freshness-severe-p freshness)
           (push "the last finished round is over 4 hours old" messages))
          ((freshness-stale-p freshness)
           (push "the last finished round is over 2.5 hours old" messages)))
    (when (and round (string= (round-row-status round) "failed"))
      (push "every source failed in the last round" messages))
    (let* ((previous (if round (previous-source-runs store (round-row-id round)) '()))
           (previous-by-source (make-hash-table :test #'equal)))
      (dolist (run previous)
        (setf (gethash (source-run-source-id run) previous-by-source) run))
      (dolist (status sources)
        (let ((before (gethash (source-status-id status) previous-by-source)))
          (when (and before
                     (eq (source-status-last-ok status) t)
                     (plusp (source-run-fetched-count before))
                     (source-status-last-fetched status))
            (let ((drop (/ (- (source-run-fetched-count before)
                              (source-status-last-fetched status))
                           (source-run-fetched-count before))))
              (when (>= drop 0.5)
                (push (format nil "~a dropped from ~d to ~d items"
                              (source-status-name status)
                              (source-run-fetched-count before)
                              (source-status-last-fetched status))
                      messages))))
          (when (and (eq (source-status-last-ok status) t)
                     (eql 0 (source-status-last-fetched status)))
            (push (format nil "~a succeeded with 0 items" (source-status-name status))
                  messages))
          (let ((quality (source-status-quality status)))
            (when (>= (source-quality-consecutive-failures quality) 3)
              (push (format nil "~a failed ~d rounds in a row"
                            (source-status-name status)
                            (source-quality-consecutive-failures quality))
                    messages))
            (when (source-quality-structure-anomaly-p quality)
                (push (format nil "~a parse structure anomaly" (source-status-name status))
                      messages)))))
      (nreverse messages))))

;;; ------------------------------------------------------------------
;;; Filtering and pagination

(defun board-deal-matches-p (deal filters)
  (let ((query (string-downcase (or (getf filters :query) "")))
        (source (or (getf filters :source) "all"))
        (category (or (getf filters :category) "all")))
    (and (or (string= source "all")
             (string= source (deal-dto-source-id deal)))
         (or (string= category "all")
             (eq (category-id category) (deal-dto-category deal)))
         (or (zerop (length query))
             (search query (string-downcase (deal-dto-title deal)))
             (search query (string-downcase (deal-dto-summary deal)))))))

(defun filter-board-deals (deals filters)
  (let ((kept (remove-if-not (lambda (deal) (board-deal-matches-p deal filters)) deals)))
    (ecase (or (getf filters :sort) :newest)
      (:newest kept)
      (:expiring (stable-sort (copy-list kept)
                              (lambda (a b)
                                (let ((ea (deal-dto-expires-at a))
                                      (eb (deal-dto-expires-at b)))
                                  (cond ((and ea eb) (< ea eb))
                                        (ea t)
                                        (eb nil)
                                        (t nil)))))))))

(defun paginate-board (board &key (offset 0) (limit +board-page-size+))
  "Replace the deal list with the requested window and record the pagination meta."
  (unless (and (integerp offset) (>= offset 0)
               (integerp limit) (>= limit 1) (<= limit 2000))
    (error 'invalid-pagination))
  (let* ((deals (board-deals board))
         (total (length deals))
         (start (min offset total))
         (end (min total (+ start limit))))
    (setf (board-pagination board)
          (json-object "offset" offset
                       "limit" limit
                       "total" total
                       "hasMore" (< end total)))
    (setf (board-deals board) (subseq deals start end))
    board))

;;; ------------------------------------------------------------------
;;; JSON serialisation

(defun deal-dto->json (deal)
  (json-object "id" (deal-dto-id deal)
               "url" (deal-dto-url deal)
               "canonicalUrl" (deal-dto-canonical-url deal)
               "title" (deal-dto-title deal)
               "summary" (deal-dto-summary deal)
               "category" (string-downcase (symbol-name (deal-dto-category deal)))
               "categoryLabel" (deal-dto-category-label deal)
               "sourceId" (deal-dto-source-id deal)
               "sourceName" (deal-dto-source-name deal)
               "publishedAt" (deal-dto-published-at deal)
               "expiresAt" (deal-dto-expires-at deal)
               "publishedLabel" (deal-dto-published-label deal)
               "expiresLabel" (deal-dto-expires-label deal)
               "expiresSoon" (and (deal-dto-expires-soon-p deal) t)
               "isNew" (and (deal-dto-new-p deal) t)))

(defun source-quality->json (quality)
  (json-object "consecutiveFailures" (source-quality-consecutive-failures quality)
               "countDrop" (and (source-quality-count-drop-p quality) t)
               "structureAnomaly" (and (source-quality-structure-anomaly-p quality) t)
               "warning" (source-quality-warning quality)))

(defun source-status->json (status)
  (json-object "id" (source-status-id status)
               "name" (source-status-name status)
               "activeCount" (source-status-active-count status)
               "lastOk" (source-status-last-ok status)
               "lastError" (source-status-last-error status)
               "lastFetched" (source-status-last-fetched status)
               "lastInserted" (source-status-last-inserted status)
               "lastFinalUrl" (source-status-last-final-url status)
               "quality" (source-quality->json (source-status-quality status))
               "diagnostic" (source-status-diagnostic status)))

(defun freshness->json (freshness)
  (json-object "lastRoundAgeMs" (freshness-last-round-age-ms freshness)
               "stale" (and (freshness-stale-p freshness) t)
               "severe" (and (freshness-severe-p freshness) t)))

(defun string-array->json (strings)
  (json-array (mapcar #'identity strings)))

(defun board->json (board)
  "BoardState plus pagination, ready for yason."
  (json-object
   "generatedAt" (board-generated-at board)
   "lastUpdatedAt" (board-last-updated-at board)
   "lastUpdatedLabel" (board-last-updated-label board)
   "nextRefreshAt" (board-next-refresh-at board)
   "nextRefreshLabel" (board-next-refresh-label board)
   "sourceHealth" (json-object "ok" (board-source-health-ok board)
                               "total" (board-source-health-total board))
   "activeCount" (board-active-count board)
   "newCount" (board-new-count board)
   "refreshInProgress" (and (board-refresh-in-progress-p board) t)
   "roundStatus" (board-round-status board)
   "failures" (json-array (mapcar (lambda (failure)
                                    (json-object "sourceId" (failure-source-id failure)
                                                 "sourceName" (failure-source-name failure)
                                                 "error" (failure-error failure)))
                                  (board-failures board)))
   "sources" (json-array (mapcar #'source-status->json (board-sources board)))
   "deals" (json-array (mapcar #'deal-dto->json (board-deals board)))
   "freshness" (freshness->json (board-freshness board))
   "anomalies" (string-array->json (board-anomalies board))
   "stats" (board-stats board)
   "pagination" (or (board-pagination board)
                    (json-object "offset" 0 "limit" (length (board-deals board))
                                 "total" (length (board-deals board))
                                 "hasMore" nil))))
