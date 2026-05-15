;; SPDX-License-Identifier: GPL-3.0-or-later
;; Native Guix System definition for the minimal Qubes TemplateVM variant.
;;
;; The minimal variant keeps Qubes GUI support and xterm, mirroring the
;; standard Qubes minimal-template expectation without pulling in xfce-terminal.

(use-modules (qubes systems guix-template))

(qubes-template-operating-system #:variant 'minimal)
