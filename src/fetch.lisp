;;;; Network access. One request per source per round, bounded by a timeout and a
;;;; response-size cap; failures are per source and never abort a round.

(in-package #:deal-aggregator)

(defvar *http-get* nil
  "Test hook: a function (url &key headers timeout) returning
\(values body status headers final-url). NIL uses Dexador.")

(defun header-value (headers name)
  (when headers
    (cond ((hash-table-p headers)
           (or (gethash name headers)
               (gethash (string-downcase name) headers)))
          ((listp headers)
           (cdr (assoc name headers :test #'string-equal)))
          (t nil))))

(defun header-int (headers name)
  (let ((value (header-value headers name)))
    (when value
      (ignore-errors (parse-integer (princ-to-string value) :junk-allowed t)))))

(defun dexador-get (url &key headers timeout)
  (dex:get url
           :headers headers
           :read-timeout (/ timeout 1000)
           :connect-timeout (min 10 (/ timeout 1000))
           :force-string t
           :max-redirects 5))

(defun retry-after-seconds (headers)
  (let ((value (header-value headers "retry-after")))
    (when (and value (plusp (length value)) (every #'digit-char-p value))
      (min (parse-integer value) (floor +max-retry-after-ms+ 1000)))))

(defun fetch-source (source &key (timeout +source-timeout-ms+) (accept nil))
  "Fetch SOURCE, returning (values body final-url).

Signals FETCH-ERROR on a bad status, an oversize body, or a transport failure."
  (let ((headers (list (cons "Accept" (or accept "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"))
                       (cons "User-Agent" (user-agent)))))
    (multiple-value-bind (body status response-headers final-url)
        (handler-case
            (funcall (or *http-get* #'dexador-get) (source-url source)
                     :headers headers :timeout timeout)
          (error (condition)
            (error 'fetch-error
                   :kind :transport
                   :message (format nil "~a" condition))))
      (let ((status (and status (parse-integer (princ-to-string status) :junk-allowed t))))
        (unless (and status (<= 200 status 299))
          (let ((retry (and (= status 429) (retry-after-seconds response-headers))))
            (error 'fetch-error
                   :kind (if (= status 429) :rate-limited :http)
                   :message (if retry
                                (format nil "HTTP ~a (retry after ~as)" status retry)
                                (format nil "HTTP ~a" (or status "unknown"))))))
        (let ((body (or body "")))
          (when (> (length body) +max-response-chars+)
            (error 'fetch-error :kind :oversize :message "response too large"))
          (values body
                  (or (and final-url (princ-to-string final-url))
                      (source-url source))))))))
