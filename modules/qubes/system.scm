;; SPDX-License-Identifier: GPL-3.0-or-later
;; Qubes TemplateVM operating-system building blocks.

(define-module (qubes system)
  #:use-module (guix channels)
  #:use-module (guix describe)
  #:use-module (guix gexp)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu services)
  #:use-module (gnu services dbus)
  #:use-module (gnu system privilege)
  #:use-module (ice-9 format)
  #:use-module (ice-9 rdelim)
  #:use-module (qubes bootloader)
  #:use-module (qubes packages)
  #:use-module (qubes services)
  #:use-module (srfi srfi-1)
  #:export (%qubes-privileged-programs %qubes-system-services qubes-host-name
                                       qubes-operating-system))

(define %qubes-privileged-programs
  (cons (privileged-program
          (program (file-append qubes-vm-core "/lib/qubes/qfile-unpacker"))
          (setuid? #t)) %default-privileged-programs))

(define %qubes-system-source-directory
  ;; Compiled Guile modules retain a load-path-relative filename such as
  ;; "qubes/system.scm".  Resolve it through %load-path before looking for the
  ;; offline tree's adjacent revision marker.
  (and=> (or (current-filename)
             (module-filename (current-module)))
         (lambda (file)
           (and=> (if (and (positive? (string-length file))
                           (char=? (string-ref file 0) #\/))
                      file
                      (search-path %load-path file))
                  dirname))))

(define (hex-commit? value)
  (and (string? value)
       (= (string-length value) 40)
       (every (lambda (character)
                (or (char-numeric? character)
                    (memv character '(#\a #\b #\c #\d #\e #\f))))
              (string->list value))))

(define (channel->revision channel)
  (let ((commit (channel-commit channel)))
    (unless (hex-commit? commit)
      (error "channel lacks an exact applied commit" (channel-name channel)))
    (list (channel-name channel) commit)))

(define (source-qubes-channel-revision)
  ;; The installed offline source tree carries the commit it was copied from.
  ;; Prefer that marker even if the invoking Guix profile contains a newer
  ;; Qubes channel: -L gives the installed source tree module precedence.
  (and %qubes-system-source-directory
       (let ((marker (string-append %qubes-system-source-directory
                                    "/.qubes-channel-commit")))
         (and (file-exists? marker)
              (call-with-input-file marker
                (lambda (port)
                  (let ((commit (read-line port)))
                    (unless (and (hex-commit? commit)
                                 (eof-object? (read-char port)))
                      (error "invalid Qubes channel source revision" marker))
                    (list 'qubes commit))))))))

(define (environment-qubes-channel-revision)
  (let ((commit (getenv "QUBES_TEMPLATE_CHANNEL_COMMIT")))
    (cond
      ((not commit) #f)
      ((hex-commit? commit) (list 'qubes commit))
      (else
       (error "invalid QUBES_TEMPLATE_CHANNEL_COMMIT" commit)))))

(define (applied-channel-revisions)
  (let* ((revisions (map channel->revision (current-channels)))
         (source-revision (source-qubes-channel-revision))
         ;; Source selection follows the same precedence as module loading:
         ;; the baked offline tree wins first, followed by the explicit commit
         ;; supplied for a local -L build, then the invoking pull profile.
         (qubes-revision
          (or source-revision
              (environment-qubes-channel-revision)
              (find (lambda (revision) (eq? (car revision) 'qubes))
                    revisions)
              (error "cannot determine the applied Qubes channel revision")))
         (revisions
          (cons qubes-revision
                (remove (lambda (revision) (eq? (car revision) 'qubes))
                        revisions)))
         (names (map car revisions)))
    (unless (find (lambda (name) (eq? name 'guix)) names)
      (error "cannot determine the applied Guix channel revision"))
    (unless (= (length names) (length (delete-duplicates names eq?)))
      (error "duplicate applied Guix channel name" names))
    (sort revisions
          (lambda (left right)
            (string<? (symbol->string (car left))
                      (symbol->string (car right)))))))

(define (qubes-applied-channel-state-etc _)
  ;; Defer provenance discovery until the operating-system service graph is
  ;; lowered.  Channel module compilation imports this module without a Qubes
  ;; channel instance, source marker, or explicit build revision.
  `(("qubes-applied-guix-channels.scm"
     ,(plain-file "qubes-applied-guix-channels.scm"
                  (format #f "~s~%" (applied-channel-revisions))))))

(define qubes-applied-channel-state-service-type
  (service-type
    (name 'qubes-applied-guix-channels)
    (extensions
     (list (service-extension etc-service-type
                              qubes-applied-channel-state-etc)))
    (default-value #f)
    (description "Record the exact channels applied to the running system.")))

(define %qubes-applied-channel-state-service
  (service qubes-applied-channel-state-service-type))

(define %qubes-system-services
  ;; The full service stack a Qubes Guix TemplateVM runs.  It is the same for
  ;; both variants (the minimal variant is GUI-capable, it just ships fewer
  ;; applications).  Composed here as one exported list so the template's
  ;; operating-system form can reference it directly:
  ;; - the session/system D-Bus used by GUI and Qubes tooling;
  ;; - the Qubes VM GUI + headless services (qrexec, QubesDB, meminfo-writer,
  ;; networking, updates proxy, GUI agent, ...);
  ;; - the Qubes sysctl service;
  ;; - the trimmed set of Guix base services Qubes does not own.
  (append (list (service dbus-root-service-type)
                %qubes-applied-channel-state-service)
          %qubes-vm-gui-services
          (list %qubes-sysctl-service) %qubes-minimal-base-services))

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

    ;; Qubes dom0 supplies the VM kernel and manages boot.  A bootloader record
    ;; is still required by the operating-system type and is needed for "guix
    ;; system init" to copy the full store closure, but qubes-external-bootloader
    ;; generates grub.cfg without ever running grub-install, so "guix system
    ;; reconfigure" succeeds inside the VM (a real grub-install cannot work on
    ;; the embedding-less ext4 root).
    (bootloader (bootloader-configuration (bootloader qubes-external-bootloader)))
    (kernel qubes-dom0-kernel)
    (initrd-modules '())
    (kernel-arguments (append '("console=hvc0" "panic=1") %default-kernel-arguments))

    (file-systems (cons* (file-system
                           (mount-point "/")
                           (device (file-system-label "guix-root"))
                           (type "ext4")) %base-file-systems))
    (swap-devices (list (swap-space (target "/dev/xvdc1"))))

    (users (cons* (user-account
                    (name "user")
                    (comment "Qubes user")
                    (group "users")
                    (supplementary-groups '("wheel" "netdev" "audio" "video"
                                            "qubes"))) %base-user-accounts))
    (groups (cons* (user-group (name "qubes")) %base-groups))

    (packages (qubes-variant-packages variant))

    (services %qubes-system-services)

    (privileged-programs %qubes-privileged-programs)
    (sudoers-file (plain-file "sudoers" "root ALL=(ALL) ALL
%wheel ALL=(ALL) NOPASSWD:ALL
user ALL=(ALL) NOPASSWD:ALL
"))))
