;;;; RSS 2.0 and Atom parsing on top of Plump.
;;;;
;;;; Feeds are untrusted: a document that is actually an HTML challenge page
;;;; fails instead of turning into deals, and item count is capped.

(in-package #:deal-aggregator)

(defun xml-element-p (node)
  (typep node 'plump:element))

(defun xml-children (node)
  (let ((children (ignore-errors (plump:children node))))
    (if children (coerce children 'list) '())))

(defun xml-local-name (node)
  (let* ((name (plump:tag-name node))
         (colon (position #\: name)))
    (string-downcase (if colon (subseq name (1+ colon)) name))))

(defun xml-named-children (node name)
  (remove-if-not (lambda (child)
                   (and (xml-element-p child)
                        (string= (xml-local-name child) name)))
                 (xml-children node)))

(defun xml-named-child (node name)
  (first (xml-named-children node name)))

(defun xml-find (node name &optional (depth 5))
  "First descendant element named NAME, case-insensitively, without namespace prefix."
  (cond
    ((xml-element-p node)
     (or (when (string= (xml-local-name node) name) node)
         (when (plusp depth)
           (loop for child in (xml-children node)
                 for found = (xml-find child name (1- depth))
                 when found return found))))
    ((plusp depth)
     (loop for child in (xml-children node)
           for found = (xml-find child name (1- depth))
           when found return found))
    (t nil)))

(defun xml-text (node)
  (or (ignore-errors (plump:text node)) ""))

(defun xml-child-text (element name)
  "Trimmed text of child NAME, or NIL when missing or blank."
  (let ((child (xml-named-child element name)))
    (when child
      (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return)
                               (xml-text child))))
        (and (plusp (length text)) text)))))

(defun xml-direct-url (element)
  "First http(s) URL in ELEMENT's direct text children.

Plump treats RSS <link> as a void HTML element, so the URL lands as a
sibling text node instead of inside the element."
  (loop for child in (xml-children element)
        for text = (string-trim '(#\Space #\Tab #\Newline #\Return)
                                (or (ignore-errors (plump:text child)) ""))
        when (and (not (xml-element-p child))
                  (> (length text) 8)
                  (or (and (>= (length text) 7)
                           (string-equal "http://" text :end1 7 :end2 (min 7 (length text))))
                      (and (>= (length text) 8)
                           (string-equal "https://" text :end1 8 :end2 (min 8 (length text))))))
        return text))

(defun xml-link (element)
  "Link target of an RSS <link> element or an Atom <link href=.../> element."
  (let* ((links (xml-named-children element "link"))
         (alternate (find-if (lambda (link)
                               (string= (or (plump:attribute link "rel") "") "alternate"))
                             links))
         (chosen (or alternate (first links))))
    (when chosen
      (or (let ((href (plump:attribute chosen "href")))
            (and href (plusp (length href)) href))
          (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return)
                                   (xml-text chosen))))
            (and (plusp (length text)) text))
          (xml-direct-url element)))))

(defun feed-item (element now)
  (let* ((title (clean-title (xml-text (xml-named-child element "title"))))
         (url (xml-link element))
         (summary-source (or (xml-child-text element "description")
                             (xml-child-text element "summary")
                             (xml-child-text element "encoded")
                             (xml-child-text element "content")
                             ""))
         (published (or (publish-time (xml-text (xml-named-child element "pubdate")) now)
                        (publish-time (xml-text (xml-named-child element "published")) now)
                        (publish-time (xml-text (xml-named-child element "updated")) now)
                        (publish-time (xml-text (xml-named-child element "date")) now))))
    (when (and url (plusp (length title)))
      (make-parsed-item :url url :title title
                        :summary (excerpt summary-source)
                        :published-at published
                        :expires-at nil))))

(defun parse-feed (xml now)
  "Parse an RSS 2.0 or Atom document into PARSED-ITEM values.
Signals PARSE-FAILURE when the body is not a feed."
  (let ((head (string-downcase (subseq xml 0 (min 400 (length xml))))))
    (when (or (search "<!doctype html" head) (search "<html" head))
      (error 'parse-failure :message "response is a web page, not a feed")))
  (let* ((root (handler-case (plump:parse xml)
                 (error ()
                   (error 'parse-failure :message "could not parse RSS/Atom"))))
         (rss (xml-find root "rss"))
         (atom (xml-find root "feed"))
         (records (cond ((and rss (xml-named-child rss "channel"))
                         (xml-named-children (xml-named-child rss "channel") "item"))
                        (atom (xml-named-children atom "entry"))
                        (t (error 'parse-failure :message "could not parse RSS/Atom")))))
    (loop for element in (subseq records 0 (min (length records) +max-feed-items+))
          for item = (feed-item element now)
          when item collect item)))
