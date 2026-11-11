;;;; Retention and expiry boundaries. Expiry is inclusive, age is exclusive.

(in-package #:deal-aggregator)

(defun stale-p (published-at first-seen-at expires-at now)
  "True when a deal has expired or is older than the retention window.

EXPIRES-AT counts up to and including NOW. The age cutoff is strict, so an item
exactly seven days old is still kept."
  (or (and expires-at (<= expires-at now))
      (let ((reference (or published-at first-seen-at)))
        (and reference (< reference (- now +retention-ms+))))))

(defun expiring-soon-p (expires-at now)
  "True inside the expiry badge window."
  (and expires-at
       (let ((remaining (- expires-at now)))
         (and (plusp remaining) (<= remaining +expiring-soon-ms+)))))
