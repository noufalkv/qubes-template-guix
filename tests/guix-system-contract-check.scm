;; SPDX-License-Identifier: GPL-3.0-or-later
(use-modules (gnu services)
             (gnu services base)
             (gnu services shepherd)
             (gnu services sysctl)
             (gnu system)
             (gnu system accounts)
             (gnu system file-systems)
             (gnu system privilege)
             (guix derivations)
             (guix gexp)
             (guix packages)
             (guix store)
             (ice-9 match)
             (ice-9 textual-ports)
             (qubes packages qubes-vm)
             (qubes services qubes-vm)
             (qubes systems guix-template)
             (srfi srfi-1)
             (srfi srfi-26)
             (system base compile))

(define (fail format-string . args)
  (apply format (current-error-port) format-string args)
  (newline (current-error-port))
  (exit 1))

(define (assert condition format-string . args)
  (unless condition
    (apply fail format-string args)))

(define (object->string object)
  (call-with-output-string
    (lambda (port)
      (write object port))))

(define (service-names os)
  (map (compose service-type-name service-kind)
       (operating-system-services os)))

(define (service-value-by-name os name)
  (let ((matches (filter (lambda (service)
                           (eq? (service-type-name (service-kind service))
                                name))
                         (operating-system-services os))))
    (match matches
      ((service) (service-value service))
      (() (fail "missing service: ~a" name))
      (_ (fail "duplicate service: ~a" name)))))

(define (service-kind-by-name os name)
  (let ((matches (filter (lambda (service)
                           (eq? (service-type-name (service-kind service))
                                name))
                         (operating-system-services os))))
    (match matches
      ((service) (service-kind service))
      (() (fail "missing service: ~a" name))
      (_ (fail "duplicate service: ~a" name)))))

(define (check-sudoers variant os)
  (let ((sudoers ((@@ (guix gexp) plain-file-content)
                  (operating-system-sudoers-file os))))
    (assert (string-contains sudoers "%wheel ALL=(ALL) NOPASSWD:ALL")
            "~a sudoers does not keep passwordless wheel sudo"
            variant)
    (assert (string-contains sudoers "user ALL=(ALL) NOPASSWD:ALL")
            "~a sudoers does not keep passwordless Qubes user sudo"
            variant)))

(define (check-user-account variant os)
  (let ((account (find (lambda (account)
                         (string=? (user-account-name account) "user"))
                       (operating-system-user-accounts os))))
    (assert account
            "~a missing standard Qubes user account"
            variant)
    (assert (string=? (user-account-group account) "users")
            "~a Qubes user primary group is not users"
            variant)
    (for-each (lambda (group)
                (assert (member group
                                (user-account-supplementary-groups account))
                        "~a Qubes user missing supplementary group: ~a"
                        variant group))
              '("wheel" "netdev" "audio" "video" "qubes"))))

(define (check-package-surface variant os)
  (let ((names (map package-name (operating-system-packages os))))
    (for-each
     (lambda (name)
       (assert (member name names)
               "~a package surface missing expected package: ~a"
               variant name))
     (append
      '("acpid"
        "bash"
        "coreutils"
        "curl"
        "dbus"
        "git"
        "guix"
        "inetutils"
        "nss-certs"
        "python"
        "sudo"
        "xorg-server"
        "xterm"
        "zstd"
        "qubes-vm-core"
        "qubes-vm-gui")
      (case variant
        ((normal) '("evince" "mousepad" "thunar" "xfce4-terminal"))
        ((minimal) '("qubes-xterm-desktop-entry")))))
    (when (eq? variant 'minimal)
      (for-each
       (lambda (name)
         (assert (not (member name names))
                 "~a package surface unexpectedly includes normal desktop package: ~a"
                 variant name))
       '("evince" "mousepad" "thunar" "xfce4-terminal")))))

(define (check-privileged-programs variant os)
  (let ((programs (operating-system-privileged-programs os)))
    (for-each
     (lambda (default-program)
       (assert (member default-program programs)
               "~a privileged program set lost Guix default entry: ~a"
               variant default-program))
     %default-privileged-programs)
    (assert (any (lambda (program)
                   (string-contains (object->string program)
                                    "/lib/qubes/qfile-unpacker"))
                 programs)
            "~a privileged program set missing Qubes qfile-unpacker"
            variant)))

(define (check-meminfo-writer variant os)
  (let ((value (service-value-by-name os 'qubes-meminfo-writer))
        (threshold (@@ (qubes services qubes-vm)
                       qubes-meminfo-writer-configuration-threshold))
        (delay (@@ (qubes services qubes-vm)
                   qubes-meminfo-writer-configuration-delay))
        (pid-file (@@ (qubes services qubes-vm)
                      qubes-meminfo-writer-configuration-pid-file)))
    (assert (qubes-meminfo-writer-configuration? value)
            "~a meminfo-writer service has unexpected configuration"
            variant)
    (assert (= (threshold value) 30000)
            "~a meminfo-writer threshold is not the Qubes default"
            variant)
    (assert (= (delay value) 100000)
            "~a meminfo-writer delay is not the Qubes default"
            variant)
    (assert (string=? (pid-file value) "/var/run/meminfo-writer.pid")
            "~a meminfo-writer pid-file is not the Qubes default"
            variant)))

(define (check-sysctl variant os)
  (let* ((value (service-value-by-name os 'sysctl))
         (settings (sysctl-configuration-settings value)))
    (for-each (match-lambda
                ((key . expected)
                 (assert (string=? (assoc-ref settings key) expected)
                         "~a sysctl setting mismatch: ~a"
                         variant key)))
              '(("kernel.threads-max" . "51200")))
    (for-each (lambda (key)
                (assert (not (assoc-ref settings key))
                        "~a Qubes network wildcard should be handled by qubes-network-sysctl, not generic sysctl: ~a"
                        variant key))
              '("net.ipv4.conf.*.accept_source_route"
                "net.ipv4.conf.*.accept_redirects"
                "net.ipv4.conf.*.secure_redirects"
                "net.ipv4.conf.*.send_redirects"
                "net.ipv4.conf.*.drop_unicast_in_l2_multicast"
                "net.ipv6.conf.*.accept_source_route"
                "net.ipv6.conf.*.accept_redirects"
                "net.ipv6.conf.*.accept_ra"
                "net.ipv6.conf.*.accept_dad"
                "net.ipv6.conf.*.autoconf"
                "net.ipv6.conf.*.drop_unicast_in_l2_multicast"))
    (assert (string=? (assoc-ref settings "fs.protected_hardlinks") "1")
            "~a sysctl service lost Guix default hardlink protection"
            variant)
    (assert (string=? (assoc-ref settings "fs.protected_symlinks") "1")
            "~a sysctl service lost Guix default symlink protection"
            variant)))

(define (check-guix-daemon variant os)
  (let* ((config (service-value-by-name os 'guix))
         (environment (guix-configuration-environment config)))
    (assert (not (guix-configuration-http-proxy config))
            "~a Guix daemon must not force inactive local update proxy"
            variant)
    (for-each
     (lambda (entry)
       (assert (not (member entry environment))
               "~a Guix daemon must not force inactive local update proxy: ~a"
               variant entry))
     '("http_proxy=http://127.0.0.1:8082/"
       "https_proxy=http://127.0.0.1:8082/"
       "HTTP_PROXY=http://127.0.0.1:8082/"
       "HTTPS_PROXY=http://127.0.0.1:8082/"
       "all_proxy=http://127.0.0.1:8082/"
       "ALL_PROXY=http://127.0.0.1:8082/"
       "no_proxy=127.0.0.1,localhost"
       "NO_PROXY=127.0.0.1,localhost"))))

(define (folded-shepherd-services os)
  (let ((root-service
         ((@@ (gnu services) fold-services)
          (operating-system-services os)
          #:target-type shepherd-root-service-type)))
    ((@@ (gnu services shepherd) shepherd-configuration-services)
     (service-value root-service))))

(define (shepherd-service-requirements variant os service-name)
  (let ((shepherd-services (folded-shepherd-services os)))
    (match (filter (lambda (service)
                     (memq service-name
                           ((@@ (gnu services shepherd)
                                shepherd-service-provision)
                            service)))
                   shepherd-services)
      ((service)
       ((@@ (gnu services shepherd) shepherd-service-requirement)
        service))
      (() (fail "~a missing Shepherd service: ~a" variant service-name))
      (_ (fail "~a duplicate Shepherd service: ~a" variant service-name)))))

(define (check-shepherd-service-requirement variant os service-name requirement)
  (assert (memq requirement
                (shepherd-service-requirements variant os service-name))
          "~a service ~a does not require Shepherd service ~a"
          variant service-name requirement))

(define (check-shepherd-service-lacks-requirement variant os service-name
                                              requirement)
  (assert (not (memq requirement
                     (shepherd-service-requirements variant os service-name)))
          "~a service ~a should not require Shepherd service ~a"
          variant service-name requirement))

(define (check-shepherd-service-before variant os first second)
  (let* ((shepherd-services (folded-shepherd-services os))
         (service-index
          (lambda (name)
            (list-index
             (lambda (service)
               (memq name
                     ((@@ (gnu services shepherd)
                          shepherd-service-provision)
                      service)))
             shepherd-services)))
         (first-index (service-index first))
         (second-index (service-index second)))
    (assert first-index
            "~a missing Shepherd service in order check: ~a"
            variant first)
    (assert second-index
            "~a missing Shepherd service in order check: ~a"
            variant second)
    (assert (< first-index second-index)
            "~a Shepherd service ~a should be scheduled before ~a"
            variant first second)))

(define (check-generated-helper-syntax)
  (let ((store (open-connection))
        (helpers
         `(("qubes-loopback"
            . ,((@@ (qubes services qubes-vm) qubes-loopback-program)))
	           ("qubes-sysctl"
	            . ,((@@ (qubes services qubes-vm) qubes-sysctl-program)
	                '(("kernel.threads-max" . "51200"))))
	           ("qubes-network-sysctl"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-network-sysctl-program)))
	           ("qubes-kernel-modules"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-kernel-modules-program)))
	           ("qubes-db"
	            . ,((@@ (qubes services qubes-vm) qubes-db-program)))
	           ("qubes-sysinit"
	            . ,((@@ (qubes services qubes-vm) qubes-sysinit-program)))
	           ("qubes-meminfo-writer"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-meminfo-writer-program)
	                ((@@ (qubes services qubes-vm)
	                     qubes-meminfo-writer-configuration))))
	           ("qubes-network-uplink"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-network-uplink-program)))
	           ("qubes-network"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-network-program)))
	           ("qubes-feature-advertisement"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-feature-advertisement-program)))
	           ("qubes-updates-proxy-forwarder"
	            . ,((@@ (qubes services qubes-vm)
	                    qubes-updates-proxy-forwarder-program)))
	           ("qubes-mount-dirs"
	            . ,((@@ (qubes services qubes-vm) qubes-mount-dirs-program)))
	           ("qubes-bind-dirs"
	            . ,((@@ (qubes services qubes-vm) qubes-bind-dirs-program)))
	           ("qubes-misc-post"
	            . ,((@@ (qubes services qubes-vm) qubes-misc-post-program)))
	           ("qubes-qrexec-agent"
	            . ,((@@ (qubes services qubes-vm) qubes-qrexec-agent-program)))
	           ("qubes-gui-agent"
	            . ,((@@ (qubes services qubes-vm) qubes-gui-agent-program))))))
    (for-each
     (match-lambda
       ((name . program)
        (catch #t
          (lambda ()
            (let* ((lowered (run-with-store store (lower-object program)))
                   (path (derivation->output-path lowered)))
              (build-derivations store (list lowered))
              (compile-file path
                            #:output-file
                            (string-append "/tmp/" name "-syntax.go"))))
          (lambda (key . args)
            (fail "generated helper does not compile: ~a: ~s ~s"
                  name key args)))))
     helpers)))

(define (check-xen-network-hotplug-tools)
  (let* ((store (open-connection))
         (drv (package-derivation store xen-network-hotplug-tools))
         (out (derivation->output-path drv))
         (required-paths
          '("/bin/xenstore-read"
            "/bin/xenstore-write"
            "/etc/xen/scripts/hotplugpath.sh"
            "/etc/xen/scripts/locking.sh"
            "/etc/xen/scripts/logging.sh"
            "/etc/xen/scripts/vif-common.sh"
            "/etc/xen/scripts/xen-hotplug-common.sh"
            "/etc/xen/scripts/xen-network-common.sh"
            "/etc/xen/scripts/xen-script-common.sh")))
    (build-derivations store (list drv))
    (for-each
     (lambda (path)
       (assert (file-exists? (string-append out path))
               "xen-network-hotplug-tools missing required path: ~a"
               path))
     required-paths)
    (assert (memq xen-network-hotplug-tools %qubes-vm-headless-packages)
            "Qubes headless package set missing xen-network-hotplug-tools")))

(define (check-wait-for-session-script)
  (let* ((store (open-connection))
         (drv (package-derivation store qubes-vm-qrexec))
         (out (derivation->output-path drv))
         (script (string-append out "/etc/qubes-rpc/qubes.WaitForSession"))
         (meta-end "!#\n"))
    (build-derivations store (list drv))
    (assert (file-exists? script)
            "qubes-vm-qrexec missing qubes.WaitForSession")
    (let* ((text (call-with-input-file script get-string-all))
           (meta-index (string-contains text meta-end)))
      (assert (string-contains text
                               "#!/run/current-system/profile/bin/guile -s\n")
              "qubes.WaitForSession missing Guile meta-switch shebang")
      (assert meta-index
              "qubes.WaitForSession missing Guile meta-switch terminator")
      (assert (not (string-contains text
                                     "/run/current-system/profile/bin/qrexec-client"))
              "qubes.WaitForSession must not return just because qrexec-client exists")
      (assert (not (string-contains text "/usr/bin/qrexec-client"))
              "qubes.WaitForSession must not return just because legacy qrexec-client exists")
      (assert (string-contains text "/var/run/qubes/qrexec-server.")
              "qubes.WaitForSession missing qrexec fork-server socket wait")
      (assert (not (string-contains text "--default=True"))
              "qubes.WaitForSession must not use invalid qubesdb-read --default form")
      (catch #t
        (lambda ()
          (let ((body (substring text (+ meta-index
                                         (string-length meta-end)))))
            (assert (not (eof-object? (call-with-input-string body read)))
                    "qubes.WaitForSession has no Scheme body")))
        (lambda (key . args)
          (fail "qubes.WaitForSession Scheme body does not parse: ~s ~s"
                key args))))))

(define (check-qubesdb-client-wrappers)
  (let* ((store (open-connection))
         (drv (package-derivation store qubesdb-vm))
         (out (derivation->output-path drv)))
    (build-derivations store (list drv))
    (for-each
     (match-lambda
       ((name command)
        (let* ((path (string-append out "/bin/" name))
               (st (lstat path))
               (text (call-with-input-file path get-string-all)))
          (assert (eq? (stat:type st) 'regular)
                  "QubesDB client applet is not an explicit wrapper: ~a"
                  name)
          (assert (string-contains text "/bin/qubesdb-cmd")
                  "QubesDB client wrapper does not call qubesdb-cmd: ~a"
                  name)
          (assert (string-contains text
                                   (string-append "-c " command " \"$@\""))
                  "QubesDB client wrapper does not force command ~a: ~a"
                  command name))))
     '(("qubesdb-read" "read")
       ("qubesdb-write" "write")
       ("qubesdb-rm" "rm")
       ("qubesdb-multiread" "multiread")
       ("qubesdb-list" "list")
       ("qubesdb-watch" "watch")))))

(define (check-guile-script path description)
  (let* ((meta-end "!#\n")
         (text (call-with-input-file path get-string-all))
         (meta-index (string-contains text meta-end)))
    (assert (string-contains text
                             "#!/run/current-system/profile/bin/guile -s\n")
            "~a missing Guile meta-switch shebang"
            description)
    (assert meta-index
            "~a missing Guile meta-switch terminator"
            description)
    (catch #t
      (lambda ()
        (let ((body (substring text (+ meta-index
                                       (string-length meta-end)))))
          (assert (not (eof-object? (call-with-input-string body read)))
                  "~a has no Scheme body"
                  description)))
      (lambda (key . args)
        (fail "~a Scheme body does not parse: ~s ~s"
              description key args)))))

(define (check-core-guile-scripts)
  (let* ((store (open-connection))
         (drv (package-derivation store qubes-vm-core))
         (out (derivation->output-path drv)))
    (build-derivations store (list drv))
    (for-each
     (match-lambda
       ((path . description)
        (check-guile-script (string-append out path) description)))
     '(("/lib/qubes/guix-updates-proxy-forwarder"
        . "guix-updates-proxy-forwarder")
       ("/lib/qubes/qubes-network-interface-sysctl"
        . "qubes-network-interface-sysctl")))))

(define (check-qubes-session-environment)
  (let* ((store (open-connection))
         (drv (package-derivation store qubes-vm-gui))
         (out (derivation->output-path drv))
         (script (string-append out "/bin/qubes-session")))
    (build-derivations store (list drv))
    (assert (file-exists? script)
            "qubes-vm-gui missing qubes-session")
    (let ((text (call-with-input-file script get-string-all)))
      (for-each
       (lambda (needle)
         (assert (string-contains text needle)
                 "qubes-session does not export StartApp environment: ~a"
                 needle))
       '(": \"${DISPLAY:=:0}\""
         ": \"${XDG_CONFIG_DIRS:=/run/current-system/profile/etc/xdg}\""
         ": \"${XDG_DATA_DIRS:=/run/current-system/profile/share}\""
         ": \"${GI_TYPELIB_PATH:=/run/current-system/profile/lib/girepository-1.0}\""
         ": \"${SSL_CERT_DIR:=/etc/ssl/certs}\""
         ": \"${SSL_CERT_FILE:=/etc/ssl/certs/ca-certificates.crt}\""
         ": \"${GIT_SSL_CAINFO:=/etc/ssl/certs/ca-certificates.crt}\""
         ": \"${CURL_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}\""
         ": \"${XDG_CACHE_HOME:=/var/tmp/guix-cache-${USER:-user}}\""
         "export DISPLAY XDG_CONFIG_DIRS XDG_DATA_DIRS GI_TYPELIB_PATH"
         "export SSL_CERT_DIR SSL_CERT_FILE GIT_SSL_CAINFO CURL_CA_BUNDLE XDG_CACHE_HOME PATH")))))

(define (check-qvm-template-repo-query-helper)
  (let* ((store (open-connection))
         (drv (package-derivation store qubes-vm-core))
         (out (derivation->output-path drv))
         (wrapper (string-append out "/lib/qubes/qvm-template-repo-query"))
         (fallback
          (string-append out "/lib/qubes/qvm-template-repo-query-guix")))
    (build-derivations store (list drv))
    (for-each
     (lambda (path)
       (assert (file-exists? path)
               "qubes-vm-core missing qvm-template repo helper: ~a"
               path))
     (list wrapper fallback))
    (let ((wrapper-text (call-with-input-file wrapper get-string-all))
          (fallback-text (call-with-input-file fallback get-string-all)))
      (assert (string-contains wrapper-text
                               "qvm-template-repo-query-guix")
              "qvm-template repo query wrapper does not fall back to Guix helper")
      (assert (string-contains fallback-text "primary_metadata_url")
              "Guix qvm-template repo query helper missing rpm-md parser")
      (assert (string-contains fallback-text "/bin/curl")
              "Guix qvm-template repo query helper does not use store curl")
      (assert (string-contains fallback-text "/bin/zstd")
              "Guix qvm-template repo query helper does not use store zstd"))))

(define (check-filecopy-script)
  (let* ((store (open-connection))
         (drv (package-derivation store qubes-vm-core))
         (out (derivation->output-path drv))
         (script (string-append out "/etc/qubes-rpc/qubes.Filecopy")))
    (build-derivations store (list drv))
    (assert (file-exists? script)
            "qubes-vm-core missing qubes.Filecopy RPC service")
    (let ((text (call-with-input-file script get-string-all)))
      (assert (string-contains text "/run/setuid-programs/qfile-unpacker")
              "qubes.Filecopy does not prefer Guix setuid-programs qfile-unpacker")
      (assert (string-contains text "/run/privileged/bin/qfile-unpacker")
              "qubes.Filecopy does not support older Guix privileged qfile-unpacker path")
      (assert (not (string-contains
                    text
                    "exec /usr/lib/qubes/qfile-unpacker $arg\n"))
              "qubes.Filecopy still directly execs the store/profile qfile-unpacker"))))

(define (check-system variant)
  (let* ((os (qubes-template-operating-system #:variant variant))
         (names (service-names os)))
    (assert (equal? (map swap-space-target
                         (operating-system-swap-devices os))
                    '("/dev/xvdc1"))
            "~a swap devices do not match standard Qubes /dev/xvdc1"
            variant)
    (assert (memq 'qubes-loopback names)
            "~a missing Qubes loopback service"
            variant)
    (assert (eq? (service-kind-by-name os 'udev)
                 qubes-udev-service-type)
            "~a should use Qubes udev service semantics"
            variant)
    (assert (not (memq 'static-networking names))
            "~a should not use generic static-networking in Qubes boot"
            variant)
    (assert (eq? (service-kind-by-name os 'sysctl)
                 qubes-sysctl-service-type)
            "~a should use Qubes Scheme sysctl service semantics"
            variant)
    (for-each (lambda (name)
                (assert (memq name names)
                        "~a missing required Qubes service: ~a"
                        variant name))
              '(qubes-kernel-modules
                qubes-db qubes-meminfo-writer qubes-qrexec-agent
                qubes-gui-agent qubes-mount-dirs qubes-bind-dirs
                qubes-misc-post qubes-network-sysctl
                qubes-network-uplink qubes-network
                qubes-feature-advertisement
                qubes-updates-proxy-forwarder))
    (check-sudoers variant os)
    (check-user-account variant os)
    (check-package-surface variant os)
    (check-privileged-programs variant os)
    (check-meminfo-writer variant os)
    (check-sysctl variant os)
    (check-guix-daemon variant os)
    (check-shepherd-service-requirement variant os
                                        'qubes-kernel-modules
                                        'root-file-system)
    (check-shepherd-service-requirement variant os
                                        'qubes-db
                                        'root-file-system)
    (check-shepherd-service-requirement variant os
                                        'qubes-db
                                        'qubes-kernel-modules)
    (check-shepherd-service-requirement variant os
                                        'udev
                                        'root-file-system)
    (check-shepherd-service-requirement variant os
                                        'udev
                                        'sysctl)
    (check-shepherd-service-requirement variant os
                                        'udev
                                        'qubes-kernel-modules)
    (check-shepherd-service-lacks-requirement variant os
                                              'udev
                                              'user-processes)
    (check-shepherd-service-lacks-requirement variant os
                                              'qubes-db
                                              'user-processes)
    (check-shepherd-service-requirement variant os
                                        'qubes-meminfo-writer
                                        'qubes-sysinit)
    (check-shepherd-service-lacks-requirement variant os
                                              'qubes-meminfo-writer
                                              'user-processes)
    (check-shepherd-service-requirement variant os
                                        'qubes-mount-dirs
                                        'qubes-sysinit)
    (check-shepherd-service-requirement variant os
                                        'qubes-bind-dirs
                                        'qubes-mount-dirs)
    (check-shepherd-service-requirement variant os
                                        'qubes-misc-post
                                        'qubes-bind-dirs)
    (check-shepherd-service-requirement variant os
                                        'qubes-qrexec-agent
                                        'qubes-bind-dirs)
    (check-shepherd-service-lacks-requirement variant os
                                              'qubes-qrexec-agent
                                              'user-processes)
    (check-shepherd-service-lacks-requirement variant os
                                              'qubes-qrexec-agent
                                              'qubes-meminfo-writer)
    (check-shepherd-service-requirement variant os
                                        'qubes-gui-agent
                                        'qubes-bind-dirs)
    (check-shepherd-service-requirement variant os
                                        'qubes-gui-agent
                                        'qubes-qrexec-agent)
    (check-shepherd-service-requirement variant os
                                        'qubes-updates-proxy-forwarder
                                        'qubes-loopback)
    (check-shepherd-service-requirement variant os
                                        'sysctl
                                        'root-file-system)
    (check-shepherd-service-before variant os
                                   'sysctl
                                   'udev)
    (check-shepherd-service-before variant os
                                   'sysctl
                                   'qubes-udev-coldplug)
    (check-shepherd-service-requirement variant os
                                        'qubes-network-uplink
                                        'sysctl)
    (check-shepherd-service-requirement variant os
                                        'qubes-network-uplink
                                        'qubes-network-sysctl)
    (check-shepherd-service-requirement variant os
                                        'qubes-network
                                        'qubes-sysinit)
    (check-shepherd-service-requirement variant os
                                        'qubes-network
                                        'sysctl)
    (check-shepherd-service-requirement variant os
                                        'qubes-network
                                        'qubes-network-sysctl)
    (check-shepherd-service-requirement variant os
                                        'qubes-network
                                        'qubes-network-uplink)
    (check-shepherd-service-requirement variant os
                                        'qubes-feature-advertisement
                                        'qubes-qrexec-agent)))

(check-generated-helper-syntax)
(check-xen-network-hotplug-tools)
(check-wait-for-session-script)
(check-qubesdb-client-wrappers)
(check-core-guile-scripts)
(check-qubes-session-environment)
(check-qvm-template-repo-query-helper)
(check-filecopy-script)
(for-each check-system '(normal minimal))
(display "Guix system contract check passed")
(newline)
