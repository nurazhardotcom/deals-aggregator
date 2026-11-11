;;;; Configuration: environment variables and fixed tuning constants.
;;;;
;;;; Every time value is an integer number of milliseconds since the Unix epoch,
;;;; matching the values stored in SQLite and returned by the JSON API.

(in-package #:deal-aggregator)

(defparameter +version+ "1.0.0")

;;; ------------------------------------------------------------------
;;; Environment

(defun getenv (name)
  "Return the value of environment variable NAME, or NIL when unset or empty."
  (let ((value (uiop:getenv name)))
    (and value (plusp (length value)) value)))

(defun env-flag-p (name)
  "True when environment variable NAME is set to \"1\"."
  (let ((value (getenv name)))
    (and value (string= value "1"))))

(defun access-token ()
  "Return the shared access token, or NIL when authentication is disabled.

A token shorter than 32 characters is a configuration error. It fails closed
rather than half-protecting a publicly reachable instance."
  (let ((token (getenv "DEAL_AGGREGATOR_ACCESS_TOKEN")))
    (when token
      (when (< (length token) 32)
        (error 'auth-configuration-error
               :message "DEAL_AGGREGATOR_ACCESS_TOKEN must be at least 32 characters"))
      token)))

(defun secure-cookie-p ()
  "True unless DEAL_AGGREGATOR_SECURE_COOKIE=0 explicitly opts out."
  (not (and (getenv "DEAL_AGGREGATOR_SECURE_COOKIE")
            (string= "0" (getenv "DEAL_AGGREGATOR_SECURE_COOKIE")))))

(defun stored-categories-p ()
  (env-flag-p "DEAL_AGGREGATOR_STORED_CATEGORIES"))

(defun skip-boot-refresh-p ()
  (env-flag-p "DEAL_AGGREGATOR_SKIP_BOOT"))

(defun data-directory ()
  "Directory holding the SQLite file, from DATA_DIR or ./data."
  (pathname (concatenate 'string
                         (string-right-trim "/" (or (getenv "DATA_DIR") "data"))
                         "/")))

(defun database-file ()
  (merge-pathnames "deals.db" (data-directory)))

(defun listen-host ()
  (or (getenv "HOST") "127.0.0.1"))

(defun listen-port ()
  (or (ignore-errors (parse-integer (getenv "PORT") :junk-allowed t))
      38471))

(defun user-agent ()
  (format nil "deal-aggregator/~a (+https://github.com/nurazhardotcom/deals-aggregator)"
          +version+))

;;; ------------------------------------------------------------------
;;; Timing

(defparameter +retention-ms+ (* 7 24 60 60 1000)
  "Items older than this are dropped, measured from publish time or first sighting.")

(defparameter +refresh-interval-ms+ (* 2 60 60 1000)
  "Scheduled round interval.")

(defparameter +scheduler-boot-delay-ms+ 4000
  "Delay before the first scheduled round after process start.")

(defparameter +scheduler-tick-ms+ 20000
  "How often the scheduler compares the clock with the due time and renews its lease.")

(defparameter +scheduler-lease-ttl-ms+ 90000
  "Scheduler lease lifetime. A killed process blocks its successor for at most this long.")

(defparameter +scheduler-busy-retry-ms+ 60000
  "Retry delay when a scheduled slot found another refresh already running.")

(defparameter +scheduler-failed-retry-ms+ (* 10 60 1000)
  "First retry delay after a round where every source failed; doubles up to the interval.")

(defparameter +refresh-lease-ttl-ms+ 180000
  "Refresh lease lifetime, longer than one round so a slow round keeps its claim.")

(defparameter +max-retry-after-ms+ (* 6 60 60 1000)
  "Upper bound for an upstream Retry-After, so a bogus header cannot pause a source for days.")

(defparameter +manual-cooldown-ms+ 60000
  "Minimum gap between two manual refreshes.")

(defparameter +source-timeout-ms+ 25000
  "Per-source network timeout. One slow source does not extend the others.")

(defparameter +expiring-soon-ms+ (* 48 60 60 1000)
  "Expiry badge window.")

(defparameter +manual-ip-limit+ 8
  "Manual refreshes allowed per client address inside the window below.")

(defparameter +manual-ip-window-ms+ (* 10 60 1000))

(defparameter +dangling-round-ms+ (* 3 60 1000)
  "A round still running after this is treated as interrupted.")

(defparameter +stale-after-ms+ (* 5 (* 30 60 1000))
  "A board older than this is stale.")

(defparameter +severe-after-ms+ (* 4 60 60 1000)
  "A board older than this is severely stale.")

(defparameter +board-page-size+ 500)
(defparameter +board-max-items+ 100000)
(defparameter +history-retention-ms+ (* 30 24 60 60 1000))
(defparameter +max-response-chars+ 1500000)
(defparameter +max-feed-items+ 2000)
(defparameter +max-url-chars+ 2048)
(defparameter +future-publish-tolerance-ms+ (* 7 24 60 60 1000))
(defparameter +min-publish-ms+ (* 946684800 1000) ; 2000-01-01T00:00:00Z
  "Published timestamps before this are treated as missing.")
(defparameter +summary-max+ 160)
(defparameter +title-max+ 300)

;;; ------------------------------------------------------------------
;;; Web

(defparameter +schema-version+ 1
  "The only database schema version this program writes.")

(defparameter +session-ms+ (* 8 60 60 1000)
  "Session cookie lifetime.")

(defparameter +login-body-limit+ 4096
  "Maximum accepted login form body, in bytes.")

(defparameter +login-attempt-limit+ 10
  "Login attempts allowed per client address inside the window below.")

(defparameter +login-attempt-window-ms+ 60000)

(defparameter +manual-refresh-body-limit+ 2048)
