;;;; Title-signal classification, ported rule for rule from the reference
;;;; implementation. It is a display heuristic over titles only: it never
;;;; asserts that an offer is real, still valid, or claimable.

(in-package #:deal-aggregator)

(defparameter +strong-scanner+
  (ppcre:create-scanner
   (concatenate 'string
                "限免|免费领|优惠[码券]|折扣码|兑换码|大促|促销|特价|降价|打折|爆降|折扣|永免|"
                "白嫖|秒杀|立减|满减|返现|返利|半价|史低|新低|羊毛|薅|红包|福利|赠送|"
                "买一送一|首月|黑五|双十一|双\\s*11|(?:^|[^\\d.])\\d(?:\\.\\d)?\\s*折|"
                "[0零]\\s*元(?:购|领|撸|体验|试用)"))
  "Wording that states an offer outright. Worth 5: survives one question mark.")

(defparameter +medium-scanner+
  (ppcre:create-scanner
   (concatenate 'string
                "免费|优惠|(?:注册|新人|新用户|评论|留言)[^，。,.!！]{0,6}送|"
                "送[^，。,.!！]{0,8}(?:额度|会员|流量|时长|积分|余额)|体验额度|低至|"
                "\\d+\\s*%\\s*off")
   :case-insensitive-mode t)
  "Weaker hints. Worth 3: enough on their own, not enough against a question.")

(defparameter +freebie-scanner+
  (ppcre:create-scanner
   (concatenate 'string
                "白嫖|免费|永免|赠送|羊毛|薅|红包|福利|返现|返利|体验额度|"
                "送[^，。,.!！]{0,8}(?:额度|会员|流量|时长|积分|余额)|[0零]\\s*元")))

(defparameter +request-scanner+
  (ppcre:create-scanner
   (concatenate 'string
                "(?:^|[\\s【\\[])(?:收|求)(?:购|助|一个|一下|个)?"
                "(?:[A-Za-z0-9._-]{0,16}|团队|管理员|家庭|企业|共享|朋友|个人|学生|开发者|机场)?"
                "[\\s:：]*(?:优惠码|会员|账号|主机|路由器|套餐|商品|上车|自建)"))
  "Purchase requests: 收/求 plus a target, where the target may follow a short brand word.")

(defparameter +trade-scanner+
  (ppcre:create-scanner
   (concatenate 'string
                "(?:^|[【\\[])\\s*(?:出|收)\\s*(?:[】\\]]|\\s|\\d|个|一|台|张|几)|"
                "(?:^|[\\s+＋【\\[])\\d+(?:\\.\\d+)?\\s*(?:元|块|刀|[rRuU¥$])?\\s*(?:出|收)"
                "(?![现来去入到集藏获录费益购])|"
                "清机出|(?:总价|打包|溢价|原价|平价|折价)\\s*\\d*\\s*(?:元|刀|[rRuU])?\\s*(?:出|收)|"
                "车找人|人找车|拼车|合租"))
  "Second-hand trading: someone selling to someone else, not an offer.")

(defparameter +hard-noise-scanner+
  (ppcre:create-scanner "抽奖|开奖|抽取|求购|收购|求助"))

(defparameter +editorial-scanner+
  (ppcre:create-scanner "闲聊|讨论|新闻|资讯|评测|测评|避雷|吐槽|预测"))

(defparameter +question-scanner+
  (ppcre:create-scanner
   "有没有|有无|是否|请问|能不能|可不可以|为什么|为啥|怎么|如何|有什么|什么价|是啥|哪里有|哪个好|吗\\s*[?？]|吗\\s*$"))

(defparameter +membership-scanner+ (ppcre:create-scanner "会员|订阅|套餐"))
(defparameter +game-scanner+ (ppcre:create-scanner "游戏|喜加一"))
(defparameter +limited-free-scanner+ (ppcre:create-scanner "限免|免费领"))
(defparameter +question-mark-scanner+ (ppcre:create-scanner "[?？]"))

(defparameter +category-labels+
  '((:freebie . "免费白嫖")
    (:limited-free . "限免")
    (:low-price . "低价优惠")
    (:membership . "会员订阅")
    (:game . "游戏")
    (:other . "其他"))
  "Stable category identifiers mapped to the labels the source feeds use.")

(defparameter +category-ids+ '(:freebie :limited-free :low-price :membership :game :other))

(defun category-label (category)
  (or (cdr (assoc category +category-labels+)) "其他"))

(defun category-from-label (label)
  (or (car (rassoc label +category-labels+ :test #'string=)) :other))

(defun category-id (value)
  "Coerce VALUE, an identifier or a label, to a category keyword."
  (cond ((member value +category-ids+) value)
        ((stringp value)
         (or (find (string-downcase value) +category-ids+
                   :test #'string-equal :key #'symbol-name)
             (category-from-label value)))
        (t :other)))

(defun word-token-p (title word)
  "True when WORD appears in TITLE as a Latin word, not inside a longer run."
  (ppcre:scan (format nil "(?i)(?:^|[^A-Za-z])~a(?:[^A-Za-z]|$)" (ppcre:quote-meta-chars word))
                title))

(defun classify-title (title source-id)
  "Classify TITLE from SOURCE-ID.

Returns four values: category keyword, content-type (:deal, :discussion or
:uncertain), confidence (:high, :medium or :low), and the raw signal score."
  (declare (type string title))
  (when (string= source-id "epic")
    (return-from classify-title (values :game :deal :high 10)))
  (let* ((strong (and (ppcre:scan +strong-scanner+ title) t))
         (medium (and (ppcre:scan +medium-scanner+ title) t))
         (membership (and (ppcre:scan +membership-scanner+ title) t))
         (game (or (word-token-p title "epic")
                   (word-token-p title "steam")
                   (and (ppcre:scan +game-scanner+ title) t)))
         (hard-noise (or (and (ppcre:scan +hard-noise-scanner+ title) t)
                         (and (ppcre:scan +request-scanner+ title) t)))
         (trade (and (ppcre:scan +trade-scanner+ title) t))
         (editorial (and (ppcre:scan +editorial-scanner+ title) t))
         (question (and (ppcre:scan +question-scanner+ title) t))
         (score (- (cond (strong 5)
                         (medium 3)
                         ((or membership game) 2)
                         (t 0))
                   (if hard-noise 10 0)
                   (if trade 6 0)
                   (if editorial 5 0)
                   (if question 4 0)
                   (if (and (ppcre:scan +question-mark-scanner+ title) (not strong)) 1 0)))
         (category :other))
    (when (>= score 2)
      (setf category
            (cond (game :game)
                  (membership :membership)
                  ((ppcre:scan +limited-free-scanner+ title) :limited-free)
                  ((ppcre:scan +freebie-scanner+ title) :freebie)
                  (t :low-price))))
    (values category
            (cond ((not (eq category :other)) :deal)
                  ((or hard-noise trade editorial question) :discussion)
                  (t :uncertain))
            (cond ((>= score 5) :high)
                  ((>= score 2) :medium)
                  (t :low))
            score)))
