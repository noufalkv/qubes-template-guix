;; SPDX-License-Identifier: GPL-3.0-or-later
;; Qubes TemplateVM operating-system building blocks.

(define-module (qubes system)
  #:use-module (guix gexp)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu system nss)
  #:use-module (gnu services)
  #:use-module (gnu services dbus)
  #:use-module (gnu system privilege)
  #:use-module (qubes packages)
  #:use-module (qubes services)
  #:export (%qubes-privileged-programs
            %qubes-system-services
            qubes-host-name
            qubes-operating-system))

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

(define* (qubes-operating-system #:key (variant 'normal))
  "Return a Qubes TemplateVM operating-system for VARIANT ('normal or 'minimal)."
  (operating-system
    (host-name (qubes-host-name variant))
    (timezone "Etc/UTC")
    (locale "en_US.utf8")

    ;; Qubes dom0 supplies the VM kernel.  A bootloader record is still required
    ;; by the operating-system type and is needed for "guix system init" to copy
    ;; the full store closure, but images are built with --no-bootloader so no
    ;; boot code is written to disk.
    (bootloader
     (bootloader-configuration
      (bootloader grub-bootloader)
      (targets '("/dev/xvda"))))
    (kernel qubes-dom0-kernel)
    (initrd-modules '())
    (kernel-arguments
     (append '("console=hvc0" "panic=1")
             %default-kernel-arguments))

    (file-systems
     (cons* (file-system
              (mount-point "/")
              (device (file-system-label "guix-root"))
              (type "ext4"))
            %base-file-systems))
    (swap-devices
     (list (swap-space
            (target "/dev/xvdc1"))))

    (users
     (cons* (user-account
              (name "user")
              (comment "Qubes user")
              (group "users")
              (supplementary-groups '("wheel" "netdev" "audio" "video"
                                      "qubes")))
            %base-user-accounts))
    (groups
     (cons* (user-group (name "qubes"))
            %base-groups))

    (packages (qubes-variant-packages variant))

    (privileged-programs %qubes-privileged-programs)
    (sudoers-file
     (plain-file "sudoers"
                 "root ALL=(ALL) ALL\n%wheel ALL=(ALL) NOPASSWD:ALL\nuser ALL=(ALL) NOPASSWD:ALL\n"))
