;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (qubes services qubes-vm)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system pam)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (qubes packages qubes-vm)
  #:export (qubes-vm-compat-service-type
            qubes-acpi-shutdown-service-type
            qubes-db-service-type
            qubes-sysinit-service-type
            qubes-meminfo-writer-configuration
            qubes-meminfo-writer-configuration?
            qubes-meminfo-writer-service-type
            qubes-network-uplink-service-type
            qubes-updates-proxy-forwarder-service-type
            qubes-guix-update-proxy-service-type
            qubes-mount-dirs-service-type
            qubes-bind-dirs-service-type
            qubes-misc-post-service-type
            qubes-qrexec-pam-service-type
            qubes-qrexec-agent-service-type
            qubes-qrexec-fork-server-service-type
            qubes-gui-agent-service-type
            %qubes-vm-headless-services
            %qubes-vm-gui-services))

(define (qubes-vm-compat-activation _)
  #~(begin
      (use-modules (guix build utils)
                   (ice-9 ftw))

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

      ;; The upstream Qubes VM tools use fixed paths. Keep those paths as
      ;; compatibility links into the current Guix system profile.
      (mkdir-p "/usr/lib")
      (mkdir-p "/etc")
      (mkdir-p "/run/qubes")
      (mkdir-p "/run/qubes-service")
      (mkdir-p "/var/log/qubes")
      (mkdir-p "/var/lib/qubes")
      (mkdir-p "/rw")
      (mkdir-p "/usr/local")
      ;; Guix exposes /etc/fstab as an immutable store symlink.  Qubes'
      ;; mount-dirs script expects to add the private /rw volume there.
      (materialize-symlinked-file "/etc/fstab")
      (write-text-file "/etc/acpi/events/qubes-power-button"
                       "event=button/power.*\naction=/etc/acpi/actions/qubes-poweroff\n")
      (write-text-file "/etc/acpi/actions/qubes-poweroff"
                       "#!/run/current-system/profile/bin/sh\nexec /run/current-system/profile/sbin/halt\n")
      (chmod "/etc/acpi/actions/qubes-poweroff" #o555)
      (replace-symlink "/run/current-system/profile/bin" "/usr/bin")
      (replace-symlink "/run/current-system/profile/sbin" "/usr/sbin")
      (replace-symlink "/run/current-system/profile/share" "/usr/share")
      (replace-symlink "/run/current-system/profile/lib/qubes" "/usr/lib/qubes")
      (replace-symlink "/run/current-system/profile/lib/qubes-bind-dirs.d"
                       "/usr/lib/qubes-bind-dirs.d")
      (link-directory-contents "/run/current-system/profile/etc/qubes"
                               "/etc/qubes")
      (replace-symlink "/run/current-system/profile/etc/qubes-rpc"
                       "/etc/qubes-rpc")
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
         (when (symlink?* path)
           (delete-file path)))
       '("/etc/profile.d/qubes-guix-session.sh"
         "/etc/profile.d/qubes-guix-update-proxy.sh"))
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
    (requirement '(user-processes))
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

(define (one-shot-service name requirements command log-file)
  (let ((script (string-append "exec >> " log-file " 2>&1; "
                               %qubes-runtime-setup-command
                               "; " %xen-device-setup-command
                               "; " command)))
    (shepherd-service
     (provision (list name))
     (requirement requirements)
     (one-shot? #t)
     (respawn? #f)
     (documentation (string-append "Run " (symbol->string name) " once."))
     (start #~(lambda _
                (zero? (system* "/run/current-system/profile/bin/sh"
                                "-c"
                                #$script))))
     (stop #~(const #f)))))

(define (best-effort-one-shot-service name requirements command log-file)
  (let ((script (string-append "exec >> " log-file " 2>&1; "
                               %qubes-runtime-setup-command
                               "; " %xen-device-setup-command
                               "; " command)))
    (shepherd-service
     (provision (list name))
     (requirement requirements)
     (one-shot? #t)
     (respawn? #f)
     (documentation (string-append "Run " (symbol->string name)
                                   " once on a best-effort basis."))
     (start #~(lambda _
                (system* "/run/current-system/profile/bin/sh" "-c" #$script)
                #t))
     (stop #~(const #f)))))

(define %xen-device-setup-command
  (string-append
   "mkdir -p /dev/xen /proc/xen; "
   "modprobe xenfs || true; "
   "modprobe xen_evtchn || true; "
   "modprobe xen_gntalloc || true; "
   "modprobe xen_gntdev || true; "
   "modprobe xen_privcmd || true; "
   "mountpoint -q /proc/xen 2>/dev/null "
   "|| mount -t xenfs xenfs /proc/xen 2>/dev/null || true; "
   "for spec in "
   "'xenbus:xen/xenbus xenbus' "
   "'hypercall:xen/hypercall hypercall' "
   "'privcmd:xen/privcmd privcmd' "
   "'evtchn:xen/evtchn evtchn' "
   "'gntdev:xen/gntdev gntdev' "
   "'gntalloc:xen/gntalloc gntalloc'; do "
   "node=${spec%%:*}; names=${spec#*:}; minor=; "
   "for misc in $names; do "
   "minor=$(awk -v name=\"$misc\" '$2 == name { print $1; exit }' "
   "/proc/misc 2>/dev/null || true); "
   "[ -n \"$minor\" ] && break; "
   "done; "
   "if [ -n \"$minor\" ] && [ ! -e \"/dev/xen/$node\" ]; then "
   "mknod \"/dev/xen/$node\" c 10 \"$minor\" || true; "
   "fi; "
   "done; "
   "if [ ! -e /dev/xen/xenbus ] && [ -e /proc/xen/xenbus ]; then "
   "ln -s /proc/xen/xenbus /dev/xen/xenbus || true; "
   "fi; "
   "chgrp qubes /dev/xen/* 2>/dev/null || true; "
   "chmod 0660 /dev/xen/* 2>/dev/null || true; "
   "i=0; "
   "while [ $i -lt 50 ] && { "
   "[ ! -e /dev/xen/xenbus ] || "
   "[ ! -e /dev/xen/evtchn ] || "
   "[ ! -e /dev/xen/gntalloc ] || "
   "[ ! -e /dev/xen/gntdev ] || "
   "[ ! -e /dev/xen/privcmd ]; }; do "
   "i=$((i + 1)); sleep 0.1; "
   "done"))

(define %qubes-runtime-setup-command
  (string-append
   "export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}; "
   "export QREXEC_SERVICE_PATH=/run/qubes-rpc:/usr/local/etc/qubes-rpc:/etc/qubes-rpc:/run/current-system/profile/etc/qubes-rpc; "
   "export QUBES_RPC_CONFIG_PATH=/run/qubes/rpc-config:/usr/local/etc/qubes/rpc-config:/etc/qubes/rpc-config:/run/current-system/profile/etc/qubes/rpc-config; "
   "mkdir -p /run/qubes /var/run /var/log/qubes /usr/local; "
   "chgrp qubes /run/qubes 2>/dev/null || true; "
   "chmod 0775 /run/qubes 2>/dev/null || true; "
   "mkdir -p /run/qubes-service; "
   "if [ /var/run -ef /run ] 2>/dev/null; then "
   ":; "
   "else "
   "rm -rf /var/run/qubes /var/run/qubes-service; "
   "rm -f /var/run/qubes-service-environment; "
   "ln -s /run/qubes /var/run/qubes; "
   "ln -s /run/qubes-service /var/run/qubes-service; "
   "ln -sfn /run/qubes-service-environment /var/run/qubes-service-environment; "
   "fi"))

(define %qubes-rw-device-wait-command
  "persistence=$(qubesdb-read /qubes-vm-persistence 2>/dev/null || true); if [ \"$persistence\" = rw-only ]; then i=0; while [ $i -lt 300 ] && [ ! -e /dev/xvdb ]; do i=$((i + 1)); sleep 0.1; done; if [ ! -e /dev/xvdb ]; then echo 'Qubes private-volume device /dev/xvdb did not appear' >&2; exit 1; fi; fi")

(define %qubes-rw-fstab-command
  "if [ -e /dev/xvdb ] && ! grep -q ' /rw ' /etc/fstab 2>/dev/null; then printf '%s\\n' '/dev/xvdb /rw auto noauto,defaults,discard,nosuid,nodev 1 2' >> /etc/fstab; fi")

(define %qubes-private-dirs-mounted-command
  "if findmnt -rn /rw >/dev/null 2>&1 && findmnt -rn /home >/dev/null 2>&1 && findmnt -rn /usr/local >/dev/null 2>&1; then echo 'Qubes private directories already mounted'; exit 0; fi")

(define %qubes-user-runtime-dir-command
  (string-append
   "user=$(qubesdb-read /default-user 2>/dev/null || echo user); "
   "uid=$(id -u \"$user\"); gid=$(id -g \"$user\"); "
   "install -d -m 0700 -o \"$uid\" -g \"$gid\" \"/run/user/$uid\""))

(define (qubes-db-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-db))
    (requirement '(user-processes))
    (documentation "Run the QubesDB VM daemon.")
    (start #~(make-forkexec-constructor
              (list "/run/current-system/profile/bin/sh" "-c"
                    #$(string-append %qubes-runtime-setup-command
                                     "; " %xen-device-setup-command
                                     "; exec /run/current-system/profile/bin/qubesdb-daemon 0"))
              #:log-file "/var/log/qubes-db.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-db-service-type
  (service-type
   (name 'qubes-db)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-db-shepherd-service)))
   (default-value #f)
   (description "Run QubesDB inside a Qubes VM.")))

(define (qubes-sysinit-shepherd-service _)
  (list
   (one-shot-service
    'qubes-sysinit
    '(qubes-db)
    "exec /usr/lib/qubes/init/qubes-sysinit.sh"
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
    (program-file
     "qubes-meminfo-writer"
     (with-imported-modules (source-module-closure
                             '((guix build utils)))
       #~(begin
           (use-modules (guix build utils)
                        (ice-9 textual-ports)
                        (srfi srfi-13))

           (define pidfile #$pid-file)

           (define (warn message)
             (display message (current-error-port))
             (newline (current-error-port)))

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

           (define (run command)
             (unless (zero? (system* "/run/current-system/profile/bin/sh" "-c"
                                     command))
               (warn (string-append "command failed: " command))
               (exit 1)))

           (define (read-pid path)
             (and (file-exists? path)
                  (let ((text (call-with-input-file path get-string-all)))
                    (string->number (string-trim-both text)))))

           (define (group-gid name)
             (let ((entry (false-if-exception (getgr name))))
               (and entry (vector-ref entry 2))))

           (setenv "PATH"
                   (string-append
                    "/run/current-system/profile/bin:"
                    "/run/current-system/profile/sbin"
                    (let ((path (getenv "PATH")))
                      (if path (string-append ":" path) ""))))
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
             (when (file-exists? "/var/run/qubes")
               (delete-file-recursively "/var/run/qubes"))
             (when (file-exists? "/var/run/qubes-service")
               (delete-file-recursively "/var/run/qubes-service"))
             (replace-symlink "/run/qubes" "/var/run/qubes")
             (replace-symlink "/run/qubes-service" "/var/run/qubes-service")
             (replace-symlink "/run/qubes-service-environment"
                              "/var/run/qubes-service-environment"))

           (run #$%xen-device-setup-command)

           (unless (file-exists? "/run/qubes-service/meminfo-writer")
             (display "meminfo-writer disabled\n")
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
                 (exit 1))))))))))

(define (qubes-meminfo-writer-shepherd-service config)
  (list
   (shepherd-service
    (provision '(qubes-meminfo-writer))
    (requirement '(user-processes qubes-sysinit))
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

(define %qubes-network-uplink-command
  (string-append
   ". /usr/lib/qubes/init/functions; "
   "ip link set lo up 2>/dev/null || true; "
   "i=0; iface=; "
   "while [ \"$i\" -lt 300 ]; do "
   "iface=$(get_qubes_managed_iface 2>/dev/null || true); "
   "[ -n \"$iface\" ] && break; "
   "i=$((i + 1)); sleep 0.1; "
   "done; "
   "if [ -z \"$iface\" ]; then "
   "echo 'No Qubes managed network interface found'; exit 0; "
   "fi; "
   "exec /usr/lib/qubes/setup-ip add \"$iface\""))

(define (qubes-network-uplink-shepherd-service _)
  (list
   (one-shot-service
    'qubes-network-uplink
    '(qubes-sysinit)
    %qubes-network-uplink-command
    "/var/log/qubes-network-uplink.log")))

(define qubes-network-uplink-service-type
  (service-type
   (name 'qubes-network-uplink)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-network-uplink-shepherd-service)))
   (default-value #f)
   (description "Configure the Qubes-provided VM network uplink.")))

(define %qubes-updates-proxy-forwarder-command
  (string-append
   ". /usr/lib/qubes/init/functions; "
   "i=0; "
   "while [ $i -lt 600 ] && [ ! -e /var/run/qubes-service-environment ]; do "
   "i=$((i + 1)); sleep 0.1; "
   "done; "
   "if ! qsvc updates-proxy-setup; then "
   "echo 'updates-proxy-setup disabled'; exit 0; "
   "fi; "
   "if qsvc qubes-updates-proxy; then "
   "echo 'qubes-updates-proxy enabled locally; not forwarding to avoid loops'; "
   "exit 0; "
   "fi; "
   "exec socat TCP-LISTEN:8082,bind=127.0.0.1,reuseaddr,fork "
   "EXEC:/usr/lib/qubes/guix-updates-proxy-forwarder"))

(define (qubes-updates-proxy-forwarder-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-updates-proxy-forwarder))
    (requirement '(qubes-sysinit))
    (documentation "Forward 127.0.0.1:8082 to Qubes UpdatesProxy RPC.")
    (respawn? #f)
    (start #~(make-forkexec-constructor
              (list "/run/current-system/profile/bin/sh" "-c"
                    #$(string-append %qubes-runtime-setup-command
                                     "; " %qubes-updates-proxy-forwarder-command))
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

(define %qubes-guix-update-proxy-command
  (string-append
   ". /usr/lib/qubes/init/functions; "
   "proxy=; "
   "if qsvc updates-proxy-setup && ! qsvc qubes-updates-proxy; then "
   "proxy=http://127.0.0.1:8082/; "
   "fi; "
   "mkdir -p /run/qubes/bin /etc/profile.d; "
   "profile=/etc/profile.d/qubes-guix-update-proxy.sh; "
   "wrapper=/run/qubes/bin/guix; "
   "if [ -n \"$proxy\" ]; then "
   "cat > \"$wrapper\" <<'EOF'\n"
   "#!/run/current-system/profile/bin/sh\n"
   "proxy=http://127.0.0.1:8082/\n"
   "no_proxy_value=127.0.0.1,localhost\n"
   "exec env \\\n"
   "  http_proxy=\"${http_proxy:-$proxy}\" \\\n"
   "  https_proxy=\"${https_proxy:-$proxy}\" \\\n"
   "  HTTP_PROXY=\"${HTTP_PROXY:-$proxy}\" \\\n"
   "  HTTPS_PROXY=\"${HTTPS_PROXY:-$proxy}\" \\\n"
   "  no_proxy=\"${no_proxy:-$no_proxy_value}\" \\\n"
   "  NO_PROXY=\"${NO_PROXY:-$no_proxy_value}\" \\\n"
   "  /run/current-system/profile/bin/guix \"$@\"\n"
   "EOF\n"
   "chmod 0755 \"$wrapper\"; "
   "cat > \"$profile\" <<'EOF'\n"
   "### This file is automatically generated by Qubes Guix integration.\n"
   "### All modifications here will be lost.\n"
   "export PATH=/run/qubes/bin:$PATH\n"
   "EOF\n"
   "chmod 0644 \"$profile\"; "
   "else "
   "rm -f \"$wrapper\" \"$profile\"; "
   "fi"))

(define (qubes-guix-update-proxy-shepherd-service _)
  (list
   (best-effort-one-shot-service
    'qubes-guix-update-proxy
    '(qubes-sysinit)
    %qubes-guix-update-proxy-command
    "/var/log/qubes-guix-update-proxy.log")))

(define qubes-guix-update-proxy-service-type
  (service-type
   (name 'qubes-guix-update-proxy)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-guix-update-proxy-shepherd-service)))
   (default-value #f)
   (description "Configure Guix client tooling to use the Qubes updates proxy.")))

(define (qubes-mount-dirs-shepherd-service _)
  (list
   (one-shot-service
            'qubes-mount-dirs
            '(qubes-sysinit)
            (string-append %qubes-private-dirs-mounted-command
                           "; " %qubes-rw-device-wait-command
                           "; " %qubes-rw-fstab-command
                           "; exec /usr/lib/qubes/init/mount-dirs.sh")
    "/var/log/qubes-mount-dirs.log")))

(define qubes-mount-dirs-service-type
  (service-type
   (name 'qubes-mount-dirs)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-mount-dirs-shepherd-service)))
   (default-value #f)
   (description "Mount Qubes persistent directories such as /rw, /home, and /usr/local.")))

(define (qubes-bind-dirs-shepherd-service _)
  (list
   (one-shot-service
    'qubes-bind-dirs
    '(qubes-mount-dirs)
    "exec /usr/lib/qubes/init/bind-dirs.sh"
    "/var/log/qubes-bind-dirs.log")))

(define qubes-bind-dirs-service-type
  (service-type
   (name 'qubes-bind-dirs)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-bind-dirs-shepherd-service)))
   (default-value #f)
   (description "Apply Qubes bind-dirs configuration.")))

(define (qubes-misc-post-shepherd-service _)
  (list
   (best-effort-one-shot-service
    'qubes-misc-post
    '(qubes-bind-dirs)
    (string-append
     ;; On systemd-based templates, qubes-misc-post.service is a late
     ;; best-effort action: a proxy/rc-local failure marks that unit failed
     ;; but does not prevent the VM from staying up long enough for qrexec and
     ;; qubes.PostInstall.  Shepherd treats failed boot one-shots as fatal
     ;; during system startup, so preserve the log signal without aborting the
     ;; native Guix VM boot.
     "/usr/lib/qubes/init/misc-post.sh; "
     "status=$?; "
     "if [ \"$status\" -ne 0 ]; then "
     "echo \"qubes-misc-post exited with status $status\" >&2; "
     "fi; "
     "exit 0")
    "/var/log/qubes-misc-post.log")))

(define qubes-misc-post-service-type
  (service-type
   (name 'qubes-misc-post)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-misc-post-shepherd-service)))
   (default-value #f)
   (description "Run late Qubes VM setup.")))

(define (qubes-qrexec-agent-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-qrexec-agent))
    (requirement '(user-processes qubes-bind-dirs qubes-meminfo-writer))
    (documentation "Run the Qubes qrexec agent.")
    (start #~(make-forkexec-constructor
              (list "/run/current-system/profile/bin/sh" "-c"
                    #$(string-append %qubes-runtime-setup-command
                                     "; " %xen-device-setup-command
                                     "; exec /usr/lib/qubes/qrexec-agent"))
              #:log-file "/var/log/qubes-qrexec-agent.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-qrexec-agent-service-type
  (service-type
   (name 'qubes-qrexec-agent)
   (extensions
    (list (service-extension shepherd-root-service-type qubes-qrexec-agent-shepherd-service)))
   (default-value #f)
   (description "Run the Qubes qrexec agent.")))

(define (qubes-qrexec-fork-server-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-qrexec-fork-server))
    (requirement '(qubes-qrexec-agent qubes-gui-agent))
    (documentation "Run the user qrexec fork server for Qubes GUI sessions.")
    (start #~(make-forkexec-constructor
              (list "/run/current-system/profile/bin/sh" "-c"
                    #$(string-append
                       %qubes-runtime-setup-command
                       "; " %qubes-user-runtime-dir-command
                       "; user=$(qubesdb-read /default-user 2>/dev/null || echo user)"
                       "; uid=$(id -u \"$user\")"
                       "; gid=$(id -g \"$user\")"
                       "; home=$(getent passwd \"$user\" | cut -d: -f6)"
                       "; [ -n \"$home\" ] || home=\"/home/$user\""
                       "; socket=\"/var/run/qubes/qrexec-server.$user.sock\""
                       "; touch \"$home/.xsession-errors\""
                       "; chown \"$uid:$gid\" \"$home/.xsession-errors\""
                       ;; Qubes' WaitForSession RPC is served by the user
                       ;; qrexec fork server.  Start that fork server only
                       ;; after Xorg has opened :0, otherwise GUI tests can
                       ;; observe a user session before applications can
                       ;; connect to the display.
                       "; i=0"
                       "; while [ ! -S /tmp/.X11-unix/X0 ] && [ \"$i\" -lt 240 ]; do"
                       " sleep 0.25; i=$((i + 1)); done"
                       "; if [ ! -S /tmp/.X11-unix/X0 ]; then"
                       " echo 'timed out waiting for X display :0' >&2; exit 1; fi"
                       "; export "
                       "HOME=\"$home\" USER=\"$user\" LOGNAME=\"$user\" "
                       "SHELL=/run/current-system/profile/bin/sh "
                       "DISPLAY=:0 XDG_RUNTIME_DIR=\"/run/user/$uid\" "
                       "DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/$uid/bus\" "
                       "QUBES_QREXEC_FORK_SOCKET=\"$socket\""
                       "; exec /run/current-system/profile/bin/su "
                       "-m -s /run/current-system/profile/bin/sh \"$user\" -c "
                       "'exec /run/current-system/profile/bin/qrexec-fork-server "
                       "\"$QUBES_QREXEC_FORK_SOCKET\"'"))
              #:log-file "/var/log/qubes-qrexec-fork-server.log"))
    (stop #~(make-kill-destructor)))))

(define qubes-qrexec-fork-server-service-type
  (service-type
   (name 'qubes-qrexec-fork-server)
   (extensions
    (list (service-extension shepherd-root-service-type
                             qubes-qrexec-fork-server-shepherd-service)))
   (default-value #f)
   (description "Run qrexec-fork-server for the Qubes default user.")))

(define (qubes-gui-agent-shepherd-service _)
  (list
   (shepherd-service
    (provision '(qubes-gui-agent))
    (requirement '(user-processes qubes-bind-dirs qubes-qrexec-agent))
    (documentation "Run the Qubes GUI agent.")
    (start #~(make-forkexec-constructor
              '("/run/current-system/profile/bin/sh" "-c"
                "test \"$(qubesdb-read --default=True /qubes-gui-enabled)\" = True || exit 0; export DISPLAY=:0; /usr/lib/qubes/qubes-gui-agent-pre.sh; if [ -r /run/qubes-service-environment ]; then while IFS= read -r line; do case \"$line\" in DISPLAY=*) DISPLAY=${line#DISPLAY=} ;; GUI_OPTS=*) GUI_OPTS=${line#GUI_OPTS=} ;; esac; done < /run/qubes-service-environment; fi; export DISPLAY GUI_OPTS; exec /run/current-system/profile/bin/qubes-gui ${GUI_OPTS:-}")
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
        (service qubes-qrexec-pam-service-type)
        (service qubes-acpi-shutdown-service-type)
        (service qubes-db-service-type)
        (service qubes-sysinit-service-type)
        (service qubes-meminfo-writer-service-type)
        (service qubes-network-uplink-service-type)
        (service qubes-updates-proxy-forwarder-service-type)
        (service qubes-guix-update-proxy-service-type)
        (service qubes-mount-dirs-service-type)
        (service qubes-bind-dirs-service-type)
        (service qubes-misc-post-service-type)
        (service qubes-qrexec-agent-service-type)))

(define %qubes-vm-gui-services
  (append %qubes-vm-headless-services
          (list (service qubes-gui-agent-service-type))))
