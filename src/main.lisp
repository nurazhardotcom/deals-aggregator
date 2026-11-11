;;;; Process entry point: command line, signal handling, startup order.

(in-package #:deal-aggregator)

(defun set-environment (name value)
  #+sbcl (sb-posix:setenv name value 1)
  #-sbcl (declare (ignore name value))
  value)

(defun print-usage ()
  (format t "~&deal-aggregator ~a~%~
Usage: deal-aggregator [options]~%~
  --host HOST        bind address (default 127.0.0.1)~%~
  --port PORT        bind port (default 38471)~%~
  --data-dir DIR     directory holding deals.db (default ./data)~%~
  --once             run one refresh round, print a summary, exit~%~
  --no-scheduler     serve without the background scheduler~%~
  --version          print the version and exit~%~
  --help             print this help~%~
Environment: DATA_DIR, HOST, PORT, DEAL_AGGREGATOR_ACCESS_TOKEN,~
  DEAL_AGGREGATOR_SECURE_COOKIE, DEAL_AGGREGATOR_STORED_CATEGORIES,~
  DEAL_AGGREGATOR_SKIP_BOOT, TRUST_PROXY_HEADERS~%"
          +version+))

(defun parse-arguments (arguments)
  "Return a plist of options parsed from ARGUMENTS."
  (let ((options (list :once nil :scheduler t :help nil :version nil)))
    (loop while arguments
          for argument = (pop arguments)
          do (cond
               ((string= argument "--once") (setf (getf options :once) t))
               ((string= argument "--no-scheduler") (setf (getf options :scheduler) nil))
               ((string= argument "--help") (setf (getf options :help) t))
               ((string= argument "--version") (setf (getf options :version) t))
               ((string= argument "--host")
                (setf (getf options :host) (or (pop arguments) "127.0.0.1")))
               ((string= argument "--port")
                (setf (getf options :port) (or (pop arguments) "38471")))
               ((string= argument "--data-dir")
                (setf (getf options :data-dir) (or (pop arguments) "data")))
               (t (format *error-output* "~&ignoring unknown argument ~a~%" argument))))
    options))

(defun install-signal-handlers (tag)
  #+sbcl
  (dolist (signal (list sb-unix:sigint sb-unix:sigterm))
    (sb-sys:enable-interrupt
     signal
     (lambda (&rest arguments)
       (declare (ignore arguments))
       (throw tag nil))))
  #-sbcl (declare (ignore tag)))

(defun run-once (store)
  (let ((board (run-refresh store :trigger "boot")))
    (format t "~&round ~a: ~a sources ok of ~a, ~a deals active~%"
            (or (board-round-status board) "unknown")
            (board-source-health-ok board)
            (board-source-health-total board)
            (board-active-count board))
    (dolist (failure (board-failures board))
      (format t "~&  ~a: ~a~%" (failure-source-name failure) (failure-error failure)))
    (board-round-status board)))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  "Program entry point. Returns a process exit code."
  (let ((options (parse-arguments arguments)))
    (cond
      ((getf options :help) (print-usage) 0)
      ((getf options :version) (format t "~&~a~%" +version+) 0)
      (t
       (when (getf options :host)
         (set-environment "HOST" (getf options :host)))
       (when (getf options :port)
         (set-environment "PORT" (princ-to-string (getf options :port))))
       (when (getf options :data-dir)
         (set-environment "DATA_DIR" (getf options :data-dir)))
       (let ((store (open-store (database-file))))
         (unwind-protect
              (if (getf options :once)
                  (progn (run-once store) 0)
                  (catch 'deal-aggregator-shutdown
                    (install-signal-handlers 'deal-aggregator-shutdown)
                    (when (getf options :scheduler)
                      (start-scheduler store))
                    (start-server :store store)
                    (log-event "ready" :port (listen-port))
                    (loop (sleep 60))))
           (stop-server)
           (stop-scheduler)
           (close-store store)))))))

(defun toplevel ()
  "Executable entry point for a saved core."
  (let ((code (main)))
    (uiop:quit code)))
