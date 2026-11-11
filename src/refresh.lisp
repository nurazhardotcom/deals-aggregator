;;;; One refresh round: fetch every source, store what survived normalisation,
;;;; record per-source outcomes, sweep retention, return the new board.
;;;;
;;;; A source that fails never changes the rows it stored previously. Epic is
;;;; reconciled only after a successful parse, so games that stopped being free
;;;; disappear while the endpoint is broken they do not.

(in-package #:deal-aggregator)

(defstruct (source-result (:constructor make-source-result))
  source-id
  ok
  (items '())
  (inserted-count 0)
  final-url
  error
  started-at
  finished-at)

(defvar *refresh-lock* (bt:make-lock "deal-aggregator.refresh"))
(defvar *refresh-running* nil)

(defun refresh-in-progress-p ()
  (bt:with-lock-held (*refresh-lock*) (and *refresh-running* t)))

(defun call-with-refresh-slot (function)
  "Run FUNCTION while holding the in-process refresh slot, or signal REFRESH-BUSY."
  (bt:with-lock-held (*refresh-lock*)
    (when *refresh-running*
      (error 'refresh-busy :message "a refresh round is already running"))
    (setf *refresh-running* t))
  (unwind-protect
       (funcall function)
    (bt:with-lock-held (*refresh-lock*)
      (setf *refresh-running* nil))))

(defun load-source-result (source now)
  "Fetch and parse one source. Never signals: failures become a result value."
  (let ((started (now-ms)))
    (handler-case
        (multiple-value-bind (body final-url) (fetch-source source)
          (let ((items (parse-source source body now)))
            (make-source-result :source-id (source-id source)
                                :ok t
                                :items items
                                :final-url final-url
                                :started-at started
                                :finished-at (now-ms))))
      (serious-condition (condition)
        (log-failure "source_failed" condition
                     :source (source-id source))
        (make-source-result :source-id (source-id source)
                            :ok nil
                            :error (princ-to-string condition)
                            :started-at started
                            :finished-at (now-ms))))))

(defun fetch-all-sources (sources now)
  "Fetch every source concurrently. Each has its own timeout."
  (let* ((count (length sources))
         (results (make-array count :initial-element nil))
         (threads
           (loop for source in sources
                 for index from 0
                 collect (let ((source source) (index index))
                           (bt:make-thread
                            (lambda ()
                              (setf (aref results index) (load-source-result source now)))
                            :name (format nil "fetch-~a" (source-id source)))))))
    (dolist (thread threads)
      (bt:join-thread thread))
    (coerce results 'list)))

(defun on-domain-items (items source)
  "Drop item links outside the source's allowed hosts; they are not stored."
  (let ((kept '())
        (dropped 0))
    (dolist (item items)
      (if (source-url-allowed-p (parsed-item-url item) source)
          (push item kept)
          (incf dropped)))
    (when (plusp dropped)
      (log-event "offsite_link_dropped" :source (source-id source) :dropped dropped))
    (nreverse kept)))

(defun apply-source (store result source round-id now)
  "Store RESULT for SOURCE inside the caller's transaction. Returns insert count."
  (let ((inserted 0)
        (epic-keep (make-hash-table :test #'equal)))
    (dolist (item (on-domain-items (source-result-items result) source))
      (let ((canonical (handler-case (canonical-url (parsed-item-url item))
                         (parse-failure () nil))))
        (when canonical
          (let* ((title (parsed-item-title item))
                 (summary (parsed-item-summary item))
                 (published (parsed-item-published-at item))
                 (expires (parsed-item-expires-at item))
                 (category (classify-title title (source-id source)))
                 (existing (find-deal store canonical)))
            (if existing
                (progn
                  (setf (deal-url existing) canonical
                        (deal-title existing) title
                        (deal-summary existing) summary
                        (deal-category existing) (category-label category)
                        (deal-published-at existing) (or published (deal-published-at existing))
                        (deal-expires-at existing) expires
                        (deal-updated-at existing) now)
                  (update-deal store existing))
                (progn
                  (insert-deal store
                               (make-deal
                                :canonical-url canonical
                                :url canonical
                                :title title
                                :summary summary
                                :category (category-label category)
                                :source-id (source-id source)
                                :published-at published
                                :expires-at expires
                                :first-seen-at now
                                :first-seen-round-id round-id
                                :updated-at now))
                  (incf inserted)))
            (when (string= (source-id source) "epic")
              (setf (gethash canonical epic-keep) t))))))
    (when (string= (source-id source) "epic")
      (delete-source-deals-unless store "epic" epic-keep))
    inserted))

(defun purge-stale-deals (store now)
  (dolist (deal (list-deals store))
    (when (stale-p (deal-published-at deal) (deal-first-seen-at deal)
                   (deal-expires-at deal) now)
      (delete-deal store (deal-id deal)))))

(defun record-runs (store round-id results now)
  "Insert one source_runs row per source, then report structure anomalies."
  (dolist (result results)
    (insert-source-run store
                       (make-source-run
                        :round-id round-id
                        :source-id (source-result-source-id result)
                        :ok (source-result-ok result)
                        :fetched-count (length (source-result-items result))
                        :inserted-count (or (source-result-inserted-count result) 0)
                        :error (source-result-error result)
                        :final-url (source-result-final-url result)
                        :started-at (source-result-started-at result)
                        :finished-at (or (source-result-finished-at result) now))))
  (dolist (result results)
    (log-event "source_round"
               :source (source-result-source-id result)
               :ok (and (source-result-ok result) t)
               :parsed (length (source-result-items result))
               :inserted (or (source-result-inserted-count result) 0)
               :error (source-result-error result))))

(defun run-refresh (store &key (trigger "manual") (now (now-ms)) fetch-function)
  "Run one refresh round and return the resulting board.

TRIGGER is informational (\"scheduled\", \"manual\" or \"boot\"). FETCH-FUNCTION is
a test hook forwarded to FETCH-SOURCE."
  (let ((*http-get* (or fetch-function *http-get*)))
    (call-with-refresh-slot
     (lambda ()
       (let ((owner (random-hex-string 16)))
         (unless (acquire-lease store "refresh" owner (now-ms) +refresh-lease-ttl-ms+)
           (error 'refresh-busy :message "another process is refreshing"))
         (unwind-protect
              (progn
                (when (string= trigger "manual")
                  (let ((last (get-meta store "last_manual_at")))
                    (when last
                      (let ((age (- now (or (ignore-errors (parse-integer last)) 0))))
                        (when (< age +manual-cooldown-ms+)
                          (error 'refresh-cooldown
                                 :message "refresh too frequent"
                                 :retry-after-ms (- +manual-cooldown-ms+ age))))))
                  (set-meta store "last_manual_at" now))
                (log-event "round_start" :trigger trigger :sources (length *sources*))
                (let ((results (fetch-all-sources *sources* now)))
                  (unless (renew-lease store "refresh" owner (now-ms) +refresh-lease-ttl-ms+)
                    (error 'refresh-busy :message "refresh lease expired; discarding this round"))
                  (let ((round-id nil) (status nil) (ok-count 0))
                    (with-transaction (store)
                      (setf round-id (insert-round store trigger now))
                      (loop for result in results
                            for source = (find-source (source-result-source-id result))
                            when (and source (source-result-ok result))
                              do (setf (source-result-inserted-count result)
                                       (apply-source store result source round-id now)))
                      (purge-stale-deals store now)
                      (setf ok-count (count-if #'source-result-ok results)
                              status (cond ((= ok-count (length results)) "ok")
                                           ((zerop ok-count) "failed")
                                           (t "partial")))
                      (record-runs store round-id results now)
                      (finish-round store round-id (now-ms) status)
                      (prune-history store (- now +history-retention-ms+))
                      (unless (renew-lease store "refresh" owner (now-ms) +refresh-lease-ttl-ms+)
                        (error 'refresh-busy :message "refresh lease lost; rolling back")))
                    (log-event "round_finished" :round round-id :trigger trigger
                               :status status :ok-sources ok-count
                               :total-sources (length results))
                    (let ((board (board-state store :now (now-ms))))
                      (setf (board-round-status board) status)
                      board))))
           (release-lease store "refresh" owner)))))))

(defun random-hex-string (byte-count)
  (string-downcase
   (ironclad:byte-array-to-hex-string (ironclad:random-data byte-count))))
