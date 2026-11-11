;;;; SQLite storage: one connection, serialised by a recursive lock, plus the
;;;; schema, migrations and every query the rest of the program uses.

(in-package #:deal-aggregator)

;;; ------------------------------------------------------------------
;;; Connection

(defstruct (store (:constructor %make-store))
  handle
  (lock (bt:make-recursive-lock "deal-aggregator.db"))
  (path ":memory:"))

(defmacro with-store-lock ((store) &body body)
  `(bt:with-recursive-lock-held ((store-lock ,store))
     ,@body))

(defun db-exec (store sql &rest parameters)
  (with-store-lock (store)
    (apply #'sqlite:execute-non-query (store-handle store) sql parameters)))

(defun db-all (store sql &rest parameters)
  (with-store-lock (store)
    (apply #'sqlite:execute-to-list (store-handle store) sql parameters)))

(defun db-one (store sql &rest parameters)
  (first (apply #'db-all store sql parameters)))

(defun db-value (store sql &rest parameters)
  (first (apply #'db-one store sql parameters)))

(defvar *transaction-depth* 0)

(defmacro with-transaction ((store) &body body)
  "Run BODY inside BEGIN IMMEDIATE ... COMMIT, rolling back on any error.
Re-entrant: nested uses join the outer transaction."
  (let ((store-var (gensym "STORE")))
    `(let ((,store-var ,store))
       (with-store-lock (,store-var)
         (if (plusp *transaction-depth*)
             (progn ,@body)
             (progn
               (db-exec ,store-var "BEGIN IMMEDIATE")
               (let ((*transaction-depth* 1))
                 (handler-case
                     (prog1 (progn ,@body)
                       (db-exec ,store-var "COMMIT"))
                   (serious-condition (condition)
                     (ignore-errors (db-exec ,store-var "ROLLBACK"))
                     (error condition))))))))))

;;; ------------------------------------------------------------------
;;; Schema

(defparameter +schema-statements+
  (list
   "CREATE TABLE IF NOT EXISTS deals (
      id INTEGER PRIMARY KEY,
      canonical_url TEXT NOT NULL UNIQUE,
      url TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      category TEXT NOT NULL,
      source_id TEXT NOT NULL,
      published_at INTEGER,
      expires_at INTEGER,
      first_seen_at INTEGER NOT NULL,
      first_seen_round_id INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )"
   "CREATE INDEX IF NOT EXISTS idx_deals_source ON deals(source_id)"
   "CREATE TABLE IF NOT EXISTS rounds (
      id INTEGER PRIMARY KEY,
      trigger TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      finished_at INTEGER,
      status TEXT NOT NULL
    )"
   "CREATE INDEX IF NOT EXISTS idx_rounds_finished ON rounds(finished_at)"
   "CREATE TABLE IF NOT EXISTS source_runs (
      id INTEGER PRIMARY KEY,
      round_id INTEGER NOT NULL,
      source_id TEXT NOT NULL,
      ok INTEGER NOT NULL,
      fetched_count INTEGER NOT NULL DEFAULT 0,
      inserted_count INTEGER NOT NULL DEFAULT 0,
      error TEXT,
      final_url TEXT,
      started_at INTEGER NOT NULL,
      finished_at INTEGER
    )"
   "CREATE INDEX IF NOT EXISTS idx_source_runs_round ON source_runs(round_id)"
   "CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )"
   "CREATE TABLE IF NOT EXISTS leases (
      name TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      expires_at INTEGER NOT NULL
    )"))

(defun migrate-store (store)
  "Create missing indexes and tables and record the schema version.

Refuses a database written by a newer version instead of downgrading it."
  (let ((version (or (db-value store "PRAGMA user_version") 0)))
    (when (> version +schema-version+)
      (error 'db-unavailable
             :message "database schema is newer than this program; refusing to downgrade"))
    (unless (= version +schema-version+)
      (with-transaction (store)
        (db-exec store "CREATE INDEX IF NOT EXISTS idx_source_runs_source_round ON source_runs(source_id, round_id DESC, id DESC)")
        (db-exec store (format nil "PRAGMA user_version = ~d" +schema-version+))))))

(defun open-store (path)
  "Open (and if needed create) the database at PATH, returning a STORE.

PATH may be \":memory:\" for tests."
  (let ((path (or path (database-file))))
    (let ((name (if (stringp path) path (namestring path))))
      (unless (string= name ":memory:")
        (ensure-directories-exist path))
      (let ((handle (handler-case (sqlite:connect name)
                      (error (condition)
                        (error 'db-unavailable
                               :message (format nil "cannot open database: ~a"
                                                condition))))))
        (let ((store (%make-store :handle handle :path name)))
          (ignore-errors (sqlite:set-busy-timeout handle 5000))
          (unless (string= name ":memory:")
            (ignore-errors (db-exec store "PRAGMA journal_mode = WAL")))
          (handler-case
              (progn
                (dolist (statement +schema-statements+)
                  (db-exec store statement))
                (migrate-store store)
                store)
            (error (condition)
              (ignore-errors (sqlite:disconnect handle))
              (error condition))))))))

(defun close-store (store)
  (when (and store (store-handle store))
    (ignore-errors (sqlite:disconnect (store-handle store)))
    (setf (store-handle store) nil))
  nil)

;;; ------------------------------------------------------------------
;;; Row types

(defstruct (deal (:constructor make-deal))
  (id 0)
  canonical-url
  url
  title
  (summary "")
  category
  source-id
  published-at
  expires-at
  first-seen-at
  first-seen-round-id
  updated-at)

(defstruct (round-row (:constructor make-round-row))
  (id 0)
  trigger
  started-at
  finished-at
  status)

(defstruct (source-run (:constructor make-source-run))
  (id 0)
  round-id
  source-id
  ok
  (fetched-count 0)
  (inserted-count 0)
  error
  final-url
  started-at
  finished-at)

(defparameter +deal-columns+
  "id, canonical_url, url, title, summary, category, source_id,
   published_at, expires_at, first_seen_at, first_seen_round_id, updated_at")

(defparameter +source-run-columns+
  "id, round_id, source_id, ok, fetched_count, inserted_count, error,
   final_url, started_at, finished_at")

(defun map-deal-row (row)
  (destructuring-bind (id canonical-url url title summary category source-id
                       published-at expires-at first-seen-at first-seen-round-id
                       updated-at)
      row
    (make-deal :id id :canonical-url canonical-url :url url :title title
               :summary summary :category category :source-id source-id
               :published-at published-at :expires-at expires-at
               :first-seen-at first-seen-at :first-seen-round-id first-seen-round-id
               :updated-at updated-at)))

(defun map-round-row (row)
  (destructuring-bind (id trigger started-at finished-at status) row
    (make-round-row :id id :trigger trigger :started-at started-at
                    :finished-at finished-at :status status)))

(defun map-source-run-row (row)
  (destructuring-bind (id round-id source-id ok fetched-count inserted-count error
                       final-url started-at finished-at)
      row
    (make-source-run :id id :round-id round-id :source-id source-id
                     :ok (= 1 ok) :fetched-count fetched-count
                     :inserted-count inserted-count :error error
                     :final-url final-url :started-at started-at
                     :finished-at finished-at)))

;;; ------------------------------------------------------------------
;;; Deals

(defun list-deals (store)
  (mapcar #'map-deal-row
          (db-all store (format nil "SELECT ~a FROM deals
                                    ORDER BY COALESCE(published_at, first_seen_at) DESC, id DESC"
                                +deal-columns+))))

(defun find-deal (store canonical-url)
  (let ((row (db-one store (format nil "SELECT ~a FROM deals WHERE canonical_url = ?"
                                   +deal-columns+)
                     canonical-url)))
    (and row (map-deal-row row))))

(defun insert-deal (store deal)
  (db-exec store
           "INSERT INTO deals (canonical_url, url, title, summary, category, source_id,
                               published_at, expires_at, first_seen_at, first_seen_round_id, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
           (deal-canonical-url deal) (deal-url deal) (deal-title deal)
           (deal-summary deal) (deal-category deal) (deal-source-id deal)
           (deal-published-at deal) (deal-expires-at deal) (deal-first-seen-at deal)
           (deal-first-seen-round-id deal) (deal-updated-at deal))
  (db-value store "SELECT last_insert_rowid()"))

(defun update-deal (store deal)
  (db-exec store
           "UPDATE deals
               SET url = ?, title = ?, summary = ?, category = ?,
                   published_at = ?, expires_at = ?, updated_at = ?
             WHERE id = ?"
           (deal-url deal) (deal-title deal) (deal-summary deal)
           (deal-category deal) (deal-published-at deal) (deal-expires-at deal)
           (deal-updated-at deal) (deal-id deal)))

(defun delete-deal (store id)
  (db-exec store "DELETE FROM deals WHERE id = ?" id))

(defun delete-source-deals-unless (store source-id keep)
  "Drop deals of SOURCE-ID whose canonical URL is not in the KEEP hash set."
  (dolist (deal (list-deals store))
    (when (and (string= (deal-source-id deal) source-id)
               (not (gethash (deal-canonical-url deal) keep)))
      (delete-deal store (deal-id deal)))))

(defun count-deals (store)
  (or (db-value store "SELECT COUNT(*) FROM deals") 0))

;;; ------------------------------------------------------------------
;;; Rounds and source runs

(defun insert-round (store trigger started-at)
  (db-exec store "INSERT INTO rounds (trigger, started_at, status) VALUES (?, ?, 'running')"
           trigger started-at)
  (db-value store "SELECT last_insert_rowid()"))

(defun finish-round (store id finished-at status)
  (db-exec store "UPDATE rounds SET finished_at = ?, status = ? WHERE id = ?"
           finished-at status id))

(defun map-rounds (rows)
  (mapcar #'map-round-row rows))

(defun latest-finished-round (store)
  (let ((row (db-one store "SELECT id, trigger, started_at, finished_at, status
                             FROM rounds WHERE status != 'running'
                             ORDER BY id DESC LIMIT 1")))
    (and row (map-round-row row))))

(defun latest-round (store)
  (let ((row (db-one store "SELECT id, trigger, started_at, finished_at, status
                             FROM rounds ORDER BY id DESC LIMIT 1")))
    (and row (map-round-row row))))

(defun insert-source-run (store run)
  (db-exec store
           "INSERT INTO source_runs (round_id, source_id, ok, fetched_count,
                                     inserted_count, error, final_url, started_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
           (source-run-round-id run) (source-run-source-id run)
           (if (source-run-ok run) 1 0) (source-run-fetched-count run)
           (source-run-inserted-count run) (source-run-error run)
           (source-run-final-url run) (source-run-started-at run)
           (source-run-finished-at run)))

(defun list-source-runs (store round-id)
  (mapcar #'map-source-run-row
          (db-all store (format nil "SELECT ~a FROM source_runs WHERE round_id = ? ORDER BY id ASC"
                                +source-run-columns+)
                  round-id)))

(defun previous-source-runs (store round-id)
  "Runs of the most recent finished round before ROUND-ID."
  (let ((previous (db-value store "SELECT MAX(id) FROM rounds WHERE status != 'running' AND id < ?"
                            round-id)))
    (if previous (list-source-runs store previous) '())))

(defun recent-source-runs (store source-id &key (limit 8))
  (let ((bounded (max 1 (min 32 limit))))
    (mapcar #'map-source-run-row
            (db-all store
                    (format nil "SELECT ~a FROM source_runs sr
                                 WHERE sr.source_id = ?
                                 ORDER BY sr.round_id DESC, sr.id DESC LIMIT ?"
                            (ppcre:regex-replace-all "(\\w+)"
                                                     +source-run-columns+
                                                     "sr.\\1"))
                    source-id bounded))))

(defun recover-dangling-rounds (store now)
  "Mark rounds abandoned by a crashed process as failed."
  (dolist (row (db-all store "SELECT id, started_at FROM rounds WHERE status = 'running'"))
    (destructuring-bind (id started-at) row
      (when (>= (- now started-at) +dangling-round-ms+)
        (with-transaction (store)
          (db-exec store "UPDATE rounds SET status = 'failed', finished_at = ? WHERE id = ?" now id)
          (db-exec store "UPDATE source_runs
                             SET ok = 0,
                                 error = COALESCE(error, 'interrupted'),
                                 finished_at = COALESCE(finished_at, ?)
                           WHERE round_id = ? AND finished_at IS NULL"
                   now id))))))

(defun prune-history (store cutoff)
  "Drop finished rounds older than CUTOFF, keeping the latest finished round."
  (let ((latest (db-value store "SELECT COALESCE(MAX(id), 0) FROM rounds WHERE status != 'running'")))
    (db-exec store "DELETE FROM source_runs WHERE round_id IN
                      (SELECT id FROM rounds
                        WHERE finished_at < ? AND status != 'running' AND id != ?)"
             cutoff latest)
    (db-exec store "DELETE FROM rounds
                     WHERE finished_at < ? AND status != 'running' AND id != ?"
             cutoff latest)))

;;; ------------------------------------------------------------------
;;; Metadata and leases

(defun get-meta (store key)
  (db-value store "SELECT value FROM meta WHERE key = ?" key))

(defun set-meta (store key value)
  (db-exec store "INSERT INTO meta (key, value) VALUES (?, ?)
                  ON CONFLICT(key) DO UPDATE SET value = excluded.value"
           key (princ-to-string value)))

(defun acquire-lease (store name owner now ttl-ms)
  "Take NAME for OWNER when free, expired, or already owned. True on success."
  (with-transaction (store)
    (let ((row (db-one store "SELECT owner, expires_at FROM leases WHERE name = ?" name)))
      (cond ((null row)
             (db-exec store "INSERT INTO leases (name, owner, expires_at) VALUES (?, ?, ?)"
                      name owner (+ now ttl-ms))
             t)
            ((or (<= (second row) now) (string= (first row) owner))
             (db-exec store "UPDATE leases SET owner = ?, expires_at = ? WHERE name = ?"
                      owner (+ now ttl-ms) name)
             t)
            (t nil)))))

(defun renew-lease (store name owner now ttl-ms)
  (with-transaction (store)
    (let ((row (db-one store "SELECT owner, expires_at FROM leases WHERE name = ?" name)))
      (when (and row (string= (first row) owner) (> (second row) now))
        (db-exec store "UPDATE leases SET expires_at = ? WHERE name = ?" (+ now ttl-ms) name)
        t))))

(defun release-lease (store name owner)
  (ignore-errors
    (db-exec store "DELETE FROM leases WHERE name = ? AND owner = ?" name owner)))
