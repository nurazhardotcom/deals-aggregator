;;;; Storage: schema, deal rows, rounds, leases, dangling-round recovery and
;;;; history pruning. Every case runs against an in-memory database.

(in-package #:deal-aggregator/tests)

(def-suite storage :description "Schema, deal rows, rounds, leases and pruning.")
(in-suite storage)

(defun store-deal (store &key (canonical "https://www.v2ex.com/t/1")
                              (title "限免测试") (source-id "v2ex")
                              (published *now*) expires (round-id 1)
                              (first-seen *now*))
  "Insert one deal and return it as stored."
  (da::insert-deal store
                   (da::make-deal :canonical-url canonical :url canonical
                                  :title title :summary "" :category "限免"
                                  :source-id source-id
                                  :published-at published :expires-at expires
                                  :first-seen-at first-seen
                                  :first-seen-round-id round-id
                                  :updated-at first-seen))
  (da::find-deal store canonical))

(test schema-version-and-tables
  (with-store (store)
    (is (= da::+schema-version+ (da::db-value store "PRAGMA user_version")))
    (let ((tables (mapcar #'first
                          (da::db-all store
                                      "SELECT name FROM sqlite_master WHERE type = 'table'"))))
      (dolist (name '("deals" "rounds" "source_runs" "meta" "leases"))
        (is (member name tables :test #'string=))))))

(test deal-round-trip
  (with-store (store)
    (let ((deal (store-deal store)))
      (is (plusp (da::deal-id deal)))
      (is (= 1 (da::count-deals store)))
      (is (string= "限免测试"
                   (da::deal-title (da::find-deal store "https://www.v2ex.com/t/1"))))
      (setf (da::deal-title deal) "改过的标题")
      (da::update-deal store deal)
      (is (string= "改过的标题"
                   (da::deal-title (da::find-deal store "https://www.v2ex.com/t/1"))))
      (da::delete-deal store (da::deal-id deal))
      (is (zerop (da::count-deals store)))
      (is (null (da::find-deal store "https://www.v2ex.com/t/1"))))))

(test canonical-url-is-unique
  (with-store (store)
    (store-deal store)
    (signals error (store-deal store))))

(test deals-are-newest-first
  (with-store (store)
    (store-deal store :canonical "https://example.com/old"
                       :published (- *now* (* 2 86400000)))
    (store-deal store :canonical "https://example.com/new" :published *now*)
    (is (equal '("https://example.com/new" "https://example.com/old")
               (mapcar #'da::deal-canonical-url (da::list-deals store))))))

(test meta-round-trip
  (with-store (store)
    (is (null (da::get-meta store "next_refresh_at")))
    (da::set-meta store "next_refresh_at" 1762650000000)
    (is (string= "1762650000000" (da::get-meta store "next_refresh_at")))
    (da::set-meta store "next_refresh_at" 42)
    (is (string= "42" (da::get-meta store "next_refresh_at")))))

(test leases
  (with-store (store)
    (let ((now *now*))
      (is (da::acquire-lease store "scheduler" "a" now 1000))
      (is (not (da::acquire-lease store "scheduler" "b" now 1000)))
      (is (da::renew-lease store "scheduler" "a" now 1000))
      (is (not (da::renew-lease store "scheduler" "b" now 1000)))
      (is (da::acquire-lease store "scheduler" "b" (+ now 1001) 1000))
      (da::release-lease store "scheduler" "b")
      (is (da::acquire-lease store "scheduler" "c" (+ now 1001) 1000)))))

(test dangling-rounds-are-failed
  (with-store (store)
    (let* ((started (- *now* (* 4 60 1000)))
           (round-id (da::insert-round store "scheduled" started)))
      (da::insert-source-run store
                             (da::make-source-run :round-id round-id :source-id "v2ex"
                                                  :ok 1 :fetched-count 3 :inserted-count 0
                                                  :started-at started :finished-at nil))
      (da::recover-dangling-rounds store *now*)
      (let ((round (da::latest-round store))
            (run (first (da::list-source-runs store round-id))))
        (is (string= "failed" (da::round-row-status round)))
        (is (= *now* (da::round-row-finished-at round)))
        (is (null (da::source-run-ok run)))
        (is (string= "interrupted" (da::source-run-error run)))))))

(test fresh-rounds-survive-recovery
  (with-store (store)
    (let ((round-id (da::insert-round store "manual" (- *now* 1000))))
      (da::recover-dangling-rounds store *now*)
      (is (string= "running" (da::round-row-status (da::latest-round store))))
      (is (= round-id (da::round-row-id (da::latest-round store)))))))

(test prune-keeps-latest-round
  (with-store (store)
    (let* ((old (- *now* (* 40 86400000)))
           (r1 (da::insert-round store "scheduled" old))
           (r2 (da::insert-round store "scheduled" (+ old 1000)))
           (r3 (da::insert-round store "scheduled" (- *now* 1000))))
      (da::finish-round store r1 (+ old 500) "ok")
      (da::finish-round store r2 (+ old 1500) "ok")
      (da::finish-round store r3 *now* "ok")
      (da::prune-history store (- *now* 86400000))
      (is (null (da::db-one store "SELECT id FROM rounds WHERE id = ?" r1)))
      (is (null (da::db-one store "SELECT id FROM rounds WHERE id = ?" r2)))
      (is (da::db-one store "SELECT id FROM rounds WHERE id = ?" r3)))))

(test epic-reconciliation-helper
  (with-store (store)
    (store-deal store :canonical "https://store.epicgames.com/zh-CN/p/keep"
                       :source-id "epic")
    (store-deal store :canonical "https://store.epicgames.com/zh-CN/p/drop"
                       :source-id "epic")
    (let ((keep (make-hash-table :test #'equal)))
      (setf (gethash "https://store.epicgames.com/zh-CN/p/keep" keep) t)
      (da::delete-source-deals-unless store "epic" keep))
    (is (= 1 (da::count-deals store)))
    (is (da::find-deal store "https://store.epicgames.com/zh-CN/p/keep"))))
