;; SPDX-License-Identifier: GPL-3.0-or-later
;; GNU Guix System configuration for a Qubes OS TemplateVM.
;;
;; This is the variant: minimal.
;; It is installed as /etc/config.scm and reconfigured with:
;;
;;   guix system -L /etc/qubes-guix-channel/modules reconfigure /etc/config.scm

(use-modules (qubes vm))

(qubes-operating-system #:variant 'minimal)
