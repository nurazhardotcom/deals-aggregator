;;;; LINUX DO welfare category, read through the Jina reader.
;;;;
;;;; The reader returns Markdown, not RSS. Each item is a level 2-4 heading link
;;;; followed by a repeated link line and an RFC 822 date. There is no summary.

(in-package #:deal-aggregator)

(defparameter +linuxdo-heading-scanner+
  (ppcre:create-scanner "^#{2,4} \\[" :multi-line-mode t))

(defparameter +linuxdo-url-scanner+
  (ppcre:create-scanner "^\\]\\((https?://linux\\.do/t/topic/\\d+)\\)"))

(defparameter +linuxdo-date-scanner+
  (ppcre:create-scanner
   "\\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), \\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \\d{4} \\d{2}:\\d{2}:\\d{2} [+-]\\d{4}\\b"))

(defun linuxdo-link (chunk start)
  "Topic link found right after the heading's title, or NIL."
  (multiple-value-bind (match registers)
      (ppcre:scan-to-strings +linuxdo-url-scanner+ (subseq chunk start))
    (declare (ignore match))
    (and registers (plusp (length registers)) (aref registers 0))))

(defun linuxdo-date (chunk)
  (ppcre:scan-to-strings +linuxdo-date-scanner+ chunk))

(defun parse-linuxdo-markdown (markdown now)
  "Parse the Jina Markdown rendering of the LINUX DO welfare category."
  (unless (search "linux.do/t/topic/" markdown)
    (error 'parse-failure :message "response is not the LINUX DO welfare list"))
  (let ((items '()))
    (dolist (chunk (subseq (rest (ppcre:split +linuxdo-heading-scanner+ markdown))
                           0
                           (min (length (rest (ppcre:split +linuxdo-heading-scanner+ markdown)))
                                +max-feed-items+)))
      (let ((title-end (search "](" chunk)))
        (when title-end
          (let ((title (clean-title (subseq chunk 0 title-end)))
                (link (linuxdo-link chunk title-end))
                (date (linuxdo-date chunk)))
            (when (and (plusp (length title)) link date)
              (push (make-parsed-item :url link :title title :summary ""
                                      :published-at (publish-time date now)
                                      :expires-at nil)
                    items))))))
    (when (null items)
      (error 'parse-failure :message "no items parsed from the LINUX DO Markdown"))
    (nreverse items)))
