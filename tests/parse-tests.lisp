;;;; Parsers: Atom, RSS, Epic free-game promotions and the LINUX DO Markdown
;;;; rendering. Every body comes from tests/fixtures.

(in-package #:deal-aggregator/tests)

(def-suite parsing :description "RSS, Atom, Epic JSON and LINUX DO Markdown parsing.")
(in-suite parsing)

(defun parse-fixture (source-id fixture &key (now *now*))
  (da:parse-source (da::find-source source-id) (read-fixture fixture) now))

(test atom-feed
  (let* ((items (parse-fixture "v2ex" "v2ex-public-sample.xml"))
         (item (first items)))
    (is (= 1 (length items)))
    (is (string= "Anthropic 原生接口直通，新人入群送 10 美元"
                 (da::parsed-item-title item)))
    (is (string= "https://www.v2ex.com/t/1255325"
                 (da:canonical-url (da::parsed-item-url item))))
    (is (= (utc-ms 49 8 5 8 11 2026) (da::parsed-item-published-at item)))
    (is (search "curl" (da::parsed-item-summary item)))))

(test rss-feeds
  (let* ((items (parse-fixture "appinn" "appinn-public-sample.xml"))
         (item (first items)))
    (is (= 1 (length items)))
    (is (search "TotK Recomp" (da::parsed-item-title item)))
    (is (string= "https://www.appinn.com/totk-recomp/" (da::parsed-item-url item)))
    (is (= (utc-ms 49 19 12 7 11 2026) (da::parsed-item-published-at item)))
    (is (search "v0.3.12" (da::parsed-item-summary item))))
  (let* ((items (parse-fixture "iplaysoft" "iplaysoft-public-sample.xml"))
         (item (first items)))
    (is (= 1 (length items)))
    (is (search "夸克网盘" (da::parsed-item-title item)))
    (is (string= "https://www.iplaysoft.com/p/quark-svip"
                 (da::parsed-item-url item)))
    (is (= (utc-ms 37 1 7 7 11 2026) (da::parsed-item-published-at item)))
    (is (not (search "<" (da::parsed-item-summary item))))))

(test feed-rejects-web-pages
  (signals da::parse-failure
    (da::parse-feed "<!DOCTYPE html><html><body>just a moment</body></html>" *now*)))

(test feed-rejects-other-bodies
  (signals da::parse-failure
    (da::parse-feed "plain text, no feed here" *now*)))

(test epic-free-window
  (let ((items (parse-fixture "epic" "epic-public-sample.json")))
    (is (= 2 (length items)))
    (let ((urls (mapcar #'da::parsed-item-url items)))
      (is (member "https://store.epicgames.com/zh-CN/p/idle-champions-of-the-forgotten-realms"
                  urls :test #'string=))
      (is (member "https://store.epicgames.com/zh-CN/p/flotsam-266287"
                  urls :test #'string=)))
    (let ((idle (find "idle-champions" items
                      :key #'da::parsed-item-url
                      :test (lambda (needle url) (and (search needle url) t)))))
      (is (string= "《Idle Champions of the Forgotten Realms》"
                   (da::parsed-item-title idle)))
      (is (= (utc-ms 0 0 16 5 11 2026) (da::parsed-item-published-at idle)))
      (is (= (utc-ms 0 0 16 12 11 2026) (da::parsed-item-expires-at idle))))))

(test epic-window-is-half-open
  (is (zerop (length (parse-fixture "epic" "epic-public-sample.json"
                                    :now (utc-ms 0 0 16 12 11 2026)))))
  (is (zerop (length (parse-fixture "epic" "epic-public-sample.json"
                                    :now (utc-ms 0 0 0 1 11 2026))))))

(test epic-rejects-broken-catalogues
  (signals da::parse-failure
    (da::parse-epic "{\"data\":{\"Catalog\":{\"searchStore\":{\"elements\":[]}}}}"
                    *now*))
  (signals da::parse-failure (da::parse-epic "<html>nope</html>" *now*)))

(test linuxdo-markdown
  (let* ((items (parse-fixture "linuxdo" "linuxdo-public-sample.md"))
         (first-item (first items)))
    (is (>= (length items) 10))
    (is (search "免费送我一度电" (da::parsed-item-title first-item)))
    (is (string= "https://linux.do/t/topic/3139754"
                 (da::parsed-item-url first-item)))
    (is (= (utc-ms 12 36 5 8 11 2026) (da::parsed-item-published-at first-item)))
    (is (string= "" (da::parsed-item-summary first-item)))))

(test linuxdo-synthetic-variants
  (let ((items (parse-fixture "linuxdo" "linuxdo-synthetic-variants.md")))
    (is (= 2 (length items)))
    (is (= (utc-ms 12 36 5 8 11 2026) (da::parsed-item-published-at (first items))))
    (is (null (da::parsed-item-published-at (second items))))))

(test linuxdo-rejects-other-bodies
  (signals da::parse-failure
    (da::parse-linuxdo-markdown "no topic links here" *now*)))
