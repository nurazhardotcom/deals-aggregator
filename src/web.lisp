;;;; HTTP layer on Hunchentoot: server-rendered board, JSON API, token login,
;;;; session cookies and the guards around the mutating routes.

(in-package #:deal-aggregator)

(defclass app-acceptor (hunchentoot:acceptor) ())

(defvar *store* nil
  "The store the acceptor serves. Bound by START-SERVER.")

(defvar *acceptor* nil)
(defvar *trust-proxy-headers* nil)

(defvar *login-limiter*
  (make-rate-limiter :limit +login-attempt-limit+
                     :window-ms +login-attempt-window-ms+))

(defvar *manual-limiter*
  (make-rate-limiter :limit +manual-ip-limit+
                     :window-ms +manual-ip-window-ms+))

;;; ------------------------------------------------------------------
;;; Responses

(defun respond (status content-type body &key headers)
  (setf (hunchentoot:return-code*) status
        (hunchentoot:content-type*) content-type
        (hunchentoot:header-out "Cache-Control") "no-store")
  (dolist (pair headers)
    (setf (hunchentoot:header-out (car pair)) (cdr pair)))
  body)

(defun respond-json (status value &key headers)
  (respond status "application/json; charset=utf-8" (to-json value) :headers headers))

(defun respond-html (status html)
  (respond status "text/html; charset=utf-8" html))

(defun redirect (location &key (status 303))
  (setf (hunchentoot:return-code*) status
        (hunchentoot:header-out "Location") location)
  "")

(defun session-cookie-header (value &key max-age)
  (format nil "~a=~a; Path=/; HttpOnly; SameSite=Strict~@[; Max-Age=~d~]~:[~;; Secure~]"
          +session-cookie-name+ value max-age (secure-cookie-p)))

;;; ------------------------------------------------------------------
;;; Request accessors

(defun request-headers-plist ()
  (list :authorization (hunchentoot:header-in* :authorization)
        :cookie (hunchentoot:header-in* :cookie)))

(defun client-address ()
  "Socket address of the client.

Forwarding headers are ignored unless TRUST_PROXY_HEADERS=1, because they are
client-controlled and would let one caller pose as many."
  (if (or *trust-proxy-headers* (env-flag-p "TRUST_PROXY_HEADERS"))
      (or (let ((forwarded (hunchentoot:header-in* :x-forwarded-for)))
            (and forwarded
                 (let ((first (string-trim '(#\Space #\Tab)
                                           (first (ppcre:split "," forwarded)))))
                   (and (plusp (length first)) (subseq first 0 (min 80 (length first)))))))
          (hunchentoot:header-in* :x-real-ip)
          "unknown")
      (or (hunchentoot:remote-addr*) "local")))

(defun assert-same-origin ()
  (when (string-equal (or (hunchentoot:header-in* :sec-fetch-site) "") "cross-site")
    (error 'guard-error :status 403 :message "cross-site request refused"))
  (let ((origin (hunchentoot:header-in* :origin))
        (host (hunchentoot:header-in* :host)))
    (when origin
      (let ((origin-uri (ignore-errors (quri:uri origin))))
        (unless (and host origin-uri
                     (string-equal host (or (quri:uri-authority origin-uri) "")))
          (error 'guard-error :status 403 :message "cross-site request refused"))))))

(defun assert-small-body (limit)
  (let ((length (ignore-errors
                 (parse-integer (or (hunchentoot:header-in* :content-length) "")
                                :junk-allowed t))))
    (when (and length (> length limit))
      (error 'guard-error :status 400 :message "request body too large"))))

(defun parameter-integer (name default &key (minimum 0) (maximum most-positive-fixnum))
  (let ((raw (hunchentoot:get-parameter name)))
    (if (or (null raw) (string= raw ""))
        default
        (let ((value (ignore-errors (parse-integer raw))))
          (unless (and value (integerp value) (>= value minimum) (<= value maximum))
            (error 'invalid-pagination))
          value))))

;;; ------------------------------------------------------------------
;;; Authorisation helpers

(defun require-token ()
  "Return the configured token, or NIL when authentication is disabled."
  (access-token))

(defun require-authorised ()
  (unless (authorized-p (require-token) (request-headers-plist))
    (error 'guard-error :status 401
           :message "authentication required: sign in or send a Bearer token")))

(defun page-authorised-p ()
  (authorized-p (require-token) (request-headers-plist)))

;;; ------------------------------------------------------------------
;;; Routes

(defun get-board-page ()
  (unless (page-authorised-p)
    (return-from get-board-page (redirect "/login")))
  (respond-html 200 (render-board-page (board-state *store*))))

(defun get-login-page ()
  (let ((token (require-token)))
    (cond ((null token) (redirect "/"))
          ((page-authorised-p) (redirect "/"))
          (t (respond-html 200
                           (render-login-page
                            :need-token t
                            :error (let ((code (hunchentoot:get-parameter "error")))
                                     (and code (string= code "invalid")
                                          "That token was not accepted."))))))))

(defun login-succeeded (token)
  (setf (hunchentoot:header-out "Set-Cookie")
        (session-cookie-header (create-session token)
                               :max-age (floor +session-ms+ 1000)))
  (redirect "/"))

(defun post-login ()
  (assert-same-origin)
  (assert-small-body +login-body-limit+)
  (let ((token (require-token)))
    (when (null token)
      (return-from post-login (redirect "/")))
    (unless (limiter-allow-p *login-limiter* (client-address))
      (return-from post-login (redirect "/login?error=invalid")))
    (let ((submitted (or (hunchentoot:post-parameter "token") "")))
      (if (constant-time-string= submitted token)
          (login-succeeded token)
          (redirect "/login?error=invalid")))))

(defun api-deals ()
  (require-authorised)
  (let ((offset (parameter-integer "offset" 0))
        (limit (parameter-integer "limit" +board-page-size+ :minimum 1 :maximum 2000)))
    (respond-json 200
                  (board->json (paginate-board (board-state *store*)
                                               :offset offset :limit limit)))))

(defun api-health ()
  (require-authorised)
  (respond-json 200 (health-report (board-state *store*))))

(defun api-session-state ()
  (let ((token (require-token)))
    (respond-json 200
                  (json-object "authRequired" (and token t)
                               "authenticated" (if token
                                                   (authorized-p token (request-headers-plist))
                                                   t)))))

(defun api-session-login ()
  (assert-same-origin)
  (assert-small-body +login-body-limit+)
  (let ((token (require-token)))
    (when (null token)
      (return-from api-session-login (respond-json 200 (json-object "authRequired" nil))))
    (unless (limiter-allow-p *login-limiter* (client-address))
      (return-from api-session-login
        (respond-json 429 (json-object "error" "too many login attempts"))))
    (let ((submitted (or (hunchentoot:post-parameter "token") "")))
      (if (constant-time-string= submitted token)
          (respond-json 200
                        (json-object "ok" t)
                        :headers (list (cons "Set-Cookie"
                                             (session-cookie-header
                                              (create-session token)
                                              :max-age (floor +session-ms+ 1000)))))
          (respond-json 401 (json-object "error" "invalid token"))))))

(defun api-session-logout ()
  (assert-same-origin)
  (respond 204 "application/json; charset=utf-8" ""
           :headers (list (cons "Set-Cookie"
                                (format nil "~a=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0~:[~;; Secure~]"
                                        +session-cookie-name+ (secure-cookie-p))))))

(defun api-refresh ()
  (require-authorised)
  (assert-same-origin)
  (assert-small-body +manual-refresh-body-limit+)
  (unless (limiter-allow-p *manual-limiter* (client-address))
    (error 'guard-error :status 429 :message "manual refresh rate limit reached"))
  (let ((board (run-refresh *store* :trigger "manual")))
    (respond-json 200 (board->json board))))

(defun route ()
  (let ((method (hunchentoot:request-method*))
        (path (hunchentoot:script-name*)))
    (cond
      ((and (eq method :get) (string= path "/")) (get-board-page))
      ((and (eq method :get) (string= path "/login")) (get-login-page))
      ((and (eq method :post) (string= path "/login")) (post-login))
      ((and (eq method :get) (string= path "/api/deals")) (api-deals))
      ((and (eq method :get) (string= path "/api/health")) (api-health))
      ((and (eq method :get) (string= path "/api/session")) (api-session-state))
      ((and (eq method :post) (string= path "/api/session")) (api-session-login))
      ((and (eq method :delete) (string= path "/api/session")) (api-session-logout))
      ((and (eq method :post) (string= path "/api/refresh")) (api-refresh))
      (t (respond-json 404 (json-object "error" "not found"))))))

(defun error-response (condition)
  (cond
    ((typep condition 'auth-configuration-error)
     (respond-json 503 (json-object "error" (error-message condition))))
    ((typep condition 'db-unavailable)
     (respond-json 503 (json-object "error" "database unreadable")))
    ((typep condition 'refresh-cooldown)
     (respond-json 429 (json-object "error" (error-message condition)
                                    "retryAfterMs" (retry-after-ms condition))
                   :headers (list (cons "Retry-After"
                                        (princ-to-string
                                         (max 1 (ceiling (retry-after-ms condition) 1000)))))))
    ((typep condition 'refresh-busy)
     (respond-json 429 (json-object "error" (error-message condition))))
    ((typep condition 'invalid-pagination)
     (respond-json 400 (json-object "error" (error-message condition))))
    ((typep condition 'guard-error)
     (respond-json (guard-status condition)
                   (json-object "error" (error-message condition))))
    (t
     (log-failure "request_failed" condition)
     (respond-json 500 (json-object "error" "internal error")))))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor app-acceptor) request)
  (declare (ignore request))
  (handler-case (route)
    (serious-condition (condition) (error-response condition))))

;;; ------------------------------------------------------------------
;;; Lifecycle

(defun start-server (&key store (host (listen-host)) (port (listen-port)))
  (when store (setf *store* store))
  (unless *store*
    (error "start-server needs a store"))
  (when (and *acceptor* (hunchentoot:started-p *acceptor*))
    (return-from start-server *acceptor*))
  (setf *acceptor* (make-instance 'app-acceptor
                                  :name "deal-aggregator"
                                  :address host
                                  :port port))
  (hunchentoot:start *acceptor*)
  (log-event "server_started" :host host :port port)
  *acceptor*)

(defun stop-server ()
  (when *acceptor*
    (ignore-errors (hunchentoot:stop *acceptor*))
    (setf *acceptor* nil)
    t))
