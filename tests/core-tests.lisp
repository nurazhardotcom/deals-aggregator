;;;; Core rules: timestamps, URL canonicalisation, the host gate, title
;;;; classification, retention boundaries and JSON booleans.

(in-package #:deal-aggregator/tests)

(def-suite core :description "Timestamps, URLs, classification, retention, JSON.")
(in-suite core)

(test rfc822-and-iso-agree
  (is (= (da:parse-timestamp-ms "Sat, 07 Nov 2026 12:19:49 +0000")
         (da:parse-timestamp-ms "2026-11-07T12:19:49Z"))))

(test rfc822-zone-offsets
  (is (= (da:parse-timestamp-ms "03 Nov 2025 02:00:00 +0800")
         (da:parse-timestamp-ms "2025-11-02T18:00:00Z")))
  (is (= (utc-ms 12 36 5 8 11 2026)
         (da:parse-timestamp-ms "Sun, 08 Nov 2026 05:36:12 +0000"))))

(test unparseable-timestamps-are-nil
  (is (null (da:parse-timestamp-ms "not a date")))
  (is (null (da:parse-timestamp-ms "")))
  (is (null (da:parse-timestamp-ms nil))))

(test publish-time-rejects-implausible-dates
  (let ((now (utc-ms 0 0 0 9 11 2026)))
    (is (= (utc-ms 0 0 5 8 11 2026)
           (da::publish-time "2026-11-08T05:00:00Z" now)))
    (is (null (da::publish-time "2099-01-01T00:00:00Z" now)))
    (is (null (da::publish-time "1999-12-31T23:59:59Z" now)))
    (is (null (da::publish-time "nonsense" now)))))

(test beijing-and-iso-labels
  (is (string= "2026-11-09 08:00" (da:format-beijing (utc-ms 0 0 0 9 11 2026))))
  (is (string= "2026-11-09T00:00:00.000Z" (da::iso-string (utc-ms 0 0 0 9 11 2026)))))

(test canonical-url-normalises
  (is (string= "https://www.v2ex.com/t/1255325"
               (da:canonical-url "https://www.v2ex.com/t/1255325#reply0")))
  (is (string= "https://example.com/path"
               (da:canonical-url "HTTPS://Example.COM/path/?utm_source=feed")))
  (is (string= "https://example.com/p?a=1&b=2"
               (da:canonical-url "https://example.com/p?b=2&a=1&fbclid=x"))))

(test canonical-url-rejects-non-articles
  (signals da::parse-failure (da:canonical-url "ftp://example.com/file"))
  (signals da::parse-failure (da:canonical-url "https://user:pass@example.com/x"))
  (signals da::parse-failure (da:canonical-url ""))
  (signals da::parse-failure
    (da:canonical-url (concatenate 'string "https://example.com/"
                                   (make-string 3000 :initial-element #\a)))))

(test host-gate
  (is (da::host-allowed-p "store.epicgames.com" '("store.epicgames.com")))
  (is (da::host-allowed-p "www.linux.do" '("linux.do")))
  (is (not (da::host-allowed-p "linux.do.evil.com" '("linux.do"))))
  (is (not (da::host-allowed-p "notepicgames.com" '("epicgames.com"))))
  (is (not (da::host-allowed-p nil '("linux.do"))))
  (is (da::source-url-allowed-p "https://www.v2ex.com/t/1"
                                (da::find-source "v2ex")))
  (is (not (da::source-url-allowed-p "https://linux.do/t/topic/1"
                                     (da::find-source "v2ex")))))

(test epic-titles-are-games
  (multiple-value-bind (category content confidence)
      (da:classify-title "《LISA: Definitive Edition》" "epic")
    (is (eq category :game))
    (is (eq content :deal))
    (is (eq confidence :high))))

(test title-signals
  (multiple-value-bind (category content confidence)
      (da:classify-title "Cloady 免费领取" "linuxdo")
    (is (eq category :limited-free))
    (is (eq content :deal))
    (is (eq confidence :high)))
  (multiple-value-bind (category content confidence)
      (da:classify-title "steam98%好评游戏喜加一" "linuxdo")
    (is (eq category :game))
    (is (eq content :deal))
    (is (eq confidence :medium)))
  (multiple-value-bind (category content confidence)
      (da:classify-title "求购一台二手路由器" "linuxdo")
    (is (eq category :other))
    (is (eq content :discussion))
    (is (eq confidence :low)))
  (multiple-value-bind (category content confidence)
      (da:classify-title "今日天气" "appinn")
    (is (eq category :other))
    (is (eq content :uncertain))))

(test category-identifiers
  (is (string= "免费白嫖" (da:category-label :freebie)))
  (is (eq :game (da:category-id "游戏")))
  (is (eq :freebie (da:category-id "freebie")))
  (is (eq :low-price (da:category-id "low-price")))
  (is (eq :other (da:category-id "no-such-category"))))

(test retention-boundaries
  (let* ((now (utc-ms 0 0 0 9 11 2026))
         (week (* 7 24 60 60 1000)))
    (is (not (da:stale-p (- now week) (- now week) nil now)))
    (is (da:stale-p (- now week 1) (- now week 1) nil now))
    (is (da:stale-p now nil now now))
    (is (not (da:stale-p now nil (1+ now) now)))
    (is (not (da:stale-p nil nil nil now)))))

(test expiring-soon-window
  (let ((now (utc-ms 0 0 0 9 11 2026)))
    (is (da:expiring-soon-p (+ now da::+expiring-soon-ms+) now))
    (is (not (da:expiring-soon-p (1+ (+ now da::+expiring-soon-ms+)) now)))
    (is (not (da:expiring-soon-p now now)))
    (is (not (da:expiring-soon-p (1- now) now)))
    (is (not (da:expiring-soon-p nil now)))))

(test text-cleanup
  (is (string= "hello world" (da::to-plain "<p>hello <b>world</b></p>")))
  (is (string= "a < b" (da::to-plain "a &lt; b")))
  (let ((long (make-string 400 :initial-element #\a)))
    (is (= da::+title-max+ (length (da::clean-title long))))
    (is (= (1+ da::+summary-max+) (length (da::excerpt long))))))

(test json-booleans
  (is (string= "{\"ok\":true}" (da::to-json (da::json-object "ok" t))))
  (is (string= "{\"ok\":false}"
               (da::to-json (da::json-object "ok" (da::json-true-p nil)))))
  (is (string= "{\"ok\":null}" (da::to-json (da::json-object "ok" nil))))
  (is (string= "[]" (da::to-json (da::json-array '()))))
  (is (equal '(1 2) (coerce (gethash "a" (da::parse-json "{\"a\":[1,2]}")) 'list))))
