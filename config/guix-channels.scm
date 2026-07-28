;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Installed as /etc/guix/channels.scm in the Qubes Guix template.  It lets the
;; user run "guix pull" to update both Guix and the Qubes channel the idiomatic
;; way instead of staying pinned to the modules baked into the image.  Neither
;; channel has a commit pin, so pulls and reconfigures follow their authenticated
;; branch heads.  During development the Qubes channel points at the GitHub
;; mirror; move it to the Qubes-hosted URL for publication.
(list (channel
        (name 'qubes)
        (url "https://github.com/noufalkv/qubes-template-guix.git")
        (branch "quality-refactor")
        (introduction
         (make-channel-introduction "0e2aef5aca27851bd9d00b4c036f790b1c2ad979"
          (openpgp-fingerprint
           "9A23 32D1 567B EEB5 57BB  53DF 559B 1DC4 CA0D 77FF"))))
      (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
