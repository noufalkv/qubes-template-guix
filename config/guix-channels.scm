;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Installed as /etc/guix/channels.scm in the Qubes Guix template.  It lets the
;; user run "guix pull" to update the Qubes channel modules the idiomatic way
;; instead of staying pinned to the modules baked into the image.  No commit is
;; pinned, so pulls track the branch; release reproducibility comes from the
;; build-time config/channels.scm.  During development this points at the
;; GitHub mirror; move it to the Qubes-hosted URL for publication.
(cons (channel
       (name 'qubes)
       (url "https://github.com/noufalkv/qubes-template-guix.git")
       (branch "main")
       (introduction
        (make-channel-introduction
         "0e2aef5aca27851bd9d00b4c036f790b1c2ad979"
         (openpgp-fingerprint
          "9A23 32D1 567B EEB5 57BB  53DF 559B 1DC4 CA0D 77FF"))))
      %default-channels)
