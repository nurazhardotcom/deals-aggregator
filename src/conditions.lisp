;;;; Condition types. The web layer maps these to HTTP status codes in one place.

(in-package #:deal-aggregator)

(define-condition app-error (error)
  ((message :initarg :message
            :initform "operation failed"
            :reader error-message)
   (kind :initarg :kind
         :initform nil
         :reader error-kind))
  (:report (lambda (condition stream)
             (write-string (error-message condition) stream))))

(define-condition guard-error (app-error)
  ((status :initarg :status
           :initform 400
           :reader guard-status))
  (:default-initargs :message "request rejected"))

(define-condition fetch-error (app-error) ()
  (:documentation "An upstream request failed: timeout, oversize body, or a bad status."))

(define-condition parse-failure (app-error) ()
  (:default-initargs :kind :structure)
  (:documentation "An upstream body did not have the expected structure."))

(define-condition db-unavailable (app-error) ()
  (:documentation "The database file cannot be opened or read."))

(define-condition refresh-busy (app-error) ()
  (:documentation "Another refresh round already holds the slot."))

(define-condition refresh-cooldown (app-error)
  ((retry-after-ms :initarg :retry-after-ms
                   :initform 0
                   :reader retry-after-ms))
  (:default-initargs :message "refresh too frequent"))

(define-condition auth-configuration-error (app-error) ()
  (:documentation "The access token is set but unusable; every request is refused."))

(define-condition invalid-pagination (app-error)
  ()
  (:default-initargs :message "invalid pagination parameters"))
