;;;; Shared helpers: the wall clock, timestamp parsing and formatting, logging,
;;;; and a small JSON vocabulary on top of yason.

(in-package #:deal-aggregator)

;;; ------------------------------------------------------------------
;;; Clock

(defvar *clock* nil
  "Optional function returning epoch milliseconds. Bound in tests to freeze time.")

(defun real-now-ms ()
  #+sbcl (multiple-value-bind (seconds microseconds) (sb-ext:get-time-of-day)
           (+ (* seconds 1000) (floor microseconds 1000)))
  #-sbcl (* 1000 (get-universal-time)))

(defun now-ms ()
  "Current time as epoch milliseconds."
  (if *clock* (funcall *clock*) (real-now-ms)))

;;; ------------------------------------------------------------------
;;; Timestamps

(defparameter +month-numbers+
  '(("jan" . 1) ("feb" . 2) ("mar" . 3) ("apr" . 4) ("may" . 5) ("jun" . 6)
    ("jul" . 7) ("aug" . 8) ("sep" . 9) ("oct" . 10) ("nov" . 11) ("dec" . 12)))

(defparameter +rfc822-scanner+
  (ppcre:create-scanner
   (concatenate 'string
                "(?:(?:mon|tue|wed|thu|fri|sat|sun),?[ \t]+)?"
                "(\\d{1,2})[ \t]+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[ \t]+(\\d{4})"
                "[ \t]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?"
                "[ \t]*(gmt|ut|utc|z|[+-]\\d{4})")
   :case-insensitive-mode t))

(defun zone-offset-seconds (zone)
  (cond ((null zone) 0)
        ((member (string-downcase zone) '("gmt" "ut" "utc" "z") :test #'string=) 0)
        (t (let ((sign (if (char= (char zone 0) #\-) -1 1))
                 (hours (parse-integer zone :start 1 :end 3))
                 (minutes (parse-integer zone :start 3 :end 5)))
             (* sign (+ (* hours 3600) (* minutes 60)))))))

(defun encode-utc-universal-time (second minute hour day month year)
  "Universal time of the given wall-clock fields read as UTC."
  (encode-universal-time second minute hour day month year 0))

(defun universal-time-to-epoch-ms (universal)
  (* 1000 (- universal 2208988800)))

(defun parse-rfc822-ms (text)
  "Parse an RFC 822 / RFC 1123 timestamp such as
\"Mon, 03 Nov 2025 10:00:00 +0800\" or \"03 Nov 2025 10:00:00 GMT\"."
  (multiple-value-bind (match registers)
      (ppcre:scan-to-strings +rfc822-scanner+ text)
    (when match
      (destructuring-bind (day month-name year hour minute second zone) (coerce registers 'list)
        (let* ((month (cdr (assoc (string-downcase month-name) +month-numbers+
                                  :test #'string=)))
               (universal (encode-utc-universal-time (or (and second (parse-integer second)) 0)
                                                     (parse-integer minute)
                                                     (parse-integer hour)
                                                     (parse-integer day)
                                                     month
                                                     (parse-integer year))))
          (universal-time-to-epoch-ms (- universal (zone-offset-seconds zone))))))))

(defun parse-timestamp-ms (text)
  "Parse an ISO 8601 or RFC 822 timestamp into epoch milliseconds, or NIL."
  (when (and text (stringp text))
    (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
      (when (plusp (length trimmed))
        (or (let ((timestamp (ignore-errors (local-time:parse-timestring trimmed))))
              (when timestamp
                (* 1000 (local-time:timestamp-to-unix timestamp))))
            (parse-rfc822-ms trimmed))))))

(defun publish-time (text now)
  "Publish instant for an untrusted timestamp, or NIL when absent or implausible."
  (let ((ms (parse-timestamp-ms text)))
    (when (and ms
               (>= ms +min-publish-ms+)
               (<= ms (+ now +future-publish-tolerance-ms+)))
      ms)))

(defun format-beijing (ms)
  "Format epoch milliseconds as Beijing wall-clock time, \"YYYY-MM-DD HH:mm\"."
  (when ms
    (local-time:format-timestring
     nil
     (local-time:unix-to-timestamp (+ (floor ms 1000) (* 8 3600)))
     :timezone local-time:+utc-zone+
     :format '((:year 4) #\- (:month 2) #\- (:day 2) #\Space (:hour 2) #\: (:min 2)))))

(defun iso-string (ms)
  "Format epoch milliseconds as an ISO 8601 UTC instant with millisecond precision."
  (when ms
    (format nil "~a.~3,'0dZ"
            (local-time:format-timestring
             nil (local-time:unix-to-timestamp (floor ms 1000))
             :timezone local-time:+utc-zone+
             :format '((:year 4) #\- (:month 2) #\- (:day 2) #\T
                       (:hour 2) #\: (:min 2) #\: (:sec 2)))
            (mod ms 1000))))

;;; ------------------------------------------------------------------
;;; Logging

(defun log-event (event &rest fields)
  "Write one structured line to standard output."
  (format *standard-output* "~&~a ~a~{ ~a=~a~}~%"
          (iso-string (now-ms)) event fields)
  (finish-output *standard-output*))

(defun log-failure (event condition &rest fields)
  (apply #'log-event event :error (princ-to-string condition) fields))

;;; ------------------------------------------------------------------
;;; JSON

(defun json-object (&rest pairs)
  "Build a JSON object from alternating string keys and values."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key table) value))
    table))

(defun json-array (sequence)
  "Build a JSON array from SEQUENCE, a list or vector. Empty yields []."
  (coerce (if (vectorp sequence) (coerce sequence 'list) sequence) 'vector))

(defun json-true-p (value)
  "Boolean VALUE as T or YASON:FALSE, so false encodes as false, not null."
  (if value t yason:false))

(defun to-json (value)
  "Serialise VALUE. NIL is JSON null, T is true, YASON:FALSE is false."
  (with-output-to-string (stream)
    (yason:encode value stream)))

(defun parse-json (text)
  (yason:parse text))
