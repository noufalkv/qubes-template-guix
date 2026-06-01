;; SPDX-License-Identifier: GPL-3.0-or-later
;; GNU Guix System configuration for a Qubes OS TemplateVM.
;;
;; This is the variant: minimal.
;; It is installed as /etc/config.scm.  Update the template the idiomatic way:
;;
;;   guix pull && sudo guix system reconfigure /etc/config.scm
;;
;; "guix pull" refreshes both Guix and the Qubes channel from
;; /etc/guix/channels.scm, so no "-L" is needed.  As an offline fallback the
;; image also ships the channel under /etc/qubes-guix-channel:
;;
;;   sudo guix system -L /etc/qubes-guix-channel/modules reconfigure /etc/config.scm

(use-modules (qubes vm))

(qubes-operating-system #:variant 'minimal)
