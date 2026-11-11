;;;; Refresh orchestration: one round over the fixture sources, failure
;;;; isolation, Epic reconciliation, the manual cooldown and scheduler timing.

(in-package #:deal-aggregator/tests)

(def-suite round :description "Refresh rounds, cooldown and scheduler arithmetic.")
(in-suite round)

(test one-round-stores-every-source
  (with-store (store)
    (let ((board (with-clock (*now*)
                   (da:run-refresh store :trigger "boot" :now *now*
                                         :fetch-function (fixture-http)))))
      (is (string= "ok" (da::board-round-status board)))
      (is (= 7 (da::board-source-health-total board)))
      (is (= 7 (da::board-source-health-ok board)))
      (is (> (da::board-active-count board) 10))
      (is (= (da::count-deals store) (da::board-active-count board)))
      (let* ((round (da::latest-finished-round store))
             (runs (da::list-source-runs store (da::round-row-id round)))
             (nodeseek (find "nodeseek" runs
                             :key #'da::source-run-source-id :test #'string=)))
        (is (string= "boot" (da::round-row-trigger round)))
        (is (= 7 (length runs)))
        (is (plusp (da::source-run-fetched-count nodeseek)))
        (is (zerop (da::source-run-inserted-count nodeseek)))))))

(test failure-is-isolated
  (with-store (store)
    (with-clock (*now*)
      (da:run-refresh store :trigger "boot" :now *now* :fetch-function (fixture-http)))
    (let ((board (with-clock (*now*)
                   (da:run-refresh
                    store :trigger "scheduled" :now *now*
                          :fetch-function
                          (failing-http "https://www.v2ex.com/feed/promotions.xml")))))
      (is (string= "partial" (da::board-round-status board)))
      (is (= 1 (length (da::board-failures board))))
      (is (string= "v2ex" (da::failure-source-id (first (da::board-failures board)))))
      (is (search "HTTP 500" (da::failure-error (first (da::board-failures board)))))
      (is (da::find-deal store "https://www.v2ex.com/t/1255325")))))

(test epic-rows-follow-the-catalogue
  (with-store (store)
    (flet ((epic-count ()
             (count-if (lambda (deal) (string= "epic" (da::deal-source-id deal)))
                       (da::list-deals store))))
      (with-clock (*now*)
        (da:run-refresh store :trigger "boot" :now *now* :fetch-function (fixture-http)))
      (is (= 2 (epic-count)))
      (let ((later (+ *now* (* 10 86400000))))
        (with-clock (later)
          (da:run-refresh store :trigger "scheduled" :now later
                                :fetch-function (fixture-http)))
        (is (zerop (epic-count)))))))

(test manual-cooldown
  (with-store (store)
    (with-clock (*now*)
      (da:run-refresh store :trigger "manual" :now *now* :fetch-function (fixture-http)))
    (let ((soon (+ *now* 30000)))
      (with-clock (soon)
        (signals da::refresh-cooldown
          (da:run-refresh store :trigger "manual" :now soon
                                :fetch-function (fixture-http)))))
    (let ((later (+ *now* 60001)))
      (with-clock (later)
        (is (da::board-p
             (da:run-refresh store :trigger "manual" :now later
                                   :fetch-function (fixture-http))))))))

(test scheduler-due-time
  (with-store (store)
    (let ((now *now*)
          (hour (* 60 60 1000)))
      (is (= (+ now da::+scheduler-boot-delay-ms+) (da::compute-due-at store now)))
      (da::set-meta store "next_refresh_at" (+ now hour))
      (is (= (+ now hour) (da::compute-due-at store now)))
      (let ((round-id (da::insert-round store "scheduled" (- now hour))))
        (da::finish-round store round-id now "ok")
        (is (= (+ now hour) (da::compute-due-at store now)))))))

(test refresh-slot
  (is (not (da:refresh-in-progress-p)))
  (let ((seen nil))
    (da::call-with-refresh-slot
     (lambda ()
       (setf seen (da:refresh-in-progress-p))
       (signals da::refresh-busy
         (da::call-with-refresh-slot (lambda () nil)))))
    (is-true seen)
    (is (not (da:refresh-in-progress-p)))))
