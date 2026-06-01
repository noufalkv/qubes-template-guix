;; SPDX-License-Identifier: GPL-3.0-or-later
;; Qubes VM Shepherd services for the qubes-template-guix channel.

(define-module (qubes services)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (gnu)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services sysctl)
  #:use-module (gnu system pam)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (qubes packages)
  #:export (%qubes-vm-headless-services %qubes-vm-gui-services
                                        %qubes-sysctl-service
                                        %qubes-minimal-base-services))

;; Single source of truth for the fixed Qubes compatibility symlinks.  Each
;; (target . link) pair points an upstream Qubes fixed path at the current Guix
;; system profile.  The qubes-vm-compat activation applier below is their one
;; owner; it runs during system activation, before any Shepherd service starts,
;; so per-service runtime setup no longer needs to recreate them.
(define %qubes-compat-links
  '(("/run/current-system/profile/bin" . "/usr/bin")
    ("/run/current-system/profile/sbin" . "/usr/sbin")
    ("/run/current-system/profile/share" . "/usr/share")
    ("/run/current-system/profile/lib/qubes" . "/usr/lib/qubes")
    ("/run/current-system/profile/lib/qubes-bind-dirs.d" . "/usr/lib/qubes-bind-dirs.d")))

(define (qubes-vm-compat-activation _)
  "Return a gexp run at system activation that materializes the fixed Qubes
compatibility symlinks (the @file{/usr/...} and @file{/var/run/qubes*}
bridges into the Guix profile) and the writable copies of files Qubes tools
rewrite at runtime, so the read-only store layout behaves like a stock Qubes
template.  The argument is the ignored service value."
  #~(begin
      (use-modules (guix build utils)
                   (ice-9 ftw)
                   (ice-9 popen)
                   (ice-9 textual-ports)
                   (srfi srfi-13))

      (define (empty-directory? directory)
        (null? (scandir directory
                        (lambda (entry)
                          (not (member entry
                                       '("." "..")))))))

      (define (replace-symlink target link)
        (mkdir-p (dirname link))
        (let ((existing (false-if-exception (lstat link))))
          (cond
            ((and existing
                  (memq (stat:type existing)
                        '(regular symlink)))
             (delete-file link))
            ((and existing
                  (eq? (stat:type existing)
                       'directory)
                  (empty-directory? link))
             (rmdir link)))
          (unless (file-exists? link)
            (symlink target link))))

      (define (symlink?* path)
        (let ((existing (false-if-exception (lstat path))))
          (and existing
               (eq? (stat:type existing)
                    'symlink))))

      (define (regular-or-symlink? path)
        (let ((existing (false-if-exception (lstat path))))
          (and existing
               (memq (stat:type existing)
                     '(regular symlink)))))

      (define (same-directory-entry? left right)
        (let ((left-stat (false-if-exception (stat left)))
              (right-stat (false-if-exception (stat right))))
          (and left-stat right-stat
               (= (stat:dev left-stat)
                  (stat:dev right-stat))
               (= (stat:ino left-stat)
                  (stat:ino right-stat)))))

      (define (link-directory-contents source directory)
        (materialize-symlinked-directory directory)
        (mkdir-p directory)
        (unless (symlink?* directory)
          (when (file-exists? source)
            (for-each (lambda (entry)
                        (let ((target (string-append source "/" entry))
                              (link (string-append directory "/" entry)))
                          (when (symlink?* link)
                            (delete-file link))
                          (unless (file-exists? link)
                            (symlink target link))))
                      (scandir source
                               (lambda (entry)
                                 (not (member entry
                                              '("." "..")))))))))

      (define (write-text-file path text)
        (mkdir-p (dirname path))
        (call-with-output-file path
          (lambda (port)
            (display text port))))

      (define tls-profile-script
        (string-append "export SSL_CERT_DIR=${SSL_CERT_DIR:-/etc/ssl/certs}
"
         "export SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}
"
         "export GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-/etc/ssl/certs/ca-certificates.crt}
"
         "export CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
"))

      (define guix-cache-profile-script
        (string-append "if [ \"${XDG_CACHE_HOME+x}\" != x ]; then\n"
         "    export XDG_CACHE_HOME=/var/tmp/guix-cache-${USER:-user}
" "fi\n"))

      (define (materialize-symlinked-directory directory)
        (let ((existing (false-if-exception (lstat directory))))
          (when (and existing
                     (eq? (stat:type existing)
                          'symlink))
            (let* ((target (readlink directory))
                   (absolute-target (if (and (positive? (string-length target))
                                             (char=? (string-ref target 0) #\/))
                                        target
                                        (string-append (dirname directory) "/"
                                                       target)))
                   (temporary (string-append directory ".qubes-tmp")))
              (when (file-exists? temporary)
                (delete-file-recursively temporary))
              (mkdir-p temporary)
              (when (file-exists? absolute-target)
                (copy-recursively absolute-target temporary))
              (delete-file directory)
              (rename-file temporary directory)))))

      (define (materialize-symlinked-file file)
        (let ((existing (false-if-exception (lstat file))))
          (when (and existing
                     (eq? (stat:type existing)
                          'symlink))
            (let* ((target (readlink file))
                   (absolute-target (if (and (positive? (string-length target))
                                             (char=? (string-ref target 0) #\/))
                                        target
                                        (string-append (dirname file) "/"
                                                       target)))
                   (temporary (string-append file ".qubes-tmp")))
              (when (file-exists? temporary)
                (delete-file temporary))
              (when (file-exists? absolute-target)
                (copy-file absolute-target temporary)
                (chmod temporary #o644)
                (delete-file file)
                (rename-file temporary file))))))

      ;; QubesDB is not reachable during system activation (it runs as a later
      ;; Shepherd service), so this helper returns #f whenever qubesdb-read is
      ;; absent or fails.  When dom0 has already published a value it lets the
      ;; activation apply the configured timezone immediately; otherwise the
      ;; qubes-early-vm-config service propagates it later into the writable
      ;; /etc/localtime materialized below.
      (define qubesdb-read*
        "/run/current-system/profile/bin/qubesdb-read")

      (define (qubesdb-read key)
        (false-if-exception (and (file-exists? qubesdb-read*)
                                 (let* ((port (open-pipe* OPEN_READ
                                                          qubesdb-read* key))
                                        (text (get-string-all port))
                                        (status (close-pipe port)))
                                   (and (zero? status)
                                        (string-trim-right text))))))

      (define (read-text file)
        (call-with-input-file file
          get-string-all))

      (define (write-text file text)
        (call-with-output-file file
          (lambda (port)
            (display text port))))

      (define (install-thunar-qubes-actions)
        (let ((uca "/etc/xdg/Thunar/uca.xml")
              (qubes-uca "/usr/lib/qubes/uca_qubes.xml"))
          (when (and (file-exists? uca)
                     (file-exists? qubes-uca))
            (materialize-symlinked-file uca)
            (let ((text (read-text uca))
                  (actions (read-text qubes-uca)))
              (unless (string-contains text "/usr/lib/qubes/qvm-actions.sh")
                (let ((index (string-contains text "</actions>")))
                  (if index
                      (write-text uca
                                  (string-append (substring text 0 index)
                                                 actions "\n"
                                                 (substring text index)))
                      (write-text uca
                                  (string-append text "\n" actions "\n")))))))))

      ;; The upstream Qubes VM tools use fixed paths. Keep those paths as
      ;; compatibility links into the current Guix system profile.
      (mkdir-p "/usr/lib")
      (mkdir-p "/etc")
      (mkdir-p "/run/qubes")
      (mkdir-p "/run/qubes-service")
      (mkdir-p "/var/log/qubes")
      (mkdir-p "/var/lib/qubes")
      (mkdir-p "/var/tmp")
      (mkdir-p "/rw")
      (mkdir-p "/usr/local")
      (chmod "/var/tmp" #o1777)
      ;; Guix exposes /etc/fstab as an immutable store symlink.  Materialize it
      ;; once here to a writable file so the qubes-mount-dirs service (the single
      ;; runtime writer) can append the private /rw volume entry at boot.
      (materialize-symlinked-file "/etc/fstab")
      ;; /etc/localtime is also an immutable store symlink on Guix (the
      ;; operating-system timezone).  Qubes' qubes-early-vm-config.sh writes
      ;; /etc/localtime when dom0 propagates a configured timezone, which fails
      ;; silently against a store symlink.  Materialize it once here to a
      ;; writable regular file so that runtime propagation can update it, and
      ;; apply the dom0-configured timezone immediately when QubesDB already
      ;; carries it.  The running profile does not expose a share/zoneinfo
      ;; directory, so derive the zoneinfo base from the existing /etc/localtime
      ;; store symlink (e.g. /gnu/store/...-tzdata/share/zoneinfo/Etc/UTC)
      ;; before materializing it.  qubesdb-read returns #f during early
      ;; activation (the daemon is not up yet); the qubes-early-vm-config
      ;; service applies the value later into this now-writable file.
      (let* ((existing (false-if-exception (lstat "/etc/localtime")))
             (zoneinfo-base (and existing
                                 (eq? (stat:type existing)
                                      'symlink)
                                 (let* ((target (readlink "/etc/localtime"))
                                        (index (string-contains target
                                                                "/zoneinfo/")))
                                   (and index
                                        (substring target 0
                                                   (+ index
                                                      (string-length
                                                       "/zoneinfo"))))))))
        (materialize-symlinked-file "/etc/localtime")
        (let ((tz (qubesdb-read "/qubes-timezone")))
          (when (and tz
                     (not (string-null? tz)) zoneinfo-base)
            (let ((zoneinfo (string-append zoneinfo-base "/" tz)))
              (when (file-exists? zoneinfo)
                (let ((temporary "/etc/localtime.qubes-tmp"))
                  (when (file-exists? temporary)
                    (delete-file temporary))
                  (copy-file zoneinfo temporary)
                  (chmod temporary #o644)
                  (when (file-exists? "/etc/localtime")
                    (delete-file "/etc/localtime"))
                  (rename-file temporary "/etc/localtime")))))))
      (write-text-file "/etc/acpi/events/qubes-power-button"
                       "event=button/power.*
action=/etc/acpi/actions/qubes-poweroff
")
      (write-text-file "/etc/acpi/actions/qubes-poweroff"
       "#!/run/current-system/profile/bin/guile -s
!#
(execl \"/run/current-system/profile/sbin/halt\" \"halt\")
")
      (chmod "/etc/acpi/actions/qubes-poweroff" #o555)
      ;; Apply the fixed Qubes compatibility symlinks from the single
      ;; %qubes-compat-links data list.  This is the one owner of these links.
      (for-each (lambda (pair)
                  (replace-symlink (car pair)
                                   (cdr pair)))
                '#$%qubes-compat-links)
      (link-directory-contents "/run/current-system/profile/etc/qubes"
                               "/etc/qubes")
      (materialize-symlinked-directory "/etc/qubes/post-install.d")
      (mkdir-p "/etc/qubes/post-install.d")
      (link-directory-contents "/run/current-system/profile/etc/xen"
                               "/etc/xen")
      ;; Official Qubes system tests and local administrators create ad-hoc
      ;; services in /etc/qubes-rpc and post-install hooks below /etc/qubes.
      ;; Keep packaged entries visible, but make the top-level directories
      ;; writable instead of immutable profile symlinks.
      (link-directory-contents "/run/current-system/profile/etc/qubes-rpc"
                               "/etc/qubes-rpc")
      (install-thunar-qubes-actions)
      ;; Qubes' init/functions still use /var/run/qubes-service* while
      ;; qubes-sysinit.sh populates /run/qubes-service*.  Bridge those paths
      ;; only on systems where /var/run is not already /run.
      (unless (same-directory-entry? "/var/run" "/run")
        (replace-symlink "/run/qubes" "/var/run/qubes")
        (replace-symlink "/run/qubes-service" "/var/run/qubes-service")
        (replace-symlink "/run/qubes-service-environment"
                         "/var/run/qubes-service-environment"))
      (link-directory-contents "/run/current-system/profile/etc/X11"
                               "/etc/X11")
      (link-directory-contents "/run/current-system/profile/etc/sysconfig"
                               "/etc/sysconfig")
      (link-directory-contents "/run/current-system/profile/etc/profile.d"
                               "/etc/profile.d")
      (for-each (lambda (path)
                  (when (regular-or-symlink? path)
                    (delete-file path)))
                '("/etc/profile.d/qubes-guix-session.sh"
                  "/etc/profile.d/qubes-guix-update-proxy.sh"
                  "/run/qubes/bin/guix"))
      (write-text-file "/etc/profile.d/qubes-guix-tls.sh" tls-profile-script)
      (chmod "/etc/profile.d/qubes-guix-tls.sh" #o644)
      (write-text-file "/etc/profile.d/qubes-guix-cache.sh"
                       guix-cache-profile-script)
      (chmod "/etc/profile.d/qubes-guix-cache.sh" #o644)
      (link-directory-contents "/run/current-system/profile/bin" "/bin")
      (link-directory-contents "/run/current-system/profile/bin" "/usr/bin")
      (link-directory-contents "/run/current-system/profile/sbin" "/sbin")
      (replace-symlink "/run/current-system/profile/sbin/halt"
                       "/sbin/poweroff")))

(define qubes-vm-compat-service-type
  (service-type (name 'qubes-vm-compat)
                (extensions (list (service-extension activation-service-type
                                   qubes-vm-compat-activation)))
                (default-value #f)
                (description
                 "Create compatibility paths expected by Qubes VM agents.")))

(define %qubes-audio-limits
  ;; Realtime scheduling + high niceness for the trusted @qubes group, matching
  ;; stock Qubes templates' /etc/security/limits.d/90-qubes-gui.conf.  This is
  ;; how Qubes gives PipeWire's audio threads realtime priority; it does not
  ;; ship rtkit-daemon, so the "RTKit ServiceUnknown" log is expected.
  (plain-file "qubes-audio-limits.conf"
              "@qubes - rtprio unlimited
@qubes - nice -20
@qubes - memlock unlimited
"))

(define (qubes-pam-service name)
  "Return a permissive @code{pam-service} named NAME for a Qubes agent user
session.  It authorizes via @code{pam_rootok}/@code{pam_permit} and applies
the @code{%qubes-audio-limits} realtime limits in its session stack so
PipeWire can run with elevated priority."
  (let ((pam-module (lambda (name)
                      (file-append linux-pam "/lib/security/" name))))
    (pam-service (name name)
                 (auth (list (pam-entry (control "sufficient")
                                        (module (pam-module "pam_rootok.so")))
                             (pam-entry (control "required")
                                        (module (pam-module "pam_permit.so")))))
                 (account (list (pam-entry (control "required")
                                           (module (pam-module "pam_permit.so")))))
                 (password (list (pam-entry (control "required")
                                            (module (pam-module
                                                     "pam_permit.so")))))
                 (session (list (pam-entry (control "required")
                                           (module (pam-module "pam_permit.so")))
                                ;; Apply the @qubes realtime audio limits to
                                ;; qrexec/GUI user sessions (where PipeWire runs).
                                (pam-entry (control "optional")
                                           (module (pam-module "pam_limits.so"))
                                           (arguments
                                            (list #~(string-append
                                                     "conf="
                                                     #$%qubes-audio-limits)))))))))

(define (qubes-qrexec-pam-services _)
  "Return the list of PAM services for the qrexec and GUI agent user
sessions.  The argument is the ignored service value."
  (list (qubes-pam-service "qrexec")
        (qubes-pam-service "qubes-gui-agent")))

(define qubes-qrexec-pam-service-type
  (service-type (name 'qubes-qrexec-pam)
                (extensions (list (service-extension pam-root-service-type
                                   qubes-qrexec-pam-services)))
                (default-value #f)
                (description
                 "Install the PAM service used by qrexec-agent user sessions.")))

(define (qubes-acpi-shutdown-shepherd-service _)
  "Return a Shepherd service that runs @command{acpid} so that an ACPI
power-button event from dom0 (sent by @command{qvm-shutdown}) cleanly halts
the VM.  The argument is the ignored service value."
  (list (shepherd-service (provision '(qubes-acpi-shutdown))
                          (requirement '(root-file-system))
                          (documentation
                           "Handle Qubes ACPI power-button shutdown requests.")
                          (start #~(make-forkexec-constructor (list #$(file-append
                                                                       acpid
                                                                       "/sbin/acpid")
                                                               "-f"
                                                               "-n"
                                                               "-S"
                                                               "-l"
                                                               "-c"
                                                               "/etc/acpi/events")
                                    #:log-file "/var/log/qubes-acpid.log"))
                          (stop #~(make-kill-destructor)))))

(define qubes-acpi-shutdown-service-type
  (service-type (name 'qubes-acpi-shutdown)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-acpi-shutdown-shepherd-service)))
                (default-value #f)
                (description "Run acpid so dom0 qvm-shutdown can halt the VM.")))

(define %qubes-runtime-modules
  '((guix build utils)
    (ice-9 ftw)
    (ice-9 match)
    (ice-9 popen)
    (ice-9 textual-ports)
    (srfi srfi-1)
    (srfi srfi-13)))

(define-syntax qubes-vm-service-program
  (syntax-rules ()
    ((_ program-name body ...)
     (program-file
      program-name
      (with-imported-modules (source-module-closure %qubes-runtime-modules)
        #~(begin
            (use-modules (guix build utils)
                         (ice-9 ftw)
                         (ice-9 match)
                         (ice-9 popen)
                         (ice-9 textual-ports)
                         (srfi srfi-1)
                         (srfi srfi-13))

            (define modprobe
              #$(file-append
                 kmod
                 "/bin/modprobe"))
            (define mount
              "/run/current-system/profile/bin/mount")
            (define mountpoint
              "/run/current-system/profile/bin/mountpoint")
            (define mknod*
              "/run/current-system/profile/bin/mknod")
            (define qrexec-client-vm*
              "/run/current-system/profile/bin/qrexec-client-vm")
            (define qubesdb-read*
              "/run/current-system/profile/bin/qubesdb-read")
            (define qubesdb-write*
              "/run/current-system/profile/bin/qubesdb-write")
            (define kernel-modules-device
              "/dev/xvdd")
            (define kernel-modules-directory
              "/run/qubes-kernel-modules")

            (define (warn
                     message)
              (display message
                       (current-error-port))
              (newline (current-error-port)))

            (define (try-run* program . args)
              (false-if-exception
               (zero? (apply
                       system*
                       program
                       args))))

            (define (run* program . args)
              (unless (apply
                       try-run*
                       program
                       args)
                (warn (string-append
                       "command failed: "
                       program))
                (exit 1)))

            (define (exec* program . args)
              (apply execl
                     program
                     program
                     args))

            (define (read-file
                     path)
              (and (file-exists?
                    path)
                   (call-with-input-file path
                     get-string-all)))

            (define (string-trim-newlines
                     text)
              (let loop
                ((end (string-length
                       text)))
                (if (and (> end
                            0)
                         (memv (string-ref
                                text

                                (-
                                 end
                                 1))
                               '
                               (#\newline
                                #\return)))
                    (loop (- end
                           1))
                    (substring
                     text 0 end))))

            (define (command-output program . args)
              (let* ((port (apply
                            open-pipe*
                            OPEN_READ
                            program
                            args))
                     (text (get-string-all
                            port))
                     (status (close-pipe
                              port)))
                (and (zero?
                      status)
                     (string-trim-newlines
                      text))))

            (define (qubesdb-read
                     path)
              (command-output
               qubesdb-read*
               path))

            (define (qubesdb-write
                     path value)
              (try-run*
               qubesdb-write*
               path value))

            (define (group-gid
                     name)
              (let ((entry (false-if-exception
                            (getgr
                             name))))
                (and entry
                     (vector-ref
                      entry 2))))

            (define (profile-python-paths)
              (let* ((lib
                      "/run/current-system/profile/lib")
                     (versions (or
                                (false-if-exception
                                 (scandir
                                  lib
                                  (lambda
                                          (entry)

                                    (string-prefix?
                                     "python"
                                     entry))))
                                '())))
                (filter
                 file-exists?
                 (map (lambda (version)
                        (string-append
                         lib "/"
                         version
                         "/site-packages"))
                      versions))))

            (define (prepend-environment
                     name
                     entries)
              (unless (null?
                       entries)
                (let ((current (getenv
                                name)))
                  (setenv name
                          (string-append
                           (string-join
                            entries
                            ":")
                           (if (and
                                current

                                (not
                                 (string-null?
                                  current)))
                            (string-append
                             ":"
                             current)
                            ""))))))

            (define (kernel-release)
              (utsname:release (uname)))

            (define (kernel-modules-release-directory)
              (string-append
               kernel-modules-directory
               "/"
               (kernel-release)))

            (define (kernel-modules-mounted?)
              (try-run*
               mountpoint "-q"
               kernel-modules-directory))

            (define (kernel-modules-available?)
              (file-exists? (kernel-modules-release-directory)))

            (define (wait-for-path
                     path
                     attempts)
              (let loop
                ((attempt 0))
                (cond
                  ((file-exists?
                    path)
                   #t)
                  ((< attempt
                      attempts)
                   (usleep
                           100000)
                   (loop (+
                          attempt
                          1)))
                  (else #f))))

            (define (kernel-modules-setup
                     attempts)
              (mkdir-p
               kernel-modules-directory)
              (cond
                ((kernel-modules-available?)
                 #t)
                ((wait-for-path
                  kernel-modules-device
                  attempts)
                 (unless (kernel-modules-mounted?)
                   (unless (try-run*
                            mount
                            "-o"
                            "ro"
                            kernel-modules-device
                            kernel-modules-directory)
                     (warn (string-append
                            "failed to mount Qubes dom0 kernel modules image: "
                            kernel-modules-device))
                     (exit 1)))
                 (unless (kernel-modules-available?)
                   (warn (string-append
                          "Qubes dom0 kernel modules image is missing modules for "
                          (kernel-release)))
                   (exit 1)))
                (else (warn (string-append
                             "Qubes dom0 kernel modules device is not present: "
                             kernel-modules-device))
                      #f)))

            (define (runtime-setup)
              (setenv "PATH"
                      (string-append
                       "/run/setuid-programs:"
                       "/run/current-system/profile/bin:"
                       "/run/current-system/profile/sbin"
                       (let ((path
                              (getenv
                               "PATH")))
                         (if
                          path
                          (string-append
                           ":"
                           path)
                          ""))))
              (setenv
               "LINUX_MODULE_DIRECTORY"
               kernel-modules-directory)
              (for-each (match-lambda
                          ((name . value)
                           (setenv
                            name
                            value)))
                        '(("SSL_CERT_DIR" . "/etc/ssl/certs")
                          ("SSL_CERT_FILE" . "/etc/ssl/certs/ca-certificates.crt")
                          ("GIT_SSL_CAINFO" . "/etc/ssl/certs/ca-certificates.crt")
                          ("CURL_CA_BUNDLE" . "/etc/ssl/certs/ca-certificates.crt")))
              (let ((python-paths
                     (profile-python-paths)))
                (prepend-environment
                 "PYTHONPATH"
                 python-paths)
                (prepend-environment
                 "GUIX_PYTHONPATH"
                 python-paths))
              (setenv
               "QREXEC_SERVICE_PATH"
               (string-append
                "/run/qubes-rpc:/usr/local/etc/qubes-rpc:/etc/qubes-rpc:"
                "/run/current-system/profile/etc/qubes-rpc"))
              (setenv
               "QUBES_RPC_CONFIG_PATH"
               (string-append
                "/run/qubes/rpc-config:/usr/local/etc/qubes/rpc-config:"
                "/etc/qubes/rpc-config:"
                "/run/current-system/profile/etc/qubes/rpc-config"))
              (mkdir-p
               "/run/qubes")
              (mkdir-p
               "/run/qubes-service")
              (mkdir-p
               "/var/run")
              (mkdir-p
               "/var/log/qubes")
              (mkdir-p
               "/usr/local")
              (let ((gid (group-gid
                          "qubes")))
                (when gid
                  (false-if-exception
                   (chown
                    "/run/qubes"
                    -1 gid))))
              (chmod
               "/run/qubes"
               #o775))

            ;; The fixed compat symlinks
            ;; (incl. /var/run/qubes*) are
            ;; made once by the
            ;; qubes-vm-compat activation
            ;; applier, before any Shepherd
            ;; service; not recreated here.

            (define (misc-minor
                     names)
              (let ((text (read-file
                           "/proc/misc")))
                (and text
                     (any (lambda
                                  (line)
                            (let
                                 (
                                  (fields
                                   (string-tokenize
                                    line)))
                              (and
                               (=
                                (length
                                 fields)
                                2)
                               (member
                                (cadr
                                 fields)
                                names)
                               (car
                                fields))))
                          (string-split
                           text
                           #\newline)))))

            (define (ensure-xen-node
                     node names)
              (let ((path (string-append
                           "/dev/xen/"
                           node))
                    (minor (misc-minor
                            names)))
                (when (and minor
                       (not (file-exists?
                             path)))
                  (try-run*
                   mknod* path
                   "c" "10"
                   minor))))

            (define (xen-device-setup)
              (mkdir-p
               "/dev/xen")
              (mkdir-p
               "/proc/xen")
              (for-each (lambda
                                (module)
                          (try-run*
                           modprobe
                           module))
                        '("xenfs"
                          "xen_evtchn"
                          "xen_gntalloc"
                          "xen_gntdev"
                          "xen_privcmd"))
              (unless (try-run*
                       mountpoint
                       "-q"
                       "/proc/xen")
                (try-run* mount
                 "-t" "xenfs"
                 "xenfs"
                 "/proc/xen"))
              (for-each (lambda
                                (spec)
                          (ensure-xen-node
                           (car
                            spec)
                           (cdr
                            spec)))
                        '(("xenbus"
                           "xen/xenbus"
                           "xenbus")
                          ("hypercall"
                           "xen/hypercall"
                           "hypercall")
                          ("privcmd"
                           "xen/privcmd"
                           "privcmd")
                          ("evtchn"
                           "xen/evtchn"
                           "evtchn")
                          ("gntdev"
                           "xen/gntdev"
                           "gntdev")
                          ("gntalloc"
                           "xen/gntalloc"
                           "gntalloc")))
              (when (and (not (file-exists?
                               "/dev/xen/xenbus"))
                         (file-exists?
                          "/proc/xen/xenbus"))
                (false-if-exception
                 (symlink
                  "/proc/xen/xenbus"
                  "/dev/xen/xenbus")))
              (let ((gid (group-gid
                          "qubes")))
                (for-each (lambda
                                  (entry)
                            (let
                                 (
                                  (path
                                   (string-append
                                    "/dev/xen/"
                                    entry)))
                              (when gid

                                (false-if-exception
                                 (chown
                                  path
                                  -1
                                  gid)))
                              (false-if-exception
                               (chmod
                                path
                                #o660))))
                          (or (false-if-exception
                               (scandir
                                "/dev/xen"
                                (lambda
                                        (entry)

                                  (not
                                   (member
                                    entry
                                    '
                                    ("."
                                     ".."))))))
                              '())))
              (let wait
                ((attempt 0))
                (when (and (<
                            attempt
                            50)
                           (any (lambda
                                        (path)

                                  (not
                                   (file-exists?
                                    path)))
                                '
                                ("/dev/xen/xenbus"
                                 "/dev/xen/evtchn"
                                 "/dev/xen/gntalloc"
                                 "/dev/xen/gntdev"
                                 "/dev/xen/privcmd")))
                  (usleep 100000)
                  (wait (+
                         attempt
                         1)))))

            (define (prepare-service-runtime)
              (runtime-setup)
              (kernel-modules-setup
               0)
              (xen-device-setup))

            (define (service-enabled?
                     name)
              (file-exists? (string-append
                             "/run/qubes-service/"
                             name)))

            (define (wait-for-service-environment
                     attempts)
              (let loop
                ((attempt
                  attempts))
                (cond
                  ((file-exists?
                    "/run/qubes-service-environment")
                   #t)
                  ((zero?
                    attempt)
                   #f)
                  (else (usleep
                                100000)
                        (loop (-
                               attempt
                               1))))))

            body
            ...))))))

(define qubes-kvm-udev-rule
  (udev-rule "90-kvm.rules" "KERNEL==\"kvm\", GROUP=\"kvm\", MODE=\"0660\"\n"))

(define (qubes-udev-configurations-union subdirectory packages)
  "Return a @code{computed-file} that unions the udev SUBDIRECTORY (e.g.
@file{rules.d} or @file{hwdb.d}) found under the standard @file{/lib/udev}
and @file{/libexec/udev} locations of every package in PACKAGES."
  (define build
    (with-imported-modules '((guix build union)
                             (guix build utils))
                           #~(begin
                               (use-modules (guix build union)
                                            (guix build utils)
                                            (srfi srfi-1))

                               (define standard-locations
                                 '(#$(string-append "/lib/udev/" subdirectory)
                                   #$(string-append "/libexec/udev/"
                                                    subdirectory)))

                               (define (configuration-sub-directory directory)
                                 (find directory-exists?
                                       (map (lambda (suffix)
                                              (string-append directory suffix))
                                            standard-locations)))

                               (union-build #$output
                                            (filter-map
                                             configuration-sub-directory
                                             '#$packages)))))

  (computed-file (string-append "qubes-udev-" subdirectory) build))

(define (qubes-udev-rules-union packages)
  "Return a @code{computed-file} unioning the @file{rules.d} udev rules from
every package in PACKAGES."
  (qubes-udev-configurations-union "rules.d" packages))

(define (qubes-udev-hardware-union packages)
  "Return a @code{computed-file} unioning the @file{hwdb.d} udev hardware
database fragments from every package in PACKAGES."
  (qubes-udev-configurations-union "hwdb.d" packages))

(define qubes-udev.conf
  (computed-file "qubes-udev.conf"
                 #~(call-with-output-file #$output
                     (lambda (port)
                       (format port "udev_rules=\"/etc/udev/rules.d\"~%")))))

(define (qubes-udev-etc config)
  "Return the @file{/etc/udev} entries (an association list for
@code{etc-service-type}) built from the udev CONFIG: a merged
@file{udev.conf}, a unioned @file{rules.d}, and a compiled @file{hwdb.bin}."
  (let* ((udev (udev-configuration-udev config))
         (rules (udev-configuration-rules config))
         (hardware (udev-configuration-hardware config))
         (hardware-union (qubes-udev-hardware-union (cons* udev hardware)))
         (hwdb.bin (computed-file "qubes-udev-hwdb.bin"
                                  (with-imported-modules '((guix build utils))
                                                         #~(begin
                                                             (use-modules (guix
                                                                           build
                                                                           utils))
                                                             (setenv
                                                              "UDEV_HWDB_PATH"
                                                              #$hardware-union)
                                                             (invoke #+(file-append
                                                                        udev
                                                                        "/bin/udevadm")
                                                              "hwdb"
                                                              "--update" "-o"
                                                              #$output))))))
    `(("udev" ,(file-union "qubes-udev"
                           `(("udev.conf" ,qubes-udev.conf)
                             ("rules.d" ,(qubes-udev-rules-union (cons* udev
                                                                  qubes-kvm-udev-rule
                                                                  rules)))
                             ("hwdb.bin" ,hwdb.bin)))))))

(define (qubes-udev-coldplug-program config)
  "Return a @code{program-file} that waits for the udevd control socket and
then triggers and settles a coldplug pass (with bounded timeouts) so devices
present at boot are processed.  CONFIG is the udev configuration."
  (let ((udev (udev-configuration-udev config)))
    (program-file
     "qubes-udev-coldplug"
     (with-imported-modules '()
       #~(begin
           (define udevadm
             #$(file-append udev
                            "/bin/udevadm"))

           (define (wait-for-udev-control
                    attempts)
             (cond
               ((file-exists?
                 "/run/udev/control")
                #t)
               ((zero? attempts)
                (format #t
                 "udevd control socket not ready; continuing Qubes boot~%")
                #f)
               (else (usleep 500000)
                     (wait-for-udev-control (-
                                             attempts
                                             1)))))

           (define (reap-child pid)
             (false-if-exception (waitpid
                                  pid)))

           (define (terminate-child pid)
             (false-if-exception (kill pid
                                  SIGTERM))
             (usleep 200000)
             (false-if-exception (kill pid
                                  SIGKILL))
             (reap-child pid))

           (define (run-udevadm/bounded seconds . args)
             (let ((pid (primitive-fork)))
               (if (= pid 0)
                   (begin
                     (apply execl udevadm
                            udevadm args)
                     (exit 127))
                   (let wait
                     ((remaining (* seconds
                                    10)))
                     (let ((result (false-if-exception
                                    (waitpid
                                     pid
                                     WNOHANG))))
                       (cond
                         ((and result
                               (= (car
                                   result)
                                  pid))
                          (let ((status (cdr
                                         result)))
                            (and (not (status:term-sig
                                       status))
                                 (let ((exit-code
                                        (status:exit-val
                                         status)))
                                   (and
                                    exit-code
                                    (zero?
                                     exit-code))))))
                         ((zero? remaining)
                          (format #t
                           "udevadm command timed out: ~s~%"
                           args)
                          (terminate-child
                           pid) #f)
                         (else (usleep
                                       100000)
                               (wait (-
                                      remaining
                                      1)))))))))

           (when (wait-for-udev-control 20)
             (run-udevadm/bounded 5
              "trigger" "--action=add"
              "--type=devices")
             (run-udevadm/bounded 5
              "trigger" "--action=add"
              "--type=subsystems")
             (run-udevadm/bounded 5 "settle"
              "--timeout=5")))))))

(define (qubes-udev-shepherd-service config)
  "Return the Shepherd services that run eudev for the Qubes template: a
@code{udev} daemon that loads static device nodes from the dom0 kernel module
tree without blocking boot on a global settle, plus a @code{qubes-udev-coldplug}
trigger.  CONFIG is the udev configuration."
  (let ((udev (udev-configuration-udev config)))
    (list
     (shepherd-service
      (provision '(udev))
      (requirement '(root-file-system sysctl qubes-kernel-modules))
      (documentation
       "Run eudev without making Qubes boot wait for global settle.")
      (start
       (with-imported-modules
           (source-module-closure '((gnu build linux-boot)))
         #~(lambda ()
             (define udevd
               #$(file-append udev "/sbin/udevd"))

             (setenv "LINUX_MODULE_DIRECTORY" "/run/qubes-kernel-modules")

             (let* ((kernel-release (utsname:release (uname)))
                    (linux-module-directory
                     (getenv "LINUX_MODULE_DIRECTORY"))
                    (directory
                     (string-append linux-module-directory "/"
                                    kernel-release))
                    (old-umask (umask #o22)))
               (when (file-exists? directory)
                 (make-static-device-nodes directory))
               (umask old-umask))

             (fork+exec-command
              (list udevd
                    #$@(if (udev-configuration-debug? config)
                           '("--debug")
                           '()))
              #:environment-variables
              (cons* (string-append
                      "LINUX_MODULE_DIRECTORY="
                      (getenv "LINUX_MODULE_DIRECTORY"))
                     (default-environment-variables))))))
      (stop #~(make-kill-destructor))
      (respawn? #f)
      (modules `((gnu build linux-boot)
                 ,@%default-modules)))
     (shepherd-service
      (provision '(qubes-udev-coldplug))
      (requirement '(udev))
      (documentation
       "Trigger Qubes udev coldplug without blocking udev readiness.")
      (start
       #~(make-forkexec-constructor
          (list #$(qubes-udev-coldplug-program config))
          #:log-file
          "/var/log/qubes-udev-coldplug.log"))
      (stop #~(make-kill-destructor))
      (respawn? #f)))))

(define qubes-udev-service-type
  (service-type (name 'udev)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-udev-shepherd-service)
                                  (service-extension etc-service-type
                                                     qubes-udev-etc)))
                (compose concatenate)
                (extend (lambda (config rules)
                          (udev-configuration (inherit config)
                                              (rules (append (udev-configuration-rules
                                                              config) rules)))))
                (default-value (udev-configuration))
                (description "Run eudev with Qubes boot readiness semantics.")))

(define (run-one-shot-gexp program log-file best-effort?)
  "Return a Shepherd one-shot @code{start} gexp that forks PROGRAM with its
stdout/stderr appended to LOG-FILE.  When BEST-EFFORT? is true the service
always reports success; otherwise it reports PROGRAM's exit status."
  #~(lambda _
      (define (status-success? status)
        (and (not (status:term-sig status))
             (let ((exit-code (status:exit-val status)))
               (and exit-code
                    (zero? exit-code)))))

      (define (run/logged)
        (let ((pid (primitive-fork)))
          (if (= pid 0)
              (begin
                (let ((port (open-file #$log-file "a")))
                  (dup2 (fileno port) 1)
                  (dup2 (fileno port) 2)
                  (close-port port))
                (execl #$program
                       #$program))
              (cdr (waitpid pid)))))

      (let ((status (run/logged)))
        (if #$best-effort? #t
            (status-success? status)))))

(define* (one-shot-service name
                           requirements
                           program
                           log-file
                           #:key (best-effort? #f))
  "Return a one-shot @code{shepherd-service} provisioning NAME that runs
PROGRAM once after REQUIREMENTS are met, logging to LOG-FILE.  When
BEST-EFFORT? is true the service succeeds regardless of PROGRAM's exit status."
  (shepherd-service (provision (list name))
                    (requirement requirements)
                    (one-shot? #t)
                    (respawn? #f)
                    (documentation (string-append "Run "
                                                  (symbol->string name)
                                                  " once."))
                    (start (run-one-shot-gexp program log-file best-effort?))
                    (stop #~(const #f))))

(define (qubes-kernel-modules-program)
  "Return the program that mounts the Qubes dom0-provided kernel modules
image, waiting up to 300 seconds for it to appear."
  (qubes-vm-service-program "qubes-kernel-modules"
                            (runtime-setup)
                            (kernel-modules-setup 300)))

(define (qubes-kernel-modules-shepherd-service _)
  "Return the one-shot Shepherd service that runs the kernel-modules program.
The argument is the ignored service value."
  (list (one-shot-service 'qubes-kernel-modules
                          '(root-file-system)
                          (qubes-kernel-modules-program)
                          "/var/log/qubes-kernel-modules.log")))

(define qubes-kernel-modules-service-type
  (service-type (name 'qubes-kernel-modules)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-kernel-modules-shepherd-service)))
                (default-value #f)
                (description
                 "Mount the Qubes dom0-provided kernel modules image.")))

(define (qubes-sysctl-settings-file settings)
  "Return a @code{plain-file} holding the serialized SETTINGS alist, read back
at runtime by the sysctl program."
  (plain-file "qubes-sysctl-settings.scm"
              (object->string settings)))

(define (qubes-sysctl-program settings)
  "Return the program that applies the kernel sysctl SETTINGS by writing each
@code{key->value} pair to its @file{/proc/sys} path, failing loudly when a
path is missing or unwritable."
  (let ((settings-file (qubes-sysctl-settings-file settings)))
    (qubes-vm-service-program "qubes-sysctl"
                              (define sysctl-settings
                                (call-with-input-file #$settings-file
                                  read))

                              (define (sysctl-key->path key)
                                (string-append "/proc/sys/"
                                               (list->string (map (lambda (char)
                                                                    (if (char=?
                                                                         char
                                                                         #\.)
                                                                        #\/
                                                                        char))
                                                                  (string->list
                                                                   key)))))

                              (define (write-sysctl setting)
                                (let* ((key (car setting))
                                       (value (cdr setting))
                                       (path (sysctl-key->path key)))
                                  (unless (file-exists? path)
                                    (warn (string-append
                                           "sysctl path is missing: " path))
                                    (exit 1))
                                  (catch #t
                                         (lambda ()
                                           (call-with-output-file path
                                             (lambda (port)
                                               (display value port)
                                               (newline port))))
                                         (lambda (key . args)
                                           (warn (string-append
                                                  "failed to write sysctl path: "
                                                  path))
                                           (exit 1)))))

                              (for-each write-sysctl sysctl-settings))))

(define (qubes-sysctl-shepherd-service config)
  "Return the one-shot Shepherd service that applies the sysctl settings from
CONFIG, a @code{sysctl-configuration}."
  (list (one-shot-service 'sysctl
                          '(root-file-system)
                          (qubes-sysctl-program (sysctl-configuration-settings
                                                 config))
                          "/var/log/sysctl.log")))

(define qubes-sysctl-service-type
  (service-type (name 'sysctl)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-sysctl-shepherd-service)))
                (compose concatenate)
                (extend (lambda (config settings)
                          (sysctl-configuration
                           (inherit config)
                           (settings
                            (append (sysctl-configuration-settings config)
                                    settings)))))
                (default-value (sysctl-configuration))
                (description
                 "Apply kernel sysctl settings with a Qubes-local Scheme helper.")))

(define (qubes-loopback-program)
  "Return the program that brings the loopback interface up, waiting up to
about five seconds for the @file{lo} device to appear before failing."
  (qubes-vm-service-program "qubes-loopback"
                            (define ip
                              "/run/current-system/profile/sbin/ip")

                            (let wait
                              ((attempt 0))
                              (cond
                                ((file-exists? "/sys/class/net/lo")
                                 (run* ip "link" "set" "lo" "up")
                                 (exit 0))
                                ((< attempt 50)
                                 (usleep 100000)
                                 (wait (+ attempt 1)))
                                (else (warn
                                       "loopback network device did not appear")
                                      (exit 1))))))

(define (qubes-loopback-shepherd-service _)
  "Return the one-shot Shepherd service that brings up the loopback interface.
The argument is the ignored service value."
  (list (one-shot-service 'qubes-loopback
                          '(root-file-system)
                          (qubes-loopback-program)
                          "/var/log/qubes-loopback.log")))

(define qubes-loopback-service-type
  (service-type (name 'qubes-loopback)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-loopback-shepherd-service)))
                (default-value #f)
                (description
                 "Bring up the loopback interface without generic static networking.")))

(define (qubes-network-sysctl-program)
  "Return the program that applies the shared Qubes network sysctl settings to
all interfaces, reusing the helper forms from (qubes packages)."
  (qubes-vm-service-program "qubes-network-sysctl"
                            (define network-sysctl-settings
                              '#$%qubes-network-sysctl-settings)

                            #$@(qubes-network-sysctl-helper-forms)

                            (apply-sysctls-to-all-ifaces
                             network-sysctl-settings)))

(define (qubes-network-sysctl-shepherd-service _)
  "Return the one-shot Shepherd service that applies the Qubes network sysctl
settings.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-network-sysctl
                          '(root-file-system qubes-loopback)
                          (qubes-network-sysctl-program)
                          "/var/log/qubes-network-sysctl.log")))

(define qubes-network-sysctl-service-type
  (service-type (name 'qubes-network-sysctl)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-network-sysctl-shepherd-service)))
                (default-value #f)
                (description
                 "Apply Qubes network sysctl settings without early wildcard sysctl.")))

(define (qubes-db-program)
  "Return the program that prepares the service runtime and execs the QubesDB
VM daemon."
  (qubes-vm-service-program "qubes-db"
                            (prepare-service-runtime)
                            (exec*
                             "/run/current-system/profile/bin/qubesdb-daemon"
                             "0")))

(define (qubes-db-shepherd-service _)
  "Return the Shepherd service that runs the QubesDB VM daemon.  The argument
is the ignored service value."
  (list (shepherd-service (provision '(qubes-db))
                          (requirement '(root-file-system qubes-kernel-modules))
                          (documentation "Run the QubesDB VM daemon.")
                          (start #~(make-forkexec-constructor (list #$(qubes-db-program))
                                    #:log-file "/var/log/qubes-db.log"))
                          (stop #~(make-kill-destructor)))))

(define qubes-db-service-type
  (service-type (name 'qubes-db)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-db-shepherd-service)))
                (default-value #f)
                (description "Run QubesDB inside a Qubes VM.")))

(define (qubes-early-vm-config-program)
  "Return the program that runs the Qubes early VM configuration script
(@file{qubes-early-vm-config.sh}), which applies dom0-supplied settings such
as the hostname and timezone."
  (qubes-vm-service-program "qubes-early-vm-config"
                            (prepare-service-runtime)
                            (exec*
                             "/usr/lib/qubes/init/qubes-early-vm-config.sh")))

(define (qubes-early-vm-config-shepherd-service _)
  "Return the one-shot Shepherd service that runs the early VM configuration
program after QubesDB is up.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-early-vm-config
                          '(qubes-db)
                          (qubes-early-vm-config-program)
                          "/var/log/qubes-early-vm-config.log")))

(define qubes-early-vm-config-service-type
  (service-type (name 'qubes-early-vm-config)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-early-vm-config-shepherd-service)))
                (default-value #f)
                (description
                 "Apply early Qubes VM configuration such as hostname and timezone.")))

(define (qubes-sysinit-program)
  "Return the program that runs the Qubes VM sysinit script
(@file{qubes-sysinit.sh})."
  (qubes-vm-service-program "qubes-sysinit"
                            (prepare-service-runtime)
                            (exec* "/usr/lib/qubes/init/qubes-sysinit.sh")))

(define (qubes-sysinit-shepherd-service _)
  "Return the one-shot Shepherd service that runs Qubes sysinit after early VM
configuration.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-sysinit
                          '(qubes-early-vm-config)
                          (qubes-sysinit-program) "/var/log/qubes-sysinit.log")))

(define qubes-sysinit-service-type
  (service-type (name 'qubes-sysinit)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-sysinit-shepherd-service)))
                (default-value #f)
                (description "Run Qubes VM sysinit.")))

(define-record-type* <qubes-meminfo-writer-configuration>
                     qubes-meminfo-writer-configuration
                     make-qubes-meminfo-writer-configuration
  qubes-meminfo-writer-configuration?
  (package
    qubes-meminfo-writer-configuration-package
    (default qubes-vm-utils))
  (threshold qubes-meminfo-writer-configuration-threshold
             (default 30000))
  (delay qubes-meminfo-writer-configuration-delay
         (default 100000))
  (pid-file qubes-meminfo-writer-configuration-pid-file
            (default "/var/run/meminfo-writer.pid")))

(define (qubes-meminfo-writer-program config)
  "Return the program that starts the Qubes @command{meminfo-writer} daemon
(used by dom0 memory ballooning) with the threshold, delay, and pid-file from
CONFIG, exiting cleanly when the meminfo-writer service flag is absent."
  (let ((meminfo-writer (file-append (qubes-meminfo-writer-configuration-package
                                      config) "/bin/meminfo-writer"))
        (threshold (number->string (qubes-meminfo-writer-configuration-threshold
                                    config)))
        (delay (number->string (qubes-meminfo-writer-configuration-delay
                                config)))
        (pid-file (qubes-meminfo-writer-configuration-pid-file config)))
    (qubes-vm-service-program "qubes-meminfo-writer"
      (define pidfile
        #$pid-file)

      (define (read-pid path)
        (and (file-exists? path)
             (let ((text (call-with-input-file path
                           get-string-all)))
               (string->number (string-trim-both text)))))

      (prepare-service-runtime)

      (unless (service-enabled? "meminfo-writer")
        (display
         "meminfo-writer service flag not present; exiting
")
        (exit 0))

      (when (file-exists? pidfile)
        (delete-file pidfile))
      (unless (zero? (system* #$meminfo-writer
                              #$threshold
                              #$delay pidfile))
        (warn "meminfo-writer failed to start")
        (exit 1))

      (let wait-for-pid
        ((attempt 0))
        (let ((pid (read-pid pidfile)))
          (cond
            ((and pid
                  (> pid 1))
             (sigaction SIGTERM
                        (lambda _
                          (false-if-exception (kill
                                               pid
                                               SIGTERM))
                          (false-if-exception (delete-file
                                               pidfile))
                          (exit 0)))
             (sigaction SIGINT
                        (lambda _
                          (false-if-exception (kill
                                               pid
                                               SIGTERM))
                          (false-if-exception (delete-file
                                               pidfile))
                          (exit 0)))
             (let loop
               ()
               (if (false-if-exception (kill pid 0))
                   (begin
                     (sleep 60)
                     (loop))
                   (begin
                     (false-if-exception (delete-file
                                          pidfile))
                     (exit 1)))))
            ((< attempt 50)
             (usleep 100000)
             (wait-for-pid (+ attempt 1)))
            (else (warn
                   "meminfo-writer did not create a valid pid file")
                  (exit 1))))))))

(define (qubes-meminfo-writer-shepherd-service config)
  "Return the Shepherd service that runs the Qubes memory information reporter
for dom0 ballooning, built from CONFIG, a
@code{qubes-meminfo-writer-configuration}."
  (list (shepherd-service (provision '(qubes-meminfo-writer))
                          (requirement '(qubes-sysinit))
                          (documentation
                           "Run the Qubes memory information reporter.")
                          (respawn? #f)
                          (start
                           #~(make-forkexec-constructor
                              (list #$(qubes-meminfo-writer-program config))
                              #:log-file "/var/log/qubes-meminfo-writer.log"))
                          (stop #~(make-kill-destructor)))))

(define qubes-meminfo-writer-service-type
  (service-type (name 'qubes-meminfo-writer)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-meminfo-writer-shepherd-service)))
                (default-value (qubes-meminfo-writer-configuration))
                (description
                 "Run Qubes memory usage reporting for dom0 ballooning.")))

(define (qubes-network-uplink-program)
  "Return the program that configures the Qubes-provided VM network uplink: it
finds the dom0-assigned interface (by MAC from QubesDB), applies the network
sysctl settings to it, and runs @file{setup-ip add}, waiting up to about 30
seconds for the interface to appear."
  (qubes-vm-service-program "qubes-network-uplink"
                            (define ip
                              "/run/current-system/profile/sbin/ip")
                            (define network-sysctl-settings
                              '#$%qubes-network-sysctl-settings)

                            (define (iface-mac iface)
                              (and iface
                                   (read-file (string-append "/sys/class/net/"
                                               iface "/address"))))

                            (define (iface-for-mac mac)
                              (and mac
                                   (any (lambda (iface)
                                          (let ((address (iface-mac iface)))
                                            (and address
                                                 (string-ci=? (string-trim-newlines
                                                               address) mac)
                                                 iface)))
                                        (or (false-if-exception (scandir
                                                                 "/sys/class/net"
                                                                 (lambda (entry)
                                                                   (not (member
                                                                         entry
                                                                         '("."
                                                                           ".."))))))
                                            '()))))

                            (define (qubes-managed-iface)
                              (let ((mac (qubesdb-read "/qubes-mac")))
                                (and mac
                                     (begin
                                       (unless (file-exists?
                                                "/sys/module/xen_netfront")
                                         (try-run* modprobe "xen-netfront"))
                                       (or (iface-for-mac mac)
                                           (and (file-exists?
                                                 "/sys/class/net/eth0") "eth0"))))))

                            #$@(qubes-network-sysctl-helper-forms)

                            (prepare-service-runtime)
                            (try-run* ip "link" "set" "lo" "up")
                            (let wait
                              ((attempt 0))
                              (let ((iface (qubes-managed-iface)))
                                (cond
                                  (iface (apply-sysctls-to-iface
                                          network-sysctl-settings iface)
                                         (exec* "/usr/lib/qubes/setup-ip"
                                                "add" iface))
                                  ((< attempt 300)
                                   (usleep 100000)
                                   (wait (+ attempt 1)))
                                  (else (display
                                         "No Qubes managed network interface found
")
                                        (exit 0)))))))

(define (qubes-network-uplink-shepherd-service _)
  "Return the one-shot Shepherd service that configures the Qubes VM network
uplink.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-network-uplink
                          '(qubes-sysinit sysctl qubes-network-sysctl)
                          (qubes-network-uplink-program)
                          "/var/log/qubes-network-uplink.log")))

(define qubes-network-uplink-service-type
  (service-type (name 'qubes-network-uplink)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-network-uplink-shepherd-service)))
                (default-value #f)
                (description "Configure the Qubes-provided VM network uplink.")))

(define (qubes-network-program)
  "Return the program that activates the Qubes network backend in a NetVM: it
loads the Xen netback module and writes the required network control files,
exiting cleanly when the qubes-network service flag is absent or no netvm
network is configured."
  (qubes-vm-service-program "qubes-network"
    (define dnat-helper
      "/usr/lib/qubes/qubes-setup-dnat-to-ns")

    (define (write-required-file path value)
      (unless (file-exists? path)
        (warn (string-append
               "required network control file is missing: "
               path))
        (exit 1))
      (catch #t
             (lambda ()
               (call-with-output-file path
                 (lambda (port)
                   (display value port)
                   (newline port))))
             (lambda (key . args)
               (warn (string-append
                      "failed to write network control file: "
                      path))
               (exit 1))))

    (define (write-optional-file path value)
      (when (file-exists? path)
        (false-if-exception (call-with-output-file path
                              (lambda (port)
                                (display value port)
                                (newline port))))))

    (define (module-loaded? name)
      (file-exists? (string-append "/sys/module/" name)))

    (define (network-backend-loaded?)
      (or (module-loaded? "netbk")
          (module-loaded? "xen_netback")))

    (define (load-network-backend)
      (unless (or (network-backend-loaded?)
                  (try-run* modprobe "netbk")
                  (try-run* modprobe "xen-netback")
                  (network-backend-loaded?))
        (warn
         "could not load Xen network backend module")
        (exit 1)))

    (prepare-service-runtime)
    (wait-for-service-environment 600)
    (cond
      ((not (service-enabled? "qubes-network"))
       (display
        "qubes-network service flag not present; network backend inactive
")
       (exit 0))
      ((string-null? (or (qubesdb-read
                          "/qubes-netvm-network") ""))
       (display
        "No Qubes downstream network configured for this VM
")
       (exit 0))
      (else (load-network-backend)
            (run* dnat-helper)
            (write-required-file
             "/proc/sys/net/ipv4/ip_forward" "1")
            (unless (string-null? (or (qubesdb-read
                                       "/qubes-netvm-gateway6")
                                      ""))
              (write-optional-file
               "/proc/sys/net/ipv6/conf/all/forwarding"
               "1"))))))

(define (qubes-network-shepherd-service _)
  "Return the one-shot Shepherd service that activates the Qubes network
backend role.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-network
                          '(qubes-sysinit sysctl qubes-network-sysctl
                                          qubes-network-uplink)
                          (qubes-network-program) "/var/log/qubes-network.log")))

(define qubes-network-service-type
  (service-type (name 'qubes-network)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-network-shepherd-service)))
                (default-value #f)
                (description
                 "Configure the Qubes network backend role for NetVMs.")))

(define (qubes-feature-advertisement-program)
  "Return the program that advertises to dom0, via QubesDB feature requests
and a qubes.FeaturesRequest qrexec call, the Qubes services this template
implements natively (updates-proxy-setup, qubes-network, and PipeWire audio
when installed), after waiting for the qrexec-agent socket."
  (qubes-vm-service-program "qubes-feature-advertisement"
                            (define supported-services
                              '("updates-proxy-setup" "qubes-network"))

                            (define (request-feature name value)
                              (unless (qubesdb-write (string-append
                                                      "/features-request/"
                                                      name) value)
                                (warn (string-append
                                       "failed to write Qubes feature request: "
                                       name))
                                (exit 1)))

                            (prepare-service-runtime)
                            (for-each (lambda (service)
                                        (request-feature (string-append
                                                          "supported-service."
                                                          service) "1"))
                                      supported-services)
                            ;; Advertise PipeWire audio only when it is actually
                            ;; installed (normal variant), so dom0 attaches the
                            ;; AudioVM vchan for sound.
                            (when (file-exists?
                                   "/run/current-system/profile/bin/pipewire")
                              (request-feature "supported-service.pipewire" "1"))
                            ;; qrexec-agent's shepherd service may report started
                            ;; before its client socket exists; wait for it so
                            ;; the commit does not race and fail.
                            (wait-for-path "/var/run/qubes/qrexec-agent" 600)
                            (unless (try-run* qrexec-client-vm* "dom0"
                                              "qubes.FeaturesRequest")
                              (warn "failed to commit Qubes feature requests")
                              (exit 1))))

(define (qubes-feature-advertisement-shepherd-service _)
  "Return the one-shot Shepherd service that runs the feature-advertisement
program after the qrexec agent is up.  The argument is the ignored service
value."
  (list (one-shot-service 'qubes-feature-advertisement
                          '(qubes-qrexec-agent)
                          (qubes-feature-advertisement-program)
                          "/var/log/qubes-feature-advertisement.log")))

(define qubes-feature-advertisement-service-type
  (service-type (name 'qubes-feature-advertisement)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-feature-advertisement-shepherd-service)))
                (default-value #f)
                (description
                 "Advertise Qubes services implemented by native Guix services.")))

(define (qubes-updates-proxy-forwarder-program)
  "Return the program that, on a non-proxy AppVM with the updates-proxy-setup
flag set, publishes a loopback proxy on 127.0.0.1:8082 forwarding to the
qubes.UpdatesProxy RPC via socat, so substitute fetches resolve through dom0
instead of guest DNS.  It exits cleanly when the flag is absent or this VM is
itself the proxy."
  (qubes-vm-service-program "qubes-updates-proxy-forwarder"
    (runtime-setup)
    (wait-for-service-environment 600)
    (cond
      ((not (service-enabled? "updates-proxy-setup"))
       (display
        "updates-proxy-setup service flag not present; forwarder inactive
")
       (exit 0))
      ((service-enabled? "qubes-updates-proxy")
       (display
        "qubes-updates-proxy enabled locally; not forwarding to avoid loops
")
       (exit 0))
      (else
       ;; Reached only when the updates-proxy-setup
       ;; flag is set (the first cond clause exits
       ;; otherwise) and this VM is not itself the
       ;; proxy.  Export the loopback proxy that this
       ;; forwarder publishes on 127.0.0.1:8082 so
       ;; substitute fetches resolve
       ;; bordeaux/ci.guix.gnu.org via the
       ;; qubes.UpdatesProxy CONNECT path instead of
       ;; guest DNS, which has no resolver in a
       ;; ProxyVM-served AppVM ("host not found").  This
       ;; is the gated local half of G-OPEN-2;
       ;; guix-daemon itself is deliberately left
       ;; unproxied in %qubes-base-services for the
       ;; flag-absent case.
       (setenv "http_proxy" "http://127.0.0.1:8082")
       (setenv "https_proxy" "http://127.0.0.1:8082")
       (exec* "/run/current-system/profile/bin/socat"
        "TCP-LISTEN:8082,bind=127.0.0.1,reuseaddr,fork"
        "EXEC:/usr/lib/qubes/guix-updates-proxy-forwarder")))))

(define (qubes-updates-proxy-forwarder-shepherd-service _)
  "Return the Shepherd service that runs the updates-proxy forwarder socket.
The argument is the ignored service value."
  (list (shepherd-service (provision '(qubes-updates-proxy-forwarder))
                          (requirement '(qubes-sysinit qubes-loopback))
                          (documentation
                           "Forward 127.0.0.1:8082 to Qubes UpdatesProxy RPC.")
                          (respawn? #f)
                          (start
                           #~(make-forkexec-constructor
                              (list #$(qubes-updates-proxy-forwarder-program))
                              #:log-file
                              "/var/log/qubes-updates-proxy-forwarder.log"))
                          (stop #~(make-kill-destructor)))))

(define qubes-updates-proxy-forwarder-service-type
  (service-type (name 'qubes-updates-proxy-forwarder)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-updates-proxy-forwarder-shepherd-service)))
                (default-value #f)
                (description
                 "Run the Qubes updates proxy forwarder socket service.")))

(define (qubes-mount-dirs-program)
  "Return the program that mounts the Qubes persistent directories (/rw,
/home, /usr/local): it waits for the private-volume device, materializes and
repairs the writable /etc/fstab /rw entry, and runs @file{mount-dirs.sh}."
  (qubes-vm-service-program "qubes-mount-dirs"
    (define findmnt
      "/run/current-system/profile/bin/findmnt")
    (define mount-dirs
      "/usr/lib/qubes/init/mount-dirs.sh")
    ;; Qubes tools write /etc/fstab at runtime to add
    ;; the /rw mount; on Guix /etc/fstab is an immutable
    ;; store symlink that must be materialized to a
    ;; writable file (done once by the qubes-vm-compat
    ;; activation applier) to permit this.  This service
    ;; is the single runtime writer of the /rw entry.
    (define fstab-entry
      "/dev/xvdb /rw auto noauto,defaults,discard,nosuid,nodev 1 2
")

    (define (mounted? path)
      (try-run* findmnt "-rn" path))

    (define (fstab-has-rw?)
      (let ((text (read-file "/etc/fstab")))
        (and text
             (any (lambda (line)
                    (let ((fields (string-tokenize
                                   line)))
                      (and (>= (length fields) 2)
                           (not (string-prefix? "#"
                                                (car
                                                 fields)))
                           (string=? (cadr fields)
                                     "/rw"))))
                  (string-split text #\newline)))))

    (define (append-fstab-entry)
      (let ((port (open-file "/etc/fstab" "a")))
        (display fstab-entry port)
        (close-port port)))

    (define (repair-fstab-entry)
      (when (and (or (file-exists? "/dev/xvdb")
                     (mounted? "/rw"))
                 (not (fstab-has-rw?)))
        (append-fstab-entry)))

    (define (wait-for-rw-device)
      (when (string=? (or (qubesdb-read
                           "/qubes-vm-persistence") "")
                      "rw-only")
        (let loop
          ((attempt 0))
          (cond
            ((file-exists? "/dev/xvdb")
             #t)
            ((< attempt 300)
             (usleep 100000)
             (loop (+ attempt 1)))
            (else (warn
                   "Qubes private-volume device /dev/xvdb did not appear")
                  (exit 1))))))

    (prepare-service-runtime)
    (wait-for-rw-device)
    (repair-fstab-entry)
    (when (and (mounted? "/rw")
               (mounted? "/home")
               (mounted? "/usr/local"))
      (display
       "Qubes private directories already mounted
")
      (exit 0))
    (run* mount-dirs)
    (repair-fstab-entry)))

(define (qubes-mount-dirs-shepherd-service _)
  "Return the one-shot Shepherd service that mounts the Qubes persistent
directories.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-mount-dirs
                          '(qubes-sysinit)
                          (qubes-mount-dirs-program)
                          "/var/log/qubes-mount-dirs.log")))

(define qubes-mount-dirs-service-type
  (service-type (name 'qubes-mount-dirs)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-mount-dirs-shepherd-service)))
                (default-value #f)
                (description
                 "Mount Qubes persistent directories such as /rw, /home, and
/usr/local.")))

(define (qubes-bind-dirs-program)
  "Return the program that applies the Qubes bind-dirs configuration by
running @file{bind-dirs.sh}."
  (qubes-vm-service-program "qubes-bind-dirs"
                            (prepare-service-runtime)
                            (exec* "/usr/lib/qubes/init/bind-dirs.sh")))

(define (qubes-bind-dirs-shepherd-service _)
  "Return the one-shot Shepherd service that applies bind-dirs after the
persistent directories are mounted.  The argument is the ignored service
value."
  (list (one-shot-service 'qubes-bind-dirs
                          '(qubes-mount-dirs)
                          (qubes-bind-dirs-program)
                          "/var/log/qubes-bind-dirs.log")))

(define qubes-bind-dirs-service-type
  (service-type (name 'qubes-bind-dirs)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-bind-dirs-shepherd-service)))
                (default-value #f)
                (description "Apply Qubes bind-dirs configuration.")))

(define (qubes-misc-post-program)
  "Return the program that runs the Qubes @file{misc-post.sh} late-boot
script, warning on a non-zero exit but always succeeding so it never blocks
boot."
  (qubes-vm-service-program "qubes-misc-post"
                            (prepare-service-runtime)
                            (let ((status (system*
                                           "/usr/lib/qubes/init/misc-post.sh")))
                              (unless (zero? status)
                                (warn (string-append
                                       "qubes-misc-post exited with status "
                                       (number->string status)))))
                            (exit 0)))

(define (qubes-misc-post-shepherd-service _)
  "Return the best-effort one-shot Shepherd service that runs the misc-post
late-boot script.  The argument is the ignored service value."
  (list (one-shot-service 'qubes-misc-post
                          '(qubes-bind-dirs)
                          (qubes-misc-post-program)
                          "/var/log/qubes-misc-post.log"
                          #:best-effort? #t)))

(define qubes-misc-post-service-type
  (service-type (name 'qubes-misc-post)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-misc-post-shepherd-service)))
                (default-value #f)
                (description "Run late Qubes VM setup.")))

(define (qubes-qrexec-agent-program)
  "Return the program that prepares the service runtime and execs the Qubes
qrexec agent."
  (qubes-vm-service-program "qubes-qrexec-agent"
                            (prepare-service-runtime)
                            (exec* "/usr/lib/qubes/qrexec-agent")))

(define (qubes-qrexec-agent-shepherd-service _)
  "Return the Shepherd service that runs the Qubes qrexec agent.  The argument
is the ignored service value."
  (list (shepherd-service (provision '(qubes-qrexec-agent))
                          (requirement '(qubes-bind-dirs))
                          (documentation "Run the Qubes qrexec agent.")
                          (start
                           #~(make-forkexec-constructor
                              (list #$(qubes-qrexec-agent-program))
                              #:log-file "/var/log/qubes-qrexec-agent.log"))
                          (stop #~(make-kill-destructor)))))

(define qubes-qrexec-agent-service-type
  (service-type (name 'qubes-qrexec-agent)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-qrexec-agent-shepherd-service)))
                (default-value #f)
                (description "Run the Qubes qrexec agent.")))

(define (qubes-gui-agent-program)
  "Return the program that starts the Qubes GUI agent: it runs the GUI
pre-start script, reads the dom0-provided DISPLAY and GUI_OPTS from the
service environment, and execs @command{qubes-gui}.  It exits cleanly when
dom0 has not enabled the GUI for this VM."
  (qubes-vm-service-program "qubes-gui-agent"
                            (define (read-service-environment)
                              (let ((text (read-file
                                           "/run/qubes-service-environment")))
                                (if text
                                    (filter-map (lambda (line)
                                                  (let ((index (string-index
                                                                line #\=)))
                                                    (and index
                                                         (cons (substring line
                                                                0 index)
                                                               (substring line
                                                                (+ index 1))))))
                                                (string-split text #\newline))
                                    '())))

                            (define (environment-ref entries key default)
                              (match (assoc key entries)
                                ((_ . value) value)
                                (_ default)))

                            (prepare-service-runtime)
                            (unless (string=? (or (command-output
                                                   qubesdb-read*
                                                   "/qubes-gui-enabled")
                                                  "True") "True")
                              (exit 0))
                            (setenv "DISPLAY" ":0")
                            (run* "/usr/lib/qubes/qubes-gui-agent-pre.sh")
                            (let* ((entries (read-service-environment))
                                   (display (environment-ref entries "DISPLAY"
                                                             ":0"))
                                   (gui-opts (environment-ref entries
                                                              "GUI_OPTS" "")))
                              (setenv "DISPLAY" display)
                              (setenv "GUI_OPTS" gui-opts)
                              (let ((qubes-gui
                                     "/run/current-system/profile/bin/qubes-gui"))
                                (apply execl qubes-gui qubes-gui
                                       (string-tokenize gui-opts))))))

(define (qubes-gui-agent-shepherd-service _)
  "Return the Shepherd service that runs the Qubes GUI agent.  The argument is
the ignored service value."
  (list (shepherd-service (provision '(qubes-gui-agent))
                          (requirement '(user-processes qubes-bind-dirs
                                                        qubes-qrexec-agent))
                          (documentation "Run the Qubes GUI agent.")
                          (start
                           #~(make-forkexec-constructor
                              (list #$(qubes-gui-agent-program))
                              #:log-file "/var/log/qubes-gui-agent.log"))
                          (stop #~(make-kill-destructor)))))

(define qubes-gui-agent-service-type
  (service-type (name 'qubes-gui-agent)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   qubes-gui-agent-shepherd-service)))
                (default-value #f)
                (description "Run the Qubes GUI agent.")))

(define %qubes-vm-headless-services
  (list (service qubes-vm-compat-service-type)
        (service qubes-kernel-modules-service-type)
        (service qubes-udev-service-type
                 (udev-configuration (rules '())))
        (service qubes-loopback-service-type)
        (service login-service-type)
        (service agetty-service-type
                 (agetty-configuration (tty "hvc0")
                                       (term "vt100")
                                       (shepherd-requirement '(qubes-sysinit))))
        (service qubes-qrexec-pam-service-type)
        (service qubes-acpi-shutdown-service-type)
        (service qubes-db-service-type)
        (service qubes-early-vm-config-service-type)
        (service qubes-sysinit-service-type)
        (service qubes-meminfo-writer-service-type)
        (service qubes-network-sysctl-service-type)
        (service qubes-network-uplink-service-type)
        (service qubes-network-service-type)
        (service qubes-updates-proxy-forwarder-service-type)
        (service qubes-mount-dirs-service-type)
        (service qubes-bind-dirs-service-type)
        (service qubes-misc-post-service-type)
        (service qubes-qrexec-agent-service-type)
        (service qubes-feature-advertisement-service-type)))

(define %qubes-vm-gui-services
  (append %qubes-vm-headless-services
          (list (service qubes-gui-agent-service-type))))

(define %qubes-omitted-base-service-types
  '(agetty console-fonts
           etc-bashrc-d
           login
           log-cleanup
           log-rotation
           mingetty
           nscd
           shepherd-timer
           shepherd-transient
           static-networking
           sysctl
           udev
           virtual-terminal))

(define %qubes-kernel-sysctl-settings
  '(("kernel.threads-max" . "51200")))

(define %qubes-base-services
  ;; Keep the daemon usable in ordinary networked AppVMs.  The Qubes updates
  ;; proxy forwarder is gated by the updates-proxy-setup service flag; forcing
  ;; guix-daemon through 127.0.0.1:8082 here breaks substitute downloads when
  ;; that flag is absent.
  %base-services)

(define %qubes-sysctl-service
  (service qubes-sysctl-service-type
           (sysctl-configuration (settings (append
                                            %qubes-kernel-sysctl-settings
                                            %default-sysctl-settings)))))

(define %qubes-minimal-base-services
  (filter (lambda (service)
            (not (memq (service-type-name (service-kind service))
                       %qubes-omitted-base-service-types)))
          %qubes-base-services))
