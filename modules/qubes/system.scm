;; SPDX-License-Identifier: GPL-3.0-or-later
;; Qubes TemplateVM operating-system building blocks.

(define-module (qubes system)
  #:use-module (guix gexp)
  #:use-module (gnu)
  #:use-module (gnu services)
  #:use-module (gnu services dbus)
  #:use-module (gnu system privilege)
  #:use-module (qubes packages)
  #:use-module (qubes services)
  #:export (%qubes-privileged-programs
            %qubes-system-services
            qubes-host-name))

(define %qubes-privileged-programs
  (cons (privileged-program
         (program (file-append qubes-vm-core "/lib/qubes/qfile-unpacker"))
         (setuid? #t))
        %default-privileged-programs))

(define %qubes-system-services
  ;; The full service stack a Qubes Guix TemplateVM runs.  It is the same for
  ;; both variants (the minimal variant is GUI-capable, it just ships fewer
  ;; applications).  Composed here as one exported list so the template's
  ;; operating-system form can reference it directly:
  ;;   - the session/system D-Bus used by GUI and Qubes tooling;
  ;;   - the Qubes VM GUI + headless services (qrexec, QubesDB, meminfo-writer,
  ;;     networking, updates proxy, GUI agent, ...);
  ;;   - the Qubes sysctl service;
  ;;   - the trimmed set of Guix base services Qubes does not own.
  (append (list (service dbus-root-service-type))
          %qubes-vm-gui-services
          (list %qubes-sysctl-service)
          %qubes-minimal-base-services))

(define (qubes-host-name variant)
  "Return the Qubes TemplateVM host name for VARIANT ('normal or 'minimal)."
  (case variant
    ((minimal) "guix-minimal-qubes")
    ((normal) "guix-qubes")
    (else (error "unsupported Qubes Guix template variant" variant))))
