;;;; URL canonicalisation and the source host gate.

(in-package #:deal-aggregator)

(defparameter +tracking-parameter-scanner+
  (ppcre:create-scanner
   "^(?:utm_.*|spm|spm_.*|ref|fbclid|gclid|mc_.*)$"
   :case-insensitive-mode t))

(defun tracking-parameter-p (name)
  (and (ppcre:scan +tracking-parameter-scanner+ name) t))

(defun canonical-url (raw)
  "Return the canonical form of RAW, used as the deduplication key.

Signals PARSE-FAILURE for anything that is not a plain http(s) article URL: wrong
scheme, credentials in the authority, or a missing host."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) (or raw ""))))
    (when (or (zerop (length trimmed))
              (> (length trimmed) +max-url-chars+))
      (error 'parse-failure :message "invalid item link"))
    (let ((uri (ignore-errors (quri:uri trimmed))))
      (unless (and uri (quri:uri-p uri))
        (error 'parse-failure :message "invalid item link"))
      (let ((scheme (quri:uri-scheme uri))
            (host (quri:uri-host uri)))
        (unless (and scheme
                     (member (string-downcase scheme) '("http" "https") :test #'string=)
                     host
                     (plusp (length host))
                     (null (quri:uri-userinfo uri)))
          (error 'parse-failure :message "invalid item link"))
        (let* ((params (ignore-errors (quri:uri-query-params uri)))
               (kept (and params
                          (remove-if (lambda (pair) (tracking-parameter-p (car pair)))
                                     params)))
               (query (when kept
                        (quri:url-encode-params (sort (copy-list kept) #'string< :key #'car))))
               (path (quri:uri-path uri))
               (path (if (and path (> (length path) 1))
                         (string-right-trim "/" path)
                         path)))
            (quri:render-uri (quri:copy-uri uri
                                            :scheme (string-downcase scheme)
                                            :host (string-downcase host)
                                            :query query
                                            :path path
                                            :fragment nil)))))))

(defun url-host (url)
  (let ((uri (ignore-errors (quri:uri url))))
    (and uri (quri:uri-host uri) (string-downcase (quri:uri-host uri)))))

(defun host-allowed-p (host allowed-hosts)
  "True when HOST is one of ALLOWED-HOSTS or a subdomain of one."
  (and host
       (let ((host (string-downcase host)))
         (some (lambda (allowed)
                 (let ((allowed (string-downcase allowed)))
                   (or (string= host allowed)
                       (let ((suffix (concatenate 'string "." allowed)))
                         (and (> (length host) (length suffix))
                              (string= suffix host
                                       :start2 (- (length host) (length suffix))))))))
               allowed-hosts))))

(defun source-url-allowed-p (url source)
  (host-allowed-p (url-host url) (source-allowed-hosts source)))
