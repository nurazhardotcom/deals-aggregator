;;;; The scheduled refresh thread. It holds a database lease so a second process
;;;; on the same data directory cannot schedule the same rounds, publishes the
;;;; next due time, and backs off after busy or fully failed rounds.

(in-package #:deal-aggregator)

(defstruct (scheduler (:constructor %make-scheduler))
  store
  (interval-ms +refresh-interval-ms+)
  (tick-ms +scheduler-tick-ms+)
  (owner (random-hex-string 16))
  thread
  (stop nil)
  (due-at nil)
  (failure-streak 0))

(defvar *scheduler* nil)
(defvar *scheduler-lock* (bt:make-lock "deal-aggregator.scheduler"))

(defun compute-due-at (store now)
  "Boot due time: the remainder of the interval since the last round start,
but never earlier than the boot delay."
  (if (skip-boot-refresh-p)
      (+ now +refresh-interval-ms+)
      (let ((stored (ignore-errors (parse-integer (or (get-meta store "next_refresh_at") ""))))
            (round (latest-round store)))
        (let ((due (if round
                       (max (+ now +scheduler-boot-delay-ms+)
                            (+ (round-row-started-at round) +refresh-interval-ms+))
                       (+ now +scheduler-boot-delay-ms+))))
          (when (and stored (<= now stored))
            (setf due (max due (min stored (+ now +refresh-interval-ms+)))))
          due))))

(defun run-scheduled-round (scheduler)
  "Run one scheduled round, classifying the outcome for the retry policy."
  (handler-case
      (let ((board (run-refresh (scheduler-store scheduler) :trigger "scheduled")))
        (if (string= (or (board-round-status board) "") "failed")
            :failed
            :ok))
    (refresh-busy () :busy)
    (serious-condition (condition)
      (log-failure "scheduled_refresh_failed" condition)
      :error)))

(defun scheduler-tick (scheduler)
  (let* ((store (scheduler-store scheduler))
         (owner (scheduler-owner scheduler))
         (now (now-ms)))
    (when (or (acquire-lease store "scheduler" owner now +scheduler-lease-ttl-ms+)
              (renew-lease store "scheduler" owner now +scheduler-lease-ttl-ms+))
      (when (>= now (scheduler-due-at scheduler))
        (setf (scheduler-due-at scheduler) (+ now (scheduler-interval-ms scheduler)))
        (set-meta store "next_refresh_at" (scheduler-due-at scheduler))
        (let ((outcome (run-scheduled-round scheduler)))
          (case outcome
            (:ok (setf (scheduler-failure-streak scheduler) 0))
            (:busy
             (log-event "scheduled_refresh_retry" :outcome "busy"
                        :retry-in-ms +scheduler-busy-retry-ms+)
             (setf (scheduler-due-at scheduler)
                   (min (scheduler-due-at scheduler)
                        (+ (now-ms) +scheduler-busy-retry-ms+))))
            (t
             (let ((retry (min (scheduler-interval-ms scheduler)
                               (* +scheduler-failed-retry-ms+
                                  (expt 2 (scheduler-failure-streak scheduler))))))
               (incf (scheduler-failure-streak scheduler))
               (log-event "scheduled_refresh_retry" :outcome (string-downcase (symbol-name outcome))
                          :retry-in-ms retry)
               (setf (scheduler-due-at scheduler)
                     (min (scheduler-due-at scheduler) (+ (now-ms) retry))))))
          (set-meta store "next_refresh_at" (scheduler-due-at scheduler)))))))

(defun scheduler-loop (scheduler)
  (unless (scheduler-due-at scheduler)
    (setf (scheduler-due-at scheduler) (compute-due-at (scheduler-store scheduler) (now-ms))))
  (loop until (scheduler-stop scheduler)
        do (handler-case (scheduler-tick scheduler)
             (serious-condition (condition)
               (log-failure "scheduler_tick_failed" condition)))
           (let* ((now (now-ms))
                  (until-due (max 1000 (- (scheduler-due-at scheduler) now))))
             (sleep (/ (min (scheduler-tick-ms scheduler) until-due) 1000))))
  (ignore-errors
    (release-lease (scheduler-store scheduler) "scheduler" (scheduler-owner scheduler))))

(defun start-scheduler (store &key (interval-ms +refresh-interval-ms+)
                                     (tick-ms +scheduler-tick-ms+))
  "Start the scheduler thread. Idempotent: a running scheduler is returned as is."
  (bt:with-lock-held (*scheduler-lock*)
    (unless (and *scheduler*
                 (bt:thread-alive-p (scheduler-thread *scheduler*)))
      (let ((scheduler (%make-scheduler :store store
                                        :interval-ms interval-ms
                                        :tick-ms tick-ms)))
        (setf (scheduler-due-at scheduler) (compute-due-at store (now-ms))
              (scheduler-thread scheduler)
              (bt:make-thread (lambda () (scheduler-loop scheduler))
                              :name "deal-aggregator-scheduler")
              *scheduler* scheduler)
        (log-event "scheduler_started" :due-at (iso-string (scheduler-due-at scheduler)))
        scheduler))))

(defun stop-scheduler ()
  "Stop the scheduler thread and release its lease."
  (bt:with-lock-held (*scheduler-lock*)
    (when *scheduler*
      (setf (scheduler-stop *scheduler*) t)
      (let ((thread (scheduler-thread *scheduler*)))
        (when (and thread (bt:thread-alive-p thread) (not (eq thread (bt:current-thread))))
          (ignore-errors (bt:join-thread thread :timeout 5))))
      (ignore-errors
        (release-lease (scheduler-store *scheduler*) "scheduler"
                       (scheduler-owner *scheduler*)))
      (setf *scheduler* nil)
      t)))
