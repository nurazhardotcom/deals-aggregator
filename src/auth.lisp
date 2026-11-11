;;;; Access control: an optional shared token, bearer authentication for scripts,
;;;; and an HMAC-signed session cookie for browsers.

(in-package #:deal-aggregator)

(defparameter +session-cookie-name+ "deal-aggregator-session")
(defparameter +session-prefix+ "deal-aggregator-session:")

;;; ------------------------------------------------------------------
;;; Constant-time comparison

(defun sha256-bytes (string)
  (ironclad:digest-sequence :sha256 (ironclad:ascii-string-to-byte-array string)))

(defun constant-time-bytes= (left right)
  (and (= (length left) (length right))
       (zerop (loop for index below (length left)
                    sum (logxor (aref left index) (aref right index))))))

(defun constant-time-string= (left right)
  (constant-time-bytes= (sha256-bytes (or left ""))
                        (sha256-bytes (or right ""))))

;;; ------------------------------------------------------------------
;;; Sessions

(defun hmac-hex (key message)
  (let ((hmac (ironclad:make-hmac (ironclad:ascii-string-to-byte-array key) :sha256)))
    (ironclad:update-hmac hmac (ironclad:ascii-string-to-byte-array message))
    (string-downcase (ironclad:byte-array-to-hex-string (ironclad:hmac-digest hmac)))))

(defun session-signature (token payload)
  (hmac-hex token (concatenate 'string +session-prefix+ payload)))

(defun create-session (token &key (now (now-ms)))
  (let ((payload (format nil "~d.~a" (+ now +session-ms+) (random-hex-string 16))))
    (format nil "~a.~a" payload (session-signature token payload))))

(defun session-hex-p (string length)
  (and (= (length string) length)
       (every (lambda (character) (digit-char-p character 16)) string)))

(defun valid-session-p (cookie token &key (now (now-ms)))
  (and cookie
       (<= (length cookie) 200)
       (let ((parts (ppcre:split "\\." cookie)))
         (and (= (length parts) 3)
              (let ((expiry (ignore-errors (parse-integer (first parts)))))
                (and expiry
                     (> expiry now)
                     (<= expiry (+ now +session-ms+))
                     (session-hex-p (second parts) 32)
                     (constant-time-string=
                      (third parts)
                      (session-signature token (format nil "~a.~a"
                                                       (first parts) (second parts))))))))))

;;; ------------------------------------------------------------------
;;; Request authorisation

(defun cookie-value (cookie-header name)
  (when cookie-header
    (loop for part in (ppcre:split ";" cookie-header)
          for trimmed = (string-trim '(#\Space #\Tab) part)
          when (and (> (length trimmed) (length name))
                    (string= name trimmed :end2 (length name))
                    (char= #\= (char trimmed (length name))))
            return (string-trim '(#\Space #\Tab #\")
                                (subseq trimmed (1+ (length name)))))))

(defun bearer-value (authorization-header)
  (when (and authorization-header
             (> (length authorization-header) 7)
             (string-equal "Bearer " authorization-header :end2 7))
    (string-trim '(#\Space #\Tab) (subseq authorization-header 7))))

(defun authorized-p (token headers &key (now (now-ms)))
  "True when the request carries a valid bearer token or session cookie.

HEADERS is a plist with :authorization and :cookie entries. A NIL TOKEN means
authentication is disabled and every request is allowed."
  (if (null token)
      t
      (or (let ((bearer (bearer-value (getf headers :authorization))))
            (and bearer (constant-time-string= bearer token)))
          (valid-session-p (cookie-value (getf headers :cookie) +session-cookie-name+)
                           token :now now))))

;;; ------------------------------------------------------------------
;;; Rate limiting

(defstruct (rate-limiter (:constructor %make-rate-limiter))
  (limit 8)
  (window-ms 600000)
  (lock (bt:make-lock "deal-aggregator.ratelimit"))
  (table (make-hash-table :test #'equal)))

(defun make-rate-limiter (&key limit window-ms)
  (%make-rate-limiter :limit limit :window-ms window-ms))

(defun limiter-allow-p (limiter key &key (now (now-ms)))
  "Record one attempt for KEY. False when the budget inside the window is used."
  (bt:with-lock-held ((rate-limiter-lock limiter))
    (let ((table (rate-limiter-table limiter))
          (window (rate-limiter-window-ms limiter)))
      ;; Bound memory: forget keys with no attempt inside the window.
      (when (> (hash-table-count table) 10000)
        (maphash (lambda (stored stamps)
                   (unless (some (lambda (stamp) (< (- now stamp) window)) stamps)
                     (remhash stored table)))
                 table))
      (let ((recent (remove-if (lambda (stamp) (>= (- now stamp) window))
                               (gethash key table))))
        (cond ((>= (length recent) (rate-limiter-limit limiter))
               (setf (gethash key table) recent)
               nil)
              (t
               (push now recent)
               (setf (gethash key table) recent)
               t))))))

(defun reset-rate-limiter (limiter)
  (bt:with-lock-held ((rate-limiter-lock limiter))
    (clrhash (rate-limiter-table limiter)))
  limiter)
