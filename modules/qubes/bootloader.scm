;;; bootloader.scm --- Externally-managed bootloader for Qubes TemplateVMs
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; A Qubes TemplateVM is booted by dom0 (pvgrub/pvh), not by GRUB installed
;;; inside the VM.  The VM root is a single ext4 partition with no embedding
;;; space, so a real "grub-install" fails ("will not proceed with blocklists").
;;; Image builds already pass --no-bootloader, but "guix system reconfigure"
;;; always runs the bootloader installer and would fail at that last step.
;;;
;;; QUBES-EXTERNAL-BOOTLOADER inherits grub-bootloader -- so the usual
;;; /boot/grub/grub.cfg is still generated, keeping generation switching,
;;; roll-back, and delete-generations working -- but its installer is a no-op
;;; because dom0 owns boot.

(define-module (qubes bootloader)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (guix gexp)
  #:export (qubes-external-bootloader))

(define install-qubes-external-bootloader
  #~(lambda (bootloader target mount-point)
      ;; Boot is managed by Qubes dom0; nothing to install inside the VM.
      #t))

(define qubes-external-bootloader
  (bootloader
    (inherit grub-bootloader)
    (name 'qubes-external)
    (installer install-qubes-external-bootloader)
    (disk-image-installer #f)))
