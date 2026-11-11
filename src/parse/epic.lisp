;;;; Epic free-games promotions. The endpoint returns every current and upcoming
;;;; promotion, so the parser keeps only offers that are free and active now.
;;;;
;;;; An empty catalogue is a broken response, not "no free games": returning an
;;;; empty list would delete every stored Epic row on the next refresh.

(in-package #:deal-aggregator)

(defun json-get (object key)
  (and (hash-table-p object) (gethash key object)))

(defun json-list (value)
  "Coerce a JSON array (vector or list) to a fresh list; anything else is NIL."
  (cond ((vectorp value) (coerce value 'list))
        ((and (listp value) value) value)
        (t nil)))

(defun finite-number-p (value)
  (and (numberp value) (not (and (floatp value) (not (zerop value)) (/= value value)))))

(defun epic-elements (payload)
  (let* ((data (json-get payload "data"))
         (catalog (json-get data "Catalog"))
         (store (json-get catalog "searchStore"))
         (elements (json-get store "elements")))
    (unless (json-list elements)
      (error 'parse-failure :message "Epic response has no product list"))
    ;; An empty catalogue means the upstream response broke, not "no free games".
    (when (null (json-list elements))
      (error 'parse-failure :message "Epic product list is empty"))
    (json-list elements)))

(defun epic-offer-groups (element)
  (json-get (json-get element "promotions") "promotionalOffers"))

(defun epic-current-offers (element)
  (loop for group in (json-list (epic-offer-groups element))
        append (json-list (json-get group "promotionalOffers"))))

(defun epic-page-slug (element)
  (let* ((mappings (append (json-list (json-get element "offerMappings"))
                           (json-list (json-get (json-get element "catalogNs") "mappings"))))
         (home (find-if (lambda (mapping)
                          (and (string= (or (json-get mapping "pageType") "") "productHome")
                               (let ((slug (json-get mapping "pageSlug")))
                                 (and (stringp slug) (plusp (length slug))
                                      (not (string= slug "home"))))))
                        mappings)))
    (or (and home (json-get home "pageSlug"))
        (let ((slug (json-get element "productSlug")))
          (and (stringp slug) (plusp (length slug)) slug)))))

(defun validate-epic-element (element)
  (unless (and (hash-table-p element)
               (nth-value 1 (gethash "promotions" element))
               (let ((title (json-get element "title")))
                 (and (stringp title) (plusp (length (string-trim " " title)))))
               (finite-number-p (json-get (json-get (json-get element "price") "totalPrice")
                                          "discountPrice"))
               (let ((promotions (json-get element "promotions")))
                 (or (null promotions)
                       (hash-table-p promotions))))
    (error 'parse-failure :message "Epic product list structure is invalid")))

(defun validate-epic-offer (offer now)
  (declare (ignore now))
  (unless (and (hash-table-p offer)
               (stringp (json-get offer "startDate"))
               (stringp (json-get offer "endDate"))
               (let ((start (parse-timestamp-ms (json-get offer "startDate")))
                     (end (parse-timestamp-ms (json-get offer "endDate"))))
                 (and start end (> end start)))
               (finite-number-p (json-get (json-get offer "discountSetting")
                                          "discountPercentage")))
    (error 'parse-failure :message "Epic promotion structure is invalid")))

(defun epic-active-offers (element now)
  (let ((offers (epic-current-offers element)))
    (dolist (offer offers)
      (validate-epic-offer offer now))
    (loop for offer in offers
          for start = (parse-timestamp-ms (json-get offer "startDate"))
          for end = (parse-timestamp-ms (json-get offer "endDate"))
          for percentage = (json-get (json-get offer "discountSetting") "discountPercentage")
          when (and start end
                     (<= start now) (< now end)
                     (or (= percentage 0) (= percentage 100)))
            collect offer)))

(defun parse-epic (body now)
  "Parse the free-games payload into PARSED-ITEM values.

EPIC encodes a free promotion as discount price 0 with a discount percentage of
0 or 100. The window is half-open: start <= now < end."
  (let ((payload (handler-case (parse-json body)
                   (error () (error 'parse-failure :message "Epic response is not JSON")))))
    (let ((items '())
          (seen (make-hash-table :test #'equal)))
      (dolist (element (epic-elements payload))
        (validate-epic-element element)
        (when (zerop (json-get (json-get (json-get element "price") "totalPrice")
                               "discountPrice"))
          (let ((active (epic-active-offers element now)))
            (when active
              (let* ((slug (epic-page-slug element))
                     (title (clean-title (json-get element "title"))))
                (unless (and slug
                             (not (ppcre:scan "\\.\\." slug))
                             (ppcre:scan "^[a-zA-Z0-9_/-]+$" slug))
                  (error 'parse-failure :message "Epic product link structure is invalid"))
                (unless (plusp (length title))
                  (error 'parse-failure :message "Epic product title is empty"))
                (let ((url (format nil "https://store.epicgames.com/zh-CN/p/~a" slug)))
                  (unless (gethash url seen)
                    (setf (gethash url seen) t)
                    (push (make-parsed-item
                           :url url
                           :title title
                           :summary (excerpt (or (json-get element "description") ""))
                           :published-at (reduce #'min (mapcar (lambda (offer)
                                                                 (parse-timestamp-ms
                                                                  (json-get offer "startDate")))
                                                               active))
                           :expires-at (reduce #'max (mapcar (lambda (offer)
                                                               (parse-timestamp-ms
                                                                (json-get offer "endDate")))
                                                             active)))
                          items))))))))
      (nreverse items))))
