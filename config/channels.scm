;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Build-time channels for template generation.  The Guix channel tracks the
;; upstream "master" branch with no commit pin, so each template build uses a
;; current Guix and the system stays up to date naturally.  Reproducibility of
;; a specific build still comes from "guix time-machine"/"guix describe" if a
;; caller wants to rebuild an exact past template.
(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
