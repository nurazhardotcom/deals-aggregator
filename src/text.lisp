;;;; Text cleanup for untrusted feed content: entity decoding, tag stripping,
;;;; terminal noise removal, truncation.

(in-package #:deal-aggregator)

(defparameter +ansi-scanner+
  (ppcre:create-scanner (format nil "~c\\[[0-9;]*[A-Za-z]" #\Escape))
  "Colour escapes from scraped terminal output.")

(defparameter +sgr-leftover-scanner+
  (ppcre:create-scanner "\\[[0-9;]{1,8}m")
  "SGR sequences whose ESC byte the upstream source already stripped.")

(defparameter +csi-leftover-scanner+
  (ppcre:create-scanner "\\[[0-9;]{0,4}[HJK]")
  "Cursor and screen CSI fragments; the final byte is restricted so ordinary text survives.")

(defparameter +cdata-scanner+
  (ppcre:create-scanner "<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>"))

(defparameter +script-scanner+
  (ppcre:create-scanner "<script[\\s\\S]*?</script>" :case-insensitive-mode t))

(defparameter +style-scanner+
  (ppcre:create-scanner "<style[\\s\\S]*?</style>" :case-insensitive-mode t))

(defparameter +tag-scanner+ (ppcre:create-scanner "<[^>]+>"))
(defparameter +padding-scanner+ (ppcre:create-scanner "[+*=_~#]{8,}"))
(defparameter +space-run-scanner+ (ppcre:create-scanner "\\s+"))

(defun decode-entities (string)
  (let ((text (ppcre:regex-replace-all +cdata-scanner+ string "\\1")))
    (setf text (ppcre:regex-replace-all "(?i)&nbsp;" text " "))
    (setf text (ppcre:regex-replace-all "(?i)&lt;" text "<"))
    (setf text (ppcre:regex-replace-all "(?i)&gt;" text ">"))
    (setf text (ppcre:regex-replace-all "(?i)&quot;" text "\""))
    (setf text (ppcre:regex-replace-all "(?i)&(?:#39|apos);" text "'"))
    (setf text (ppcre:regex-replace-all "(?i)&amp;" text "&"))
    (setf text (ppcre:regex-replace-all
                "&#(\\d+);" text
                (lambda (match digits)
                  (declare (ignore match))
                  (let ((code (parse-integer digits)))
                    (if (and (> code 0) (<= code #x10ffff))
                        (string (code-char code))
                        "")))))
    (setf text (ppcre:regex-replace-all
                "(?i)&#x([0-9a-f]+);" text
                (lambda (match digits)
                  (declare (ignore match))
                  (let ((code (parse-integer digits :radix 16)))
                    (if (and (> code 0) (<= code #x10ffff))
                        (string (code-char code))
                        "")))))
    text))

(defun strip-control-characters (string)
  (map 'string
       (lambda (character)
         (let ((code (char-code character)))
           (if (or (< code 32) (= code 127))
               #\Space
               character)))
       string))

(defun to-plain (input)
  "Decode entities, drop tags and terminal noise, and collapse whitespace.

Does not invent text: an empty input yields an empty string."
  (let ((text (decode-entities (or input ""))))
    (setf text (ppcre:regex-replace-all +ansi-scanner+ text " "))
    (setf text (ppcre:regex-replace-all +sgr-leftover-scanner+ text " "))
    (setf text (ppcre:regex-replace-all +csi-leftover-scanner+ text " "))
    (setf text (ppcre:regex-replace-all +script-scanner+ text " "))
    (setf text (ppcre:regex-replace-all +style-scanner+ text " "))
    (setf text (ppcre:regex-replace-all +tag-scanner+ text " "))
    (setf text (strip-control-characters text))
    (setf text (ppcre:regex-replace-all +padding-scanner+ text " "))
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (ppcre:regex-replace-all +space-run-scanner+ text " "))))

(defun truncate-chars (string max &key ellipsis)
  (if (<= (length string) max)
      string
      (concatenate 'string
                   (string-right-trim '(#\Space #\Tab)
                                      (subseq string 0 max))
                   (or ellipsis ""))))

(defun clean-title (input)
  (truncate-chars (to-plain input) +title-max+))

(defun excerpt (input &optional (max +summary-max+))
  (let ((plain (to-plain input)))
    (if (<= (length plain) max)
        plain
        (concatenate 'string
                     (string-right-trim '(#\Space #\Tab) (subseq plain 0 max))
                     "…"))))
