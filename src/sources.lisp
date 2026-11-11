;;;; The fixed source registry. Callers cannot substitute URLs: every source is
;;;; declared here with its allowed hosts, and item links leaving those hosts are
;;;; dropped rather than published.

(in-package #:deal-aggregator)

(defstruct (source (:constructor make-source))
  id
  name
  url
  allowed-hosts
  format)

(defparameter *sources* '()
  "Source definitions in declaration order, which is also display order.")

(defparameter +source-formats+ '(:feed :epic :markdown))

(defun register-source (source)
  "Add SOURCE to the registry, rejecting duplicates and malformed definitions."
  (unless (and (source-id source) (plusp (length (source-id source))))
    (error "source definition needs an id"))
  (unless (and (source-url source) (plusp (length (source-url source))))
    (error "source ~a needs a url" (source-id source)))
  (unless (and (source-allowed-hosts source)
               (every (lambda (host) (and (stringp host) (plusp (length host))))
                      (source-allowed-hosts source)))
    (error "source ~a needs a non-empty allowed host list" (source-id source)))
  (unless (member (source-format source) +source-formats+)
    (error "source ~a has unknown format ~s" (source-id source) (source-format source)))
  (when (find (source-id source) *sources* :key #'source-id :test #'string=)
    (error "duplicate source id ~a" (source-id source)))
  (setf *sources* (append *sources* (list source)))
  source)

(defmacro define-source (id &key name url allowed-hosts format)
  "Declare one fixed source."
  `(register-source (make-source :id ,(string-downcase (symbol-name id))
                                 :name ,name
                                 :url ,url
                                 :allowed-hosts ',allowed-hosts
                                 :format ,format)))

(defun find-source (id)
  (find id *sources* :key #'source-id :test #'string=))

(defun source-name (id-or-source)
  "Display name for a source id string or a SOURCE struct."
  (if (typep id-or-source 'source)
      (slot-value id-or-source 'name)
      (or (let ((source (find-source id-or-source)))
            (and source (slot-value source 'name)))
          id-or-source)))

(define-source linuxdo
  :name "LINUX DO 福利羊毛"
  :url "https://r.jina.ai/https://linux.do/c/welfare/36.rss"
  :allowed-hosts ("linux.do")
  :format :markdown)

(define-source v2ex
  :name "V2EX 推广"
  :url "https://www.v2ex.com/feed/promotions.xml"
  :allowed-hosts ("v2ex.com")
  :format :feed)

(define-source epic
  :name "Epic"
  :url "https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=zh-CN&country=CN&allowCountries=CN"
  :allowed-hosts ("store.epicgames.com")
  :format :epic)

(define-source nodeseek
  :name "NodeSeek"
  :url "https://rss.nodeseek.com/"
  :allowed-hosts ("nodeseek.com")
  :format :feed)

(define-source appinn
  :name "小众软件"
  :url "https://www.appinn.com/feed/"
  :allowed-hosts ("appinn.com")
  :format :feed)

(define-source ghxi
  :name "果核剥壳"
  :url "https://www.ghxi.com/feed"
  :allowed-hosts ("ghxi.com")
  :format :feed)

(define-source iplaysoft
  :name "异次元软件世界"
  :url "https://www.iplaysoft.com/feed"
  :allowed-hosts ("iplaysoft.com")
  :format :feed)

;;; ------------------------------------------------------------------
;;; Normalised item, the single shape every parser produces

(defstruct (parsed-item (:constructor make-parsed-item))
  url
  title
  (summary "")
  published-at
  expires-at)
