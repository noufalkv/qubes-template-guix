;; SPDX-License-Identifier: GPL-3.0-or-later
;; Qubes VM Shepherd services for the qubes-template-guix channel.

(define-module (qubes services)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (gnu)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages xorg)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services sysctl)
  #:use-module (gnu system pam)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (qubes packages)
  #:export (%qubes-vm-headless-services
            %qubes-vm-gui-services
            %qubes-sysctl-service
            %qubes-minimal-base-services))

(define (qubes-vm-compat-activation _)
  #~(begin
	      (use-modules (guix build utils)
	                   (ice-9 ftw)
	                   (ice-9 textual-ports)
	                   (srfi srfi-13))

      (define (empty-directory? directory)
        (null? (scandir directory
                        (lambda (entry)
                          (not (member entry '("." "..")))))))

      (define (replace-symlink target link)
        (mkdir-p (dirname link))
        (let ((existing (false-if-exception (lstat link))))
          (cond
           ((and existing (memq (stat:type existing) '(regular symlink)))
            (delete-file link))
           ((and existing
                 (eq? (stat:type existing) 'directory)
                 (empty-directory? link))
            (rmdir link)))
          (unless (file-exists? link)
            (symlink target link))))

      (define (symlink?* path)
        (let ((existing (false-if-exception (lstat path))))
          (and existing (eq? (stat:type existing) 'symlink))))

      (define (regular-or-symlink? path)
        (let ((existing (false-if-exception (lstat path))))
          (and existing (memq (stat:type existing) '(regular symlink)))))

      (define (same-directory-entry? left right)
        (let ((left-stat (false-if-exception (stat left)))
              (right-stat (false-if-exception (stat right))))
          (and left-stat right-stat
               (= (stat:dev left-stat) (stat:dev right-stat))
               (= (stat:ino left-stat) (stat:ino right-stat)))))

      (define (link-directory-contents source directory)
        (materialize-symlinked-directory directory)
        (mkdir-p directory)
        (unless (symlink?* directory)
          (when (file-exists? source)
            (for-each
             (lambda (entry)
               (let ((target (string-append source "/" entry))
                     (link (string-append directory "/" entry)))
                 (when (symlink?* link)
                   (delete-file link))
                 (unless (file-exists? link)
                   (symlink target link))))
             (scandir source
                      (lambda (entry)
                        (not (member entry '("." "..")))))))))

      (define (write-text-file path text)
        (mkdir-p (dirname path))
        (call-with-output-file path
          (lambda (port)
            (display text port))))

      (define tls-profile-script
        (string-append
         "export SSL_CERT_DIR=${SSL_CERT_DIR:-/etc/ssl/certs}\n"
         "export SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}\n"
         "export GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-/etc/ssl/certs/ca-certificates.crt}\n"
         "export CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}\n"))

      (define guix-cache-profile-script
        (string-append
         "if [ \"${XDG_CACHE_HOME+x}\" != x ]; then\n"
         "    export XDG_CACHE_HOME=/var/tmp/guix-cache-${USER:-user}\n"
         "fi\n"))

      (define (materialize-symlinked-directory directory)
        (let ((existing (false-if-exception (lstat directory))))
          (when (and existing (eq? (stat:type existing) 'symlink))
            (let* ((target (readlink directory))
                   (absolute-target
                    (if (and (positive? (string-length target))
                             (char=? (string-ref target 0) #\/))
                        target
                        (string-append (dirname directory) "/" target)))
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
	          (when (and existing (eq? (stat:type existing) 'symlink))
            (let* ((target (readlink file))
                   (absolute-target
                    (if (and (positive? (string-length target))
                             (char=? (string-ref target 0) #\/))
                        target
                        (string-append (dirname file) "/" target)))
                   (temporary (string-append file ".qubes-tmp")))
              (when (file-exists? temporary)
                (delete-file temporary))
              (when (file-exists? absolute-target)
                (copy-file absolute-target temporary)
                (chmod temporary #o644)
	                (delete-file file)
	                (rename-file temporary file))))))

	      (define (read-text file)
	        (call-with-input-file file get-string-all))

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
	                      (write-text
	                       uca
	                       (string-append (substring text 0 index)
	                                      actions
	                                      "\n"
	                                      (substring text index)))
	                      (write-text
	                       uca
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
      ;; Guix exposes /etc/fstab as an immutable store symlink.  Qubes'
      ;; mount-dirs script expects to add the private /rw volume there.
      (materialize-symlinked-file "/etc/fstab")
      (write-text-file "/etc/acpi/events/qubes-power-button"
                       "event=button/power.*\naction=/etc/acpi/actions/qubes-poweroff\n")
      (write-text-file "/etc/acpi/actions/qubes-poweroff"
                       "#!/run/current-system/profile/bin/guile -s
!#
(execl \"/run/current-system/profile/sbin/halt\" \"halt\")
")
      (chmod "/etc/acpi/actions/qubes-poweroff" #o555)
      (replace-symlink "/run/current-system/profile/bin" "/usr/bin")
      (replace-symlink "/run/current-system/profile/sbin" "/usr/sbin")
      (replace-symlink "/run/current-system/profile/share" "/usr/share")
      (replace-symlink "/run/current-system/profile/lib/qubes" "/usr/lib/qubes")
      (replace-symlink "/run/current-system/profile/lib/qubes-bind-dirs.d"
                       "/usr/lib/qubes-bind-dirs.d")
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
      (link-directory-contents "/run/current-system/profile/etc/X11" "/etc/X11")
      (link-directory-contents "/run/current-system/profile/etc/sysconfig"
                               "/etc/sysconfig")
      (link-directory-contents "/run/current-system/profile/etc/profile.d"
                               "/etc/profile.d")
      (for-each
       (lambda (path)
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
      (replace-symlink "/run/current-system/profile/sbin/halt" "/sbin/poweroff")))

(define qubes-vm-compat-service-type
  (service-type
   (name 'qubes-vm-compat)
   (extensions
    (list (service-extension activation-service-type qubes-vm-compat-activation)))
   (default-value #f)
   (description "Create compatibility paths expected by Qubes VM agents.")))

(define (qubes-pam-service name)
  (let ((pam-module (lambda (name)
                      (file-append linux-pam "/lib/security/" name))))
    (pam-service
     (name name)
     (auth (list (pam-entry
                  (control "sufficient")
                  (module (pam-module "pam_rootok.so")))
                 (pam-entry
                  (control "required")
                  (module (pam-module "pam_permit.so")))))
     (account (list (pam-entry
                     (control "required")
                     (module (pam-module "pam_permit.so")))))
     (password (list (pam-entry
                      (control "required")
                      (module (pam-module "pam_permit.so")))))
     (session (list (pam-entry
                     (control "required")
                     (module (pam-module "pam_permit.so"))))))))

(define (qubes-qrexec-pam-services _)
  (list (qubes-pam-service "qrexec")
        (qubes-pam-service "qubes-gui-agent")))

(define qubes-qrexec-pam-service-type
  (service-type
   (name 'qubes-qrexec-pam)
   (extensions
    (list (service-extension pam-root-service-type
                             qubes-qrexec-pam-services)))
   (default-value #f)
   (description "Install the PAM service used by qrexec-agent user sessions.")))

(define (qubes-acpi-shutdown-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-acpi-shutdown))
    (requirement '(root-file-system))
    (documentation "Handle Qubes ACPI power-button shutdown requests.")
    (start #~(make-forkexec-constructor
              (list #$(file-append acpid "/sbin/acpid")
                    "-f" "-n" "-S" "-l" "-c" "/etc/acpi/events")
              #:log-file "/var/log/qubes-acpid.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-acpi-shutdown-service-type
  (service-type
   (name 'qubes-acpi-shutdown)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-acpi-shutdown-shepherd-service)))
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

            (define modprobe #$(file-append kmod "/bin/modprobe"))
            (define mount "/run/current-system/profile/bin/mount")
            (define mountpoint "/run/current-system/profile/bin/mountpoint")
            (define mknod* "/run/current-system/profile/bin/mknod")
            (define qrexec-client-vm* "/run/current-system/profile/bin/qrexec-client-vm")
            (define qubesdb-read* "/run/current-system/profile/bin/qubesdb-read")
            (define qubesdb-write* "/run/current-system/profile/bin/qubesdb-write")
            (define kernel-modules-device "/dev/xvdd")
            (define kernel-modules-directory "/run/qubes-kernel-modules")

            (define (warn message)
              (display message (current-error-port))
              (newline (current-error-port)))

            (define (try-run* program . args)
              (false-if-exception
               (zero? (apply system* program args))))

            (define (run* program . args)
              (unless (apply try-run* program args)
                (warn (string-append "command failed: " program))
                (exit 1)))

            (define (exec* program . args)
              (apply execl program program args))

            (define (read-file path)
              (and (file-exists? path)
                   (call-with-input-file path get-string-all)))

            (define (string-trim-newlines text)
              (let loop ((end (string-length text)))
                (if (and (> end 0)
                         (memv (string-ref text (- end 1))
                               '(#\newline #\return)))
                    (loop (- end 1))
                    (substring text 0 end))))

            (define (command-output program . args)
              (let* ((port (apply open-pipe* OPEN_READ program args))
                     (text (get-string-all port))
                     (status (close-pipe port)))
                (and (zero? status)
                     (string-trim-newlines text))))

            (define (qubesdb-read path)
              (command-output qubesdb-read* path))

            (define (qubesdb-write path value)
              (try-run* qubesdb-write* path value))

            (define (regular-or-symlink? path)
              (let ((st (false-if-exception (lstat path))))
                (and st (memq (stat:type st) '(regular symlink)))))

            (define (same-directory-entry? left right)
              (let ((left-stat (false-if-exception (stat left)))
                    (right-stat (false-if-exception (stat right))))
                (and left-stat right-stat
                     (= (stat:dev left-stat) (stat:dev right-stat))
                     (= (stat:ino left-stat) (stat:ino right-stat)))))

            (define (same-link? target link)
              (let ((st (false-if-exception (lstat link))))
                (and st
                     (eq? 'symlink (stat:type st))
                     (string=? target (readlink link)))))

            (define (replace-symlink target link)
              (mkdir-p (dirname link))
              (cond
               ((same-link? target link) #t)
               ((regular-or-symlink? link)
                (delete-file link)
                (symlink target link))
               ((not (file-exists? link))
                (symlink target link))))

            (define (group-gid name)
              (let ((entry (false-if-exception (getgr name))))
                (and entry (vector-ref entry 2))))

            (define (profile-python-paths)
              (let* ((lib "/run/current-system/profile/lib")
                     (versions
                      (or (false-if-exception
                           (scandir lib
                                    (lambda (entry)
                                      (string-prefix? "python" entry))))
                          '())))
                (filter file-exists?
                        (map (lambda (version)
                               (string-append lib "/" version
                                              "/site-packages"))
                             versions))))

            (define (prepend-environment name entries)
              (unless (null? entries)
                (let ((current (getenv name)))
                  (setenv name
                          (string-append
                           (string-join entries ":")
                           (if (and current
                                    (not (string-null? current)))
                               (string-append ":" current)
                               ""))))))

            (define (kernel-release)
              (utsname:release (uname)))

            (define (kernel-modules-release-directory)
              (string-append kernel-modules-directory "/" (kernel-release)))

            (define (kernel-modules-mounted?)
              (try-run* mountpoint "-q" kernel-modules-directory))

            (define (kernel-modules-available?)
              (file-exists? (kernel-modules-release-directory)))

            (define (wait-for-path path attempts)
              (let loop ((attempt 0))
                (cond
                 ((file-exists? path) #t)
                 ((< attempt attempts)
                  (usleep 100000)
                  (loop (+ attempt 1)))
                 (else #f))))

            (define (kernel-modules-setup attempts)
              (mkdir-p kernel-modules-directory)
              (cond
               ((kernel-modules-available?) #t)
               ((wait-for-path kernel-modules-device attempts)
                (unless (kernel-modules-mounted?)
                  (unless (try-run* mount "-o" "ro"
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
               (else
                (warn (string-append
                       "Qubes dom0 kernel modules device is not present: "
                       kernel-modules-device))
                #f)))

            (define (runtime-setup)
              (setenv "PATH"
                      (string-append
                       "/run/setuid-programs:"
                       "/run/current-system/profile/bin:"
                       "/run/current-system/profile/sbin"
                       (let ((path (getenv "PATH")))
                         (if path (string-append ":" path) ""))))
              (setenv "LINUX_MODULE_DIRECTORY"
                      kernel-modules-directory)
              (for-each
               (match-lambda
                 ((name . value)
                  (setenv name value)))
               '(("SSL_CERT_DIR" . "/etc/ssl/certs")
                 ("SSL_CERT_FILE" . "/etc/ssl/certs/ca-certificates.crt")
                 ("GIT_SSL_CAINFO" . "/etc/ssl/certs/ca-certificates.crt")
                 ("CURL_CA_BUNDLE" . "/etc/ssl/certs/ca-certificates.crt")))
              (let ((python-paths (profile-python-paths)))
                (prepend-environment "PYTHONPATH" python-paths)
                (prepend-environment "GUIX_PYTHONPATH" python-paths))
              (setenv "QREXEC_SERVICE_PATH"
                      (string-append
                       "/run/qubes-rpc:/usr/local/etc/qubes-rpc:/etc/qubes-rpc:"
                       "/run/current-system/profile/etc/qubes-rpc"))
              (setenv "QUBES_RPC_CONFIG_PATH"
                      (string-append
                       "/run/qubes/rpc-config:/usr/local/etc/qubes/rpc-config:"
                       "/etc/qubes/rpc-config:"
                       "/run/current-system/profile/etc/qubes/rpc-config"))
              (mkdir-p "/run/qubes")
              (mkdir-p "/run/qubes-service")
              (mkdir-p "/var/run")
              (mkdir-p "/var/log/qubes")
              (mkdir-p "/usr/local")
              (let ((gid (group-gid "qubes")))
                (when gid
                  (false-if-exception (chown "/run/qubes" -1 gid))))
              (chmod "/run/qubes" #o775)
              (unless (same-directory-entry? "/var/run" "/run")
                (replace-symlink "/run/qubes" "/var/run/qubes")
                (replace-symlink "/run/qubes-service" "/var/run/qubes-service")
                (replace-symlink "/run/qubes-service-environment"
                                 "/var/run/qubes-service-environment")))

            (define (misc-minor names)
              (let ((text (read-file "/proc/misc")))
                (and text
                     (any (lambda (line)
                            (let ((fields (string-tokenize line)))
                              (and (= (length fields) 2)
                                   (member (cadr fields) names)
                                   (car fields))))
                          (string-split text #\newline)))))

            (define (ensure-xen-node node names)
              (let ((path (string-append "/dev/xen/" node))
                    (minor (misc-minor names)))
                (when (and minor (not (file-exists? path)))
                  (try-run* mknod* path "c" "10" minor))))

            (define (xen-device-setup)
              (mkdir-p "/dev/xen")
              (mkdir-p "/proc/xen")
              (for-each (lambda (module)
                          (try-run* modprobe module))
                        '("xenfs" "xen_evtchn" "xen_gntalloc"
                          "xen_gntdev" "xen_privcmd"))
              (unless (try-run* mountpoint "-q" "/proc/xen")
                (try-run* mount "-t" "xenfs" "xenfs" "/proc/xen"))
              (for-each (lambda (spec)
                          (ensure-xen-node (car spec) (cdr spec)))
                        '(("xenbus" "xen/xenbus" "xenbus")
                          ("hypercall" "xen/hypercall" "hypercall")
                          ("privcmd" "xen/privcmd" "privcmd")
                          ("evtchn" "xen/evtchn" "evtchn")
                          ("gntdev" "xen/gntdev" "gntdev")
                          ("gntalloc" "xen/gntalloc" "gntalloc")))
              (when (and (not (file-exists? "/dev/xen/xenbus"))
                         (file-exists? "/proc/xen/xenbus"))
                (false-if-exception
                 (symlink "/proc/xen/xenbus" "/dev/xen/xenbus")))
              (let ((gid (group-gid "qubes")))
                (for-each (lambda (entry)
                            (let ((path (string-append "/dev/xen/" entry)))
                              (when gid
                                (false-if-exception (chown path -1 gid)))
                              (false-if-exception (chmod path #o660))))
                          (or (false-if-exception
                               (scandir "/dev/xen"
                                        (lambda (entry)
                                          (not (member entry '("." ".."))))))
                              '())))
              (let wait ((attempt 0))
                (when (and (< attempt 50)
                           (any (lambda (path)
                                  (not (file-exists? path)))
                                '("/dev/xen/xenbus" "/dev/xen/evtchn"
                                  "/dev/xen/gntalloc" "/dev/xen/gntdev"
                                  "/dev/xen/privcmd")))
                  (usleep 100000)
                  (wait (+ attempt 1)))))

            (define (prepare-service-runtime)
              (runtime-setup)
              (kernel-modules-setup 0)
              (xen-device-setup))

            (define (service-enabled? name)
              (file-exists? (string-append "/run/qubes-service/" name)))

            (define (wait-for-service-environment attempts)
              (let loop ((attempt attempts))
                (cond
                 ((file-exists? "/run/qubes-service-environment") #t)
                 ((zero? attempt) #f)
                 (else
                  (usleep 100000)
                  (loop (- attempt 1))))))

            body ...))))))

(define qubes-kvm-udev-rule
  (udev-rule "90-kvm.rules"
             "KERNEL==\"kvm\", GROUP=\"kvm\", MODE=\"0660\"\n"))

(define (qubes-udev-configurations-union subdirectory packages)
  (define build
    (with-imported-modules '((guix build union)
                             (guix build utils))
      #~(begin
          (use-modules (guix build union)
                       (guix build utils)
                       (srfi srfi-1))

          (define standard-locations
            '(#$(string-append "/lib/udev/" subdirectory)
              #$(string-append "/libexec/udev/" subdirectory)))

          (define (configuration-sub-directory directory)
            (find directory-exists?
                  (map (lambda (suffix)
                         (string-append directory suffix))
                       standard-locations)))

          (union-build #$output
                       (filter-map configuration-sub-directory '#$packages)))))

  (computed-file (string-append "qubes-udev-" subdirectory) build))

(define (qubes-udev-rules-union packages)
  (qubes-udev-configurations-union "rules.d" packages))

(define (qubes-udev-hardware-union packages)
  (qubes-udev-configurations-union "hwdb.d" packages))

(define qubes-udev.conf
  (computed-file "qubes-udev.conf"
                 #~(call-with-output-file #$output
                     (lambda (port)
                       (format port "udev_rules=\"/etc/udev/rules.d\"~%")))))

(define (qubes-udev-etc config)
  (let* ((udev (udev-configuration-udev config))
         (rules (udev-configuration-rules config))
         (hardware (udev-configuration-hardware config))
         (hardware-union (qubes-udev-hardware-union (cons* udev hardware)))
         (hwdb.bin
          (computed-file
           "qubes-udev-hwdb.bin"
           (with-imported-modules '((guix build utils))
             #~(begin
                 (use-modules (guix build utils))
                 (setenv "UDEV_HWDB_PATH" #$hardware-union)
                 (invoke #+(file-append udev "/bin/udevadm")
                         "hwdb" "--update" "-o" #$output))))))
    `(("udev"
       ,(file-union "qubes-udev"
                    `(("udev.conf" ,qubes-udev.conf)
                      ("rules.d"
                       ,(qubes-udev-rules-union
                         (cons* udev qubes-kvm-udev-rule rules)))
                      ("hwdb.bin" ,hwdb.bin)))))))

(define (qubes-udev-coldplug-program config)
  (let ((udev (udev-configuration-udev config)))
    (program-file
     "qubes-udev-coldplug"
     (with-imported-modules '()
       #~(begin
           (define udevadm #$(file-append udev "/bin/udevadm"))

           (define (wait-for-udev-control attempts)
             (cond
              ((file-exists? "/run/udev/control") #t)
              ((zero? attempts)
               (format #t "udevd control socket not ready; continuing Qubes boot~%")
               #f)
              (else
               (usleep 500000)
               (wait-for-udev-control (- attempts 1)))))

           (define (reap-child pid)
             (false-if-exception (waitpid pid)))

           (define (terminate-child pid)
             (false-if-exception (kill pid SIGTERM))
             (usleep 200000)
             (false-if-exception (kill pid SIGKILL))
             (reap-child pid))

           (define (run-udevadm/bounded seconds . args)
             (let ((pid (primitive-fork)))
               (if (= pid 0)
                   (begin
                     (apply execl udevadm udevadm args)
                     (exit 127))
                   (let wait ((remaining (* seconds 10)))
                     (let ((result (false-if-exception
                                    (waitpid pid WNOHANG))))
                       (cond
                        ((and result (= (car result) pid))
                         (let ((status (cdr result)))
                           (and (not (status:term-sig status))
                                (let ((exit-code (status:exit-val status)))
                                  (and exit-code (zero? exit-code))))))
                        ((zero? remaining)
                         (format #t "udevadm command timed out: ~s~%" args)
                         (terminate-child pid)
                         #f)
                        (else
                         (usleep 100000)
                         (wait (- remaining 1)))))))))

           (when (wait-for-udev-control 20)
             (run-udevadm/bounded
              5 "trigger" "--action=add" "--type=devices")
             (run-udevadm/bounded
              5 "trigger" "--action=add" "--type=subsystems")
             (run-udevadm/bounded 5 "settle" "--timeout=5")))))))

(define (qubes-udev-shepherd-service config)
  (let ((udev (udev-configuration-udev config)))
    (list
     (shepherd-service
      (provision '(udev))
      (requirement '(root-file-system sysctl qubes-kernel-modules))
      (documentation "Run eudev without making Qubes boot wait for global settle.")
      (start
       (with-imported-modules (source-module-closure
                               '((gnu build linux-boot)))
         #~(lambda ()
             (define udevd #$(file-append udev "/sbin/udevd"))

             (setenv "LINUX_MODULE_DIRECTORY"
                     "/run/qubes-kernel-modules")

             (let* ((kernel-release (utsname:release (uname)))
                    (linux-module-directory
                     (getenv "LINUX_MODULE_DIRECTORY"))
                    (directory
                     (string-append linux-module-directory "/"
                                    kernel-release))
                    (old-umask (umask #o022)))
               (when (file-exists? directory)
                 (make-static-device-nodes directory))
               (umask old-umask))

             (fork+exec-command
              (list udevd
                    #$@(if (udev-configuration-debug? config)
                           '("--debug")
                           '()))
              #:environment-variables
              (cons*
               (string-append "LINUX_MODULE_DIRECTORY="
                              (getenv "LINUX_MODULE_DIRECTORY"))
               (default-environment-variables))))))
      (stop #~(make-kill-destructor))
      (respawn? #f)
      (modules `((gnu build linux-boot)
                 ,@%default-modules)))
     (shepherd-service
      (provision '(qubes-udev-coldplug))
      (requirement '(udev))
      (documentation "Trigger Qubes udev coldplug without blocking udev readiness.")
      (start #~(make-forkexec-constructor
                (list #$(qubes-udev-coldplug-program config))
                #:log-file "/var/log/qubes-udev-coldplug.log"))
      (stop #~(make-kill-destructor))
      (respawn? #f)))))

(define qubes-udev-service-type
    (service-type
     (name 'udev)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-udev-shepherd-service)
          (service-extension etc-service-type qubes-udev-etc)))
   (compose concatenate)
   (extend (lambda (config rules)
             (udev-configuration
              (inherit config)
              (rules (append (udev-configuration-rules config)
                             rules)))))
   (default-value (udev-configuration))
   (description "Run eudev with Qubes boot readiness semantics.")))

(define (run-one-shot-gexp program log-file best-effort?)
  #~(lambda _
      (define (status-success? status)
        (and (not (status:term-sig status))
             (let ((exit-code (status:exit-val status)))
               (and exit-code (zero? exit-code)))))

      (define (run/logged)
        (let ((pid (primitive-fork)))
          (if (= pid 0)
              (begin
                (let ((port (open-file #$log-file "a")))
                  (dup2 (fileno port) 1)
                  (dup2 (fileno port) 2)
                  (close-port port))
                (execl #$program #$program))
              (cdr (waitpid pid)))))

      (let ((status (run/logged)))
        (if #$best-effort?
            #t
            (status-success? status)))))

(define* (one-shot-service name requirements program log-file
                           #:key (best-effort? #f))
  (shepherd-service
   (provision (list name))
   (requirement requirements)
   (one-shot? #t)
   (respawn? #f)
   (documentation (string-append "Run " (symbol->string name) " once."))
   (start (run-one-shot-gexp program log-file best-effort?))
   (stop #~(const #f))))

(define (qubes-kernel-modules-program)
  (qubes-vm-service-program
   "qubes-kernel-modules"
   (runtime-setup)
   (kernel-modules-setup 300)))

(define (qubes-kernel-modules-shepherd-service _)
  (list
   (one-shot-service
    'qubes-kernel-modules
    '(root-file-system)
    (qubes-kernel-modules-program)
    "/var/log/qubes-kernel-modules.log")))

(define qubes-kernel-modules-service-type
  (service-type
   (name 'qubes-kernel-modules)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-kernel-modules-shepherd-service)))
   (default-value #f)
   (description "Mount the Qubes dom0-provided kernel modules image.")))

(define (qubes-sysctl-settings-file settings)
  (plain-file "qubes-sysctl-settings.scm"
              (object->string settings)))

(define (qubes-sysctl-program settings)
  (let ((settings-file (qubes-sysctl-settings-file settings)))
    (qubes-vm-service-program
     "qubes-sysctl"
     (define sysctl-settings
       (call-with-input-file #$settings-file read))

     (define (sysctl-key->path key)
       (string-append
        "/proc/sys/"
        (list->string
         (map (lambda (char)
                (if (char=? char #\.) #\/ char))
              (string->list key)))))

     (define (write-sysctl setting)
       (let* ((key (car setting))
              (value (cdr setting))
              (path (sysctl-key->path key)))
         (unless (file-exists? path)
           (warn (string-append "sysctl path is missing: " path))
           (exit 1))
         (catch #t
           (lambda ()
             (call-with-output-file path
               (lambda (port)
                 (display value port)
                 (newline port))))
           (lambda (key . args)
             (warn (string-append "failed to write sysctl path: " path))
             (exit 1)))))

     (for-each write-sysctl sysctl-settings))))

(define (qubes-sysctl-shepherd-service config)
  (list
   (one-shot-service
    'sysctl
    '(root-file-system)
    (qubes-sysctl-program (sysctl-configuration-settings config))
    "/var/log/sysctl.log")))

(define qubes-sysctl-service-type
  (service-type
   (name 'sysctl)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-sysctl-shepherd-service)))
   (compose concatenate)
   (extend (lambda (config settings)
             (sysctl-configuration
              (inherit config)
              (settings (append (sysctl-configuration-settings config)
                                settings)))))
   (default-value (sysctl-configuration))
   (description "Apply kernel sysctl settings with a Qubes-local Scheme helper.")))

(define (qubes-loopback-program)
  (qubes-vm-service-program
   "qubes-loopback"
   (define ip "/run/current-system/profile/sbin/ip")

   (let wait ((attempt 0))
     (cond
      ((file-exists? "/sys/class/net/lo")
       (run* ip "link" "set" "lo" "up")
       (exit 0))
      ((< attempt 50)
       (usleep 100000)
       (wait (+ attempt 1)))
      (else
       (warn "loopback network device did not appear")
       (exit 1))))))

(define (qubes-loopback-shepherd-service _)
  (list
   (one-shot-service
    'qubes-loopback
    '(root-file-system)
    (qubes-loopback-program)
    "/var/log/qubes-loopback.log")))

(define qubes-loopback-service-type
  (service-type
   (name 'qubes-loopback)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-loopback-shepherd-service)))
   (default-value #f)
   (description "Bring up the loopback interface without generic static networking.")))

(define (qubes-network-sysctl-program)
  (qubes-vm-service-program
   "qubes-network-sysctl"
   (define network-sysctl-settings '#$%qubes-network-sysctl-settings)

   (define (interface-names family)
     (let ((directory (string-append "/proc/sys/net/" family "/conf")))
       (or (false-if-exception
            (scandir directory
                     (lambda (entry)
                       (not (member entry '("." ".."))))))
           '())))

   (define (write-sysctl path value)
     (when (file-exists? path)
       (false-if-exception
        (call-with-output-file path
          (lambda (port)
            (display value port))))))

   (define (apply-setting setting)
     (let ((family (car setting))
           (name (cadr setting))
           (value (cddr setting)))
       (for-each
        (lambda (interface)
          (write-sysctl
           (string-append "/proc/sys/net/" family "/conf/"
                          interface "/" name)
           value))
        (interface-names family))))

   (for-each apply-setting network-sysctl-settings)))

(define (qubes-network-sysctl-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network-sysctl
    '(root-file-system qubes-loopback)
    (qubes-network-sysctl-program)
    "/var/log/qubes-network-sysctl.log")))

(define qubes-network-sysctl-service-type
  (service-type
   (name 'qubes-network-sysctl)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-sysctl-shepherd-service)))
   (default-value #f)
   (description "Apply Qubes network sysctl settings without early wildcard sysctl.")))

(define (qubes-db-program)
  (qubes-vm-service-program
   "qubes-db"
   (prepare-service-runtime)
   (exec* "/run/current-system/profile/bin/qubesdb-daemon" "0")))

(define (qubes-db-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-db))
    (requirement '(root-file-system qubes-kernel-modules))
    (documentation "Run the QubesDB VM daemon.")
    (start #~(make-forkexec-constructor
              (list #$(qubes-db-program))
              #:log-file "/var/log/qubes-db.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-db-service-type
  (service-type
   (name 'qubes-db)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-db-shepherd-service)))
   (default-value #f)
   (description "Run QubesDB inside a Qubes VM.")))

(define (qubes-early-vm-config-program)
  (qubes-vm-service-program
   "qubes-early-vm-config"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/init/qubes-early-vm-config.sh")))

(define (qubes-early-vm-config-shepherd-service _)
  (list
   (one-shot-service
    'qubes-early-vm-config
    '(qubes-db)
    (qubes-early-vm-config-program)
    "/var/log/qubes-early-vm-config.log")))

(define qubes-early-vm-config-service-type
  (service-type
   (name 'qubes-early-vm-config)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-early-vm-config-shepherd-service)))
   (default-value #f)
   (description "Apply early Qubes VM configuration such as hostname and timezone.")))

(define (qubes-sysinit-program)
  (qubes-vm-service-program
   "qubes-sysinit"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/init/qubes-sysinit.sh")))

(define (qubes-sysinit-shepherd-service _)
  (list
   (one-shot-service
    'qubes-sysinit
    '(qubes-early-vm-config)
    (qubes-sysinit-program)
    "/var/log/qubes-sysinit.log")))

(define qubes-sysinit-service-type
  (service-type
   (name 'qubes-sysinit)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-sysinit-shepherd-service)))
   (default-value #f)
   (description "Run Qubes VM sysinit.")))

(define-record-type* <qubes-meminfo-writer-configuration>
  qubes-meminfo-writer-configuration make-qubes-meminfo-writer-configuration
  qubes-meminfo-writer-configuration?
  (package qubes-meminfo-writer-configuration-package
           (default qubes-vm-utils))
  (threshold qubes-meminfo-writer-configuration-threshold
             (default 30000))
  (delay qubes-meminfo-writer-configuration-delay
         (default 100000))
  (pid-file qubes-meminfo-writer-configuration-pid-file
            (default "/var/run/meminfo-writer.pid")))

(define (qubes-meminfo-writer-program config)
  (let ((meminfo-writer
         (file-append (qubes-meminfo-writer-configuration-package config)
                      "/bin/meminfo-writer"))
        (threshold
         (number->string
          (qubes-meminfo-writer-configuration-threshold config)))
        (delay
         (number->string
          (qubes-meminfo-writer-configuration-delay config)))
        (pid-file
         (qubes-meminfo-writer-configuration-pid-file config)))
    (qubes-vm-service-program
     "qubes-meminfo-writer"
     (define pidfile #$pid-file)

     (define (read-pid path)
       (and (file-exists? path)
            (let ((text (call-with-input-file path get-string-all)))
              (string->number (string-trim-both text)))))

     (prepare-service-runtime)

     (unless (service-enabled? "meminfo-writer")
       (display "meminfo-writer service flag not present; exiting\n")
       (exit 0))

     (when (file-exists? pidfile)
       (delete-file pidfile))
     (unless (zero? (system* #$meminfo-writer
                             #$threshold #$delay pidfile))
       (warn "meminfo-writer failed to start")
       (exit 1))

     (let wait-for-pid ((attempt 0))
       (let ((pid (read-pid pidfile)))
         (cond
          ((and pid (> pid 1))
           (sigaction SIGTERM
             (lambda _
               (false-if-exception (kill pid SIGTERM))
               (false-if-exception (delete-file pidfile))
               (exit 0)))
           (sigaction SIGINT
             (lambda _
               (false-if-exception (kill pid SIGTERM))
               (false-if-exception (delete-file pidfile))
               (exit 0)))
           (let loop ()
             (if (false-if-exception (kill pid 0))
                 (begin
                   (sleep 60)
                   (loop))
                 (begin
                   (false-if-exception (delete-file pidfile))
                   (exit 1)))))
          ((< attempt 50)
           (usleep 100000)
           (wait-for-pid (+ attempt 1)))
          (else
           (warn "meminfo-writer did not create a valid pid file")
           (exit 1))))))))

(define (qubes-meminfo-writer-shepherd-service config)
  (list
   (shepherd-service
    (provision '(qubes-meminfo-writer))
    (requirement '(qubes-sysinit))
    (documentation "Run the Qubes memory information reporter.")
    (respawn? #f)
    (start #~(make-forkexec-constructor
              (list #$(qubes-meminfo-writer-program config))
              #:log-file "/var/log/qubes-meminfo-writer.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-meminfo-writer-service-type
  (service-type
   (name 'qubes-meminfo-writer)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-meminfo-writer-shepherd-service)))
   (default-value (qubes-meminfo-writer-configuration))
   (description "Run Qubes memory usage reporting for dom0 ballooning.")))

(define (qubes-network-uplink-program)
  (qubes-vm-service-program
   "qubes-network-uplink"
   (define ip "/run/current-system/profile/sbin/ip")
   (define network-sysctl-settings '#$%qubes-network-sysctl-settings)

   (define (iface-mac iface)
     (and iface
          (read-file (string-append "/sys/class/net/" iface "/address"))))

   (define (iface-for-mac mac)
     (and mac
          (any (lambda (iface)
                 (let ((address (iface-mac iface)))
                   (and address
                        (string-ci=? (string-trim-newlines address) mac)
                        iface)))
               (or (false-if-exception
                    (scandir "/sys/class/net"
                             (lambda (entry)
                               (not (member entry '("." ".."))))))
                   '()))))

   (define (qubes-managed-iface)
     (let ((mac (qubesdb-read "/qubes-mac")))
       (and mac
            (begin
              (unless (file-exists? "/sys/module/xen_netfront")
                (try-run* modprobe "xen-netfront"))
              (or (iface-for-mac mac)
                  (and (file-exists? "/sys/class/net/eth0")
                       "eth0"))))))

     (define (apply-interface-sysctl iface)
       (for-each
        (lambda (setting)
          (let ((family (car setting))
                (name (cadr setting))
                (value (cddr setting)))
            (write-sysctl
             (string-append "/proc/sys/net/" family "/conf/" iface "/" name)
             value)))
        network-sysctl-settings))

   (define (write-sysctl path value)
     (when (file-exists? path)
       (false-if-exception
        (call-with-output-file path
          (lambda (port)
            (display value port))))))

     (prepare-service-runtime)
     (try-run* ip "link" "set" "lo" "up")
     (let wait ((attempt 0))
       (let ((iface (qubes-managed-iface)))
         (cond
          (iface
           (apply-interface-sysctl iface)
           (exec* "/usr/lib/qubes/setup-ip" "add" iface))
          ((< attempt 300)
           (usleep 100000)
           (wait (+ attempt 1)))
          (else
           (display "No Qubes managed network interface found\n")
           (exit 0)))))))

(define (qubes-network-uplink-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network-uplink
    '(qubes-sysinit sysctl qubes-network-sysctl)
    (qubes-network-uplink-program)
    "/var/log/qubes-network-uplink.log")))

(define qubes-network-uplink-service-type
  (service-type
   (name 'qubes-network-uplink)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-uplink-shepherd-service)))
   (default-value #f)
   (description "Configure the Qubes-provided VM network uplink.")))

(define (qubes-network-program)
  (qubes-vm-service-program
   "qubes-network"
   (define dnat-helper "/usr/lib/qubes/qubes-setup-dnat-to-ns")

   (define (write-required-file path value)
     (unless (file-exists? path)
       (warn (string-append "required network control file is missing: " path))
       (exit 1))
     (catch #t
       (lambda ()
         (call-with-output-file path
           (lambda (port)
             (display value port)
             (newline port))))
       (lambda (key . args)
         (warn (string-append "failed to write network control file: " path))
         (exit 1))))

   (define (write-optional-file path value)
     (when (file-exists? path)
       (false-if-exception
        (call-with-output-file path
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
       (warn "could not load Xen network backend module")
       (exit 1)))

   (prepare-service-runtime)
   (wait-for-service-environment 600)
   (cond
    ((not (service-enabled? "qubes-network"))
     (display "qubes-network service flag not present; network backend inactive\n")
     (exit 0))
    ((string-null? (or (qubesdb-read "/qubes-netvm-network") ""))
     (display "No Qubes downstream network configured for this VM\n")
     (exit 0))
    (else
     (load-network-backend)
     (run* dnat-helper)
     (write-required-file "/proc/sys/net/ipv4/ip_forward" "1")
     (unless (string-null? (or (qubesdb-read "/qubes-netvm-gateway6") ""))
       (write-optional-file "/proc/sys/net/ipv6/conf/all/forwarding" "1"))))))

(define (qubes-network-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network
    '(qubes-sysinit sysctl qubes-network-sysctl qubes-network-uplink)
    (qubes-network-program)
    "/var/log/qubes-network.log")))

(define qubes-network-service-type
  (service-type
   (name 'qubes-network)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-shepherd-service)))
   (default-value #f)
   (description "Configure the Qubes network backend role for NetVMs.")))

(define (qubes-feature-advertisement-program)
  (qubes-vm-service-program
   "qubes-feature-advertisement"
   (define supported-services
     '("updates-proxy-setup" "qubes-network"))

   (define (request-feature name value)
     (unless (qubesdb-write (string-append "/features-request/" name) value)
       (warn (string-append "failed to write Qubes feature request: " name))
       (exit 1)))

   (prepare-service-runtime)
   (for-each
    (lambda (service)
      (request-feature (string-append "supported-service." service) "1"))
    supported-services)
   (unless (try-run* qrexec-client-vm* "dom0" "qubes.FeaturesRequest")
     (warn "failed to commit Qubes feature requests")
     (exit 1))))

(define (qubes-feature-advertisement-shepherd-service _)
  (list
   (one-shot-service
    'qubes-feature-advertisement
    '(qubes-qrexec-agent)
    (qubes-feature-advertisement-program)
    "/var/log/qubes-feature-advertisement.log")))

(define qubes-feature-advertisement-service-type
  (service-type
   (name 'qubes-feature-advertisement)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-feature-advertisement-shepherd-service)))
   (default-value #f)
   (description "Advertise Qubes services implemented by native Guix services.")))

(define (qubes-updates-proxy-forwarder-program)
  (qubes-vm-service-program
   "qubes-updates-proxy-forwarder"
   (runtime-setup)
   (wait-for-service-environment 600)
   (cond
    ((not (service-enabled? "updates-proxy-setup"))
     (display "updates-proxy-setup service flag not present; forwarder inactive\n")
     (exit 0))
    ((service-enabled? "qubes-updates-proxy")
     (display "qubes-updates-proxy enabled locally; not forwarding to avoid loops\n")
     (exit 0))
    (else
     (exec* "/run/current-system/profile/bin/socat"
            "TCP-LISTEN:8082,bind=127.0.0.1,reuseaddr,fork"
            "EXEC:/usr/lib/qubes/guix-updates-proxy-forwarder")))))

(define (qubes-updates-proxy-forwarder-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-updates-proxy-forwarder))
    (requirement '(qubes-sysinit qubes-loopback))
    (documentation "Forward 127.0.0.1:8082 to Qubes UpdatesProxy RPC.")
    (respawn? #f)
    (start #~(make-forkexec-constructor
              (list #$(qubes-updates-proxy-forwarder-program))
              #:log-file "/var/log/qubes-updates-proxy-forwarder.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-updates-proxy-forwarder-service-type
  (service-type
   (name 'qubes-updates-proxy-forwarder)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-updates-proxy-forwarder-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes updates proxy forwarder socket service.")))

(define (qubes-mount-dirs-program)
  (qubes-vm-service-program
   "qubes-mount-dirs"
   (define findmnt "/run/current-system/profile/bin/findmnt")
   (define mount-dirs "/usr/lib/qubes/init/mount-dirs.sh")
   (define fstab-entry
     "/dev/xvdb /rw auto noauto,defaults,discard,nosuid,nodev 1 2\n")

   (define (mounted? path)
     (try-run* findmnt "-rn" path))

   (define (fstab-has-rw?)
     (let ((text (read-file "/etc/fstab")))
       (and text
            (any (lambda (line)
                   (let ((fields (string-tokenize line)))
                     (and (>= (length fields) 2)
                          (not (string-prefix? "#" (car fields)))
                          (string=? (cadr fields) "/rw"))))
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
     (when (string=? (or (qubesdb-read "/qubes-vm-persistence") "")
                     "rw-only")
       (let loop ((attempt 0))
         (cond
          ((file-exists? "/dev/xvdb") #t)
          ((< attempt 300)
           (usleep 100000)
           (loop (+ attempt 1)))
          (else
           (warn "Qubes private-volume device /dev/xvdb did not appear")
           (exit 1))))))

   (prepare-service-runtime)
   (wait-for-rw-device)
   (repair-fstab-entry)
   (when (and (mounted? "/rw")
              (mounted? "/home")
              (mounted? "/usr/local"))
     (display "Qubes private directories already mounted\n")
     (exit 0))
   (run* mount-dirs)
   (repair-fstab-entry)))

(define (qubes-mount-dirs-shepherd-service _)
  (list
   (one-shot-service
    'qubes-mount-dirs
    '(qubes-sysinit)
    (qubes-mount-dirs-program)
    "/var/log/qubes-mount-dirs.log")))

(define qubes-mount-dirs-service-type
  (service-type
   (name 'qubes-mount-dirs)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-mount-dirs-shepherd-service)))
   (default-value #f)
   (description "Mount Qubes persistent directories such as /rw, /home, and /usr/local.")))

(define (qubes-bind-dirs-program)
  (qubes-vm-service-program
   "qubes-bind-dirs"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/init/bind-dirs.sh")))

(define (qubes-bind-dirs-shepherd-service _)
  (list
   (one-shot-service
    'qubes-bind-dirs
    '(qubes-mount-dirs)
    (qubes-bind-dirs-program)
    "/var/log/qubes-bind-dirs.log")))

(define qubes-bind-dirs-service-type
  (service-type
   (name 'qubes-bind-dirs)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-bind-dirs-shepherd-service)))
   (default-value #f)
   (description "Apply Qubes bind-dirs configuration.")))

(define (qubes-misc-post-program)
  (qubes-vm-service-program
   "qubes-misc-post"
   (prepare-service-runtime)
   (let ((status (system* "/usr/lib/qubes/init/misc-post.sh")))
     (unless (zero? status)
       (warn (string-append "qubes-misc-post exited with status "
                            (number->string status)))))
   (exit 0)))

(define (qubes-misc-post-shepherd-service _)
  (list
   (one-shot-service
    'qubes-misc-post
    '(qubes-bind-dirs)
    (qubes-misc-post-program)
    "/var/log/qubes-misc-post.log"
    #:best-effort? #t)))

(define qubes-misc-post-service-type
  (service-type
   (name 'qubes-misc-post)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-misc-post-shepherd-service)))
   (default-value #f)
   (description "Run late Qubes VM setup.")))

(define (qubes-qrexec-agent-program)
  (qubes-vm-service-program
   "qubes-qrexec-agent"
   (prepare-service-runtime)
   (exec* "/usr/lib/qubes/qrexec-agent")))

(define (qubes-qrexec-agent-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-qrexec-agent))
    (requirement '(qubes-bind-dirs))
    (documentation "Run the Qubes qrexec agent.")
    (start #~(make-forkexec-constructor
              (list #$(qubes-qrexec-agent-program))
              #:log-file "/var/log/qubes-qrexec-agent.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-qrexec-agent-service-type
  (service-type
   (name 'qubes-qrexec-agent)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-qrexec-agent-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes qrexec agent.")))

(define (qubes-gui-agent-program)
  (qubes-vm-service-program
   "qubes-gui-agent"
   (define (read-service-environment)
     (let ((text (read-file "/run/qubes-service-environment")))
       (if text
           (filter-map
            (lambda (line)
              (let ((index (string-index line #\=)))
                (and index
                     (cons (substring line 0 index)
                           (substring line (+ index 1))))))
            (string-split text #\newline))
           '())))

   (define (environment-ref entries key default)
     (match (assoc key entries)
       ((_ . value) value)
       (_ default)))

   (prepare-service-runtime)
   (unless (string=? (or (command-output qubesdb-read*
                                         "/qubes-gui-enabled")
                         "True")
                     "True")
     (exit 0))
   (setenv "DISPLAY" ":0")
   (run* "/usr/lib/qubes/qubes-gui-agent-pre.sh")
   (let* ((entries (read-service-environment))
          (display (environment-ref entries "DISPLAY" ":0"))
          (gui-opts (environment-ref entries "GUI_OPTS" "")))
     (setenv "DISPLAY" display)
     (setenv "GUI_OPTS" gui-opts)
     (let ((qubes-gui "/run/current-system/profile/bin/qubes-gui"))
       (apply execl qubes-gui qubes-gui (string-tokenize gui-opts))))))

(define (qubes-gui-agent-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-gui-agent))
    (requirement '(user-processes qubes-bind-dirs qubes-qrexec-agent))
    (documentation "Run the Qubes GUI agent.")
    (start #~(make-forkexec-constructor
              (list #$(qubes-gui-agent-program))
              #:log-file "/var/log/qubes-gui-agent.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-gui-agent-service-type
  (service-type
   (name 'qubes-gui-agent)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-gui-agent-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes GUI agent.")))

(define %qubes-vm-headless-services
  (list (service qubes-vm-compat-service-type)
        (service qubes-kernel-modules-service-type)
        (service qubes-udev-service-type
                 (udev-configuration
                  (rules '())))
        (service qubes-loopback-service-type)
        (service login-service-type)
        (service agetty-service-type
                 (agetty-configuration
                  (tty "hvc0")
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
  '(agetty
    console-fonts
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
           (sysctl-configuration
            (settings (append %qubes-kernel-sysctl-settings
                              %default-sysctl-settings)))))

(define %qubes-minimal-base-services
  (filter (lambda (service)
            (not (memq (service-type-name (service-kind service))
                       %qubes-omitted-base-service-types)))
          %qubes-base-services))
