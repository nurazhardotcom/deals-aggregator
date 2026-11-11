;;;; Parser dispatch by source format.

(in-package #:deal-aggregator)

(defun parse-source (source body now)
  "Parse BODY for SOURCE into PARSED-ITEM values."
  (ecase (source-format source)
    (:feed (parse-feed body now))
    (:epic (parse-epic body now))
    (:markdown (parse-linuxdo-markdown body now))))
