;;;; HTTP layer: routes, authentication guards, pagination limits, session
;;;; cookies and the manual refresh cooldown.

(in-package #:deal-aggregator/tests)

(def-suite web :description "Routes, guards, pagination, sessions, manual refresh.")
(in-suite web)

(defparameter *web-token* "test-token-0123456789abcdef0123456789abcdef")

(defun bearer (token)
  (list (cons "Authorization" (concatenate 'string "Bearer " token))))

(defun form-headers ()
  '(("Content-Type" . "application/x-www-form-urlencoded")))

(defun seeded-store ()
  "A store holding one finished round built from the fixture sources."
  (let ((store (da:open-store ":memory:")))
    (with-clock (*now*)
      (da:run-refresh store :trigger "boot" :now *now* :fetch-function (fixture-http)))
    store))

(test session-signature
  (let* ((token *web-token*)
         (now *now*)
         (cookie (da::create-session token :now now)))
    (is (da::valid-session-p cookie token :now now))
    (is (not (da::valid-session-p cookie
                                  "another-token-0123456789abcdef0123456789abcdef"
                                  :now now)))
    (is (not (da::valid-session-p cookie token :now (+ now da::+session-ms+ 1))))
    (is (not (da::valid-session-p (concatenate 'string cookie "x") token :now now)))
    (is (not (da::valid-session-p nil token :now now)))))

(test bearer-and-cookie-authorisation
  (let ((token *web-token*))
    (is (da::authorized-p token (list :authorization (format nil "Bearer ~a" token)
                                      :cookie nil)))
    (is (not (da::authorized-p token (list :authorization "Bearer nope" :cookie nil))))
    (is (da::authorized-p nil (list :authorization nil :cookie nil)))))

(test rate-limiter
  (let ((limiter (da::make-rate-limiter :limit 2 :window-ms 1000)))
    (is (da::limiter-allow-p limiter "ip" :now 0))
    (is (da::limiter-allow-p limiter "ip" :now 0))
    (is (not (da::limiter-allow-p limiter "ip" :now 0)))
    (is (da::limiter-allow-p limiter "ip" :now 1000))))

(test api-without-token
  (let ((store (seeded-store)))
    (unwind-protect
         (with-server (store)
           (let* ((response (http "GET" "/api/session"))
                  (body (json-body response)))
             (is (= 200 (getf response :status)))
             (is (null (gethash "authRequired" body)))
             (is (eq t (gethash "authenticated" body))))
           (let* ((response (http "GET" "/api/deals"))
                  (body (json-body response))
                  (pagination (gethash "pagination" body)))
             (is (= 200 (getf response :status)))
             (is (search "application/json" (response-header response "content-type")))
             (is (plusp (length (gethash "deals" body))))
             (is (= 0 (gethash "offset" pagination)))
             (is (= 500 (gethash "limit" pagination))))
           (let* ((response (http "GET" "/api/deals?offset=1&limit=2"))
                  (body (json-body response))
                  (pagination (gethash "pagination" body)))
             (is (= 200 (getf response :status)))
             (is (= 2 (length (gethash "deals" body))))
             (is (= 1 (gethash "offset" pagination)))
             (is (eq t (gethash "hasMore" pagination))))
           (is (= 400 (getf (http "GET" "/api/deals?limit=0") :status)))
           (is (= 400 (getf (http "GET" "/api/deals?offset=abc") :status)))
           (is (= 400 (getf (http "GET" "/api/deals?limit=20000") :status)))
           (is (= 404 (getf (http "GET" "/nope") :status)))
           (is (= 200 (getf (http "GET" "/api/health") :status)))
           (let ((page (http "GET" "/")))
             (is (= 200 (getf page :status)))
             (is (search "<title>deal-aggregator</title>" (getf page :body)))))
      (da:close-store store))))

(test auth-guards
  (let ((store (seeded-store)))
    (unwind-protect
         (with-environment ("DEAL_AGGREGATOR_ACCESS_TOKEN" *web-token*)
           (with-server (store)
             (is (= 401 (getf (http "GET" "/api/deals") :status)))
             (is (= 401 (getf (http "GET" "/api/deals"
                                    :headers (bearer "wrong-token-0123456789abcdef0123456789abcdef"))
                               :status)))
             (is (= 200 (getf (http "GET" "/api/deals"
                                    :headers (bearer *web-token*))
                               :status)))
             (let ((root (http "GET" "/")))
               (is (= 303 (getf root :status)))
               (is (string= "/login" (response-header root "location"))))
             (let ((login (http "GET" "/login")))
               (is (= 200 (getf login :status)))
               (is (search "Sign in" (getf login :body))))
             (is (= 401 (getf (http "POST" "/api/session"
                                    :headers (form-headers)
                                    :body "token=wrong")
                               :status)))
             (let* ((login (http "POST" "/api/session"
                                 :headers (form-headers)
                                 :body (format nil "token=~a" *web-token*)))
                    (cookie (response-header login "set-cookie"))
                    (prefix "deal-aggregator-session=")
                    (value (subseq cookie (length prefix) (position #\; cookie))))
               (is (= 200 (getf login :status)))
               (is (eq t (gethash "ok" (json-body login))))
               (is (search prefix cookie))
               (is (= 200 (getf (http "GET" "/api/deals"
                                      :headers (list (cons "Cookie"
                                                           (format nil "~a~a" prefix value))))
                                 :status)))
               (is (= 200 (getf (http "GET" "/"
                                      :headers (list (cons "Cookie"
                                                           (format nil "~a~a" prefix value))))
                                 :status)))
               (is (= 204 (getf (http "DELETE" "/api/session") :status))))
             (is (= 403 (getf (http "POST" "/api/session"
                                    :headers (append (form-headers)
                                                     '(("Sec-Fetch-Site" . "cross-site")))
                                    :body "token=x")
                               :status)))))
      (da:close-store store))))

(test manual-refresh-cooldown
  (let ((store (seeded-store))
        (previous da::*http-get*))
    (setf da::*http-get* (fixture-http))
    (unwind-protect
         (with-server (store)
           (is (= 200 (getf (http "POST" "/api/refresh") :status)))
           (let* ((second-call (http "POST" "/api/refresh"))
                  (body (json-body second-call)))
             (is (= 429 (getf second-call :status)))
             (is (response-header second-call "retry-after"))
             (is (plusp (gethash "retryAfterMs" body)))))
      (setf da::*http-get* previous)
      (da:close-store store))))
