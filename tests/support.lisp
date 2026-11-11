;;;; Shared test support: fixtures, an in-memory store, a frozen clock, a stub
;;;; fetcher and a real HTTP client for the web suite.

(in-package #:deal-aggregator/tests)

;;; ------------------------------------------------------------------
;;; Fixtures

(defparameter *fixture-directory*
  (asdf:system-relative-pathname "deal-aggregator" "tests/fixtures/"))

(defun read-fixture (name)
  "Contents of the fixture file NAME."
  (uiop:read-file-string (merge-pathnames name *fixture-directory*)))

;;; ------------------------------------------------------------------
;;; Clock

(defun utc-ms (second minute hour day month year)
  "Epoch milliseconds of the given UTC wall-clock time."
  (da::universal-time-to-epoch-ms
   (da::encode-utc-universal-time second minute hour day month year)))

(defparameter *now* (utc-ms 0 0 0 9 11 2026)
  "2026-11-09T00:00:00Z, inside every promotion window in the Epic fixture.")

(defmacro with-clock ((ms) &body body)
  "Run BODY with the program clock frozen at MS."
  `(let ((da::*clock* (lambda () ,ms)))
     ,@body))

;;; ------------------------------------------------------------------
;;; Store

(defmacro with-store ((var) &body body)
  "Run BODY with VAR bound to a fresh in-memory store."
  `(let ((,var (da:open-store ":memory:")))
     (unwind-protect (progn ,@body)
       (da:close-store ,var))))

;;; ------------------------------------------------------------------
;;; Fetch stub

(defparameter *fixture-routes*
  '(("https://r.jina.ai/https://linux.do/c/welfare/36.rss" . "linuxdo-public-sample.md")
    ("https://www.v2ex.com/feed/promotions.xml" . "v2ex-public-sample.xml")
    ("https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=zh-CN&country=CN&allowCountries=CN"
     . "epic-public-sample.json")
    ("https://rss.nodeseek.com/" . "v2ex-public-sample.xml")
    ("https://www.appinn.com/feed/" . "appinn-public-sample.xml")
    ("https://www.ghxi.com/feed" . "v2ex-public-sample.xml")
    ("https://www.iplaysoft.com/feed" . "iplaysoft-public-sample.xml"))
  "Source URL to fixture file.

NODESEEK and GHXI answer with the V2EX body on purpose: every link in it points
at v2ex.com, so the host gate drops those items and the sources insert nothing.")

(defun fixture-http (&key (routes *fixture-routes*))
  "A *HTTP-GET* replacement serving ROUTES from tests/fixtures."
  (lambda (url &key headers timeout)
    (declare (ignore headers timeout))
    (let ((entry (assoc url routes :test #'string=)))
      (unless entry
        (error "no fixture for ~a" url))
      (values (read-fixture (cdr entry)) 200 nil url))))

(defun failing-http (failing-url &key (routes *fixture-routes*) (status 500))
  "Like FIXTURE-HTTP, except FAILING-URL answers STATUS with no body."
  (lambda (url &key headers timeout)
    (declare (ignore headers timeout))
    (if (string= url failing-url)
        (values "upstream unavailable" status nil url)
        (let ((entry (assoc url routes :test #'string=)))
          (unless entry
            (error "no fixture for ~a" url))
          (values (read-fixture (cdr entry)) 200 nil url)))))

;;; ------------------------------------------------------------------
;;; Environment

(defun set-environment-variable (name value)
  "Set NAME to VALUE, or remove it when VALUE is NIL."
  (if value
      (sb-posix:setenv name value 1)
      (sb-posix:unsetenv name)))

(defmacro with-environment ((name value) &body body)
  (let ((previous (gensym "PREVIOUS")))
    `(let ((,previous (uiop:getenv ,name)))
       (unwind-protect (progn (set-environment-variable ,name ,value) ,@body)
         (set-environment-variable ,name ,previous)))))

;;; ------------------------------------------------------------------
;;; Server

(defun free-port ()
  "A TCP port that was free a moment ago."
  (let ((socket (us:socket-listen "127.0.0.1" 0 :reuse-address nil)))
    (unwind-protect (us:get-local-port socket)
      (us:socket-close socket))))

(defvar *server-port* nil
  "Port of the server the web suite talks to.")

(defmacro with-server ((store) &body body)
  "Serve STORE on a free local port and run BODY."
  `(let ((*server-port* (free-port)))
     (da:start-server :store ,store :host "127.0.0.1" :port *server-port*)
     (unwind-protect (progn ,@body)
       (da:stop-server))))

;;; ------------------------------------------------------------------
;;; HTTP client

(defun read-all (stream)
  (with-output-to-string (out)
    (loop for character = (read-char stream nil nil)
          while character
          do (write-char character out))))

(defun dechunk (body)
  "Decode a chunked transfer body."
  (with-output-to-string (out)
    (let ((position 0)
          (limit (length body))
          (crlf (format nil "~c~c" #\Return #\Linefeed)))
      (loop
        (when (>= position limit) (return))
        (let ((line-end (search crlf body :start2 position)))
          (when (null line-end) (return))
          (let ((size (parse-integer body :start position :end line-end
                                          :radix 16 :junk-allowed t)))
            (when (or (null size) (zerop size)) (return))
            (let ((start (+ line-end 2)))
              (write-string body out :start start :end (min limit (+ start size)))
              (setf position (+ start size 2)))))))))

(defun parse-http-response (raw)
  (let* ((divider (search (format nil "~c~c~c~c" #\Return #\Linefeed #\Return #\Linefeed)
                          raw))
         (head (subseq raw 0 divider))
         (body (subseq raw (+ divider 4)))
         (lines (ppcre:split "\\r\\n" head))
         (headers (loop for line in (rest lines)
                        for colon = (position #\: line)
                        when colon
                          collect (cons (string-downcase (string-trim " " (subseq line 0 colon)))
                                        (string-trim " " (subseq line (1+ colon)))))))
    (list :status (parse-integer (first lines)
                                 :start (1+ (position #\Space (first lines))))
          :headers headers
          :body (if (equal "chunked"
                           (cdr (assoc "transfer-encoding" headers :test #'string=)))
                    (dechunk body)
                    body))))

(defun response-header (response name)
  (cdr (assoc (string-downcase name) (getf response :headers) :test #'string=)))

(defun http (method path &key headers body)
  "Send one HTTP/1.0 request to the server under test.

Returns a plist with :STATUS, :HEADERS as an alist and :BODY."
  (let ((socket (us:socket-connect "127.0.0.1" *server-port* :element-type 'character)))
    (unwind-protect
         (let ((stream (us:socket-stream socket)))
           (format stream "~a ~a HTTP/1.0~c~c" method path #\Return #\Linefeed)
           (format stream "Host: 127.0.0.1:~d~c~c" *server-port* #\Return #\Linefeed)
           (dolist (header headers)
             (format stream "~a: ~a~c~c" (car header) (cdr header) #\Return #\Linefeed))
           (when body
             (format stream "Content-Length: ~d~c~c" (length body) #\Return #\Linefeed))
           (format stream "~c~c" #\Return #\Linefeed)
           (when body (write-string body stream))
           (finish-output stream)
           (parse-http-response (read-all stream)))
      (us:socket-close socket))))

(defun json-body (response)
  (da::parse-json (getf response :body)))

;;; ------------------------------------------------------------------
;;; Runner

(defun run-tests ()
  "Run every suite; signal a failure so ASDF reports one."
  (let ((results (fiveam:run! '(core parsing storage round web))))
    (fiveam:explain! results)
    (unless (fiveam:results-status results)
      (error "deal-aggregator tests failed"))
    t))
