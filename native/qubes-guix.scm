;; SPDX-License-Identifier: GPL-3.0-or-later
;; Native Guix System definition for the normal Qubes TemplateVM variant.
;;
;; Build with:
;;   guix system init --no-bootloader -L native/modules native/qubes-guix.scm /mnt

(use-modules (qubes systems guix-template))

(qubes-template-operating-system #:variant 'normal)
