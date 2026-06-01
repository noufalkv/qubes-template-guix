;; SPDX-License-Identifier: GPL-3.0-or-later
;; Qubes VM package definitions for the qubes-template-guix channel.

(define-module (qubes packages)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix modules)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (guix utils)
  #:use-module (gnu)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages certs)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages dns)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages haskell-xyz)
  #:use-module (gnu packages icu4c)
  #:use-module (gnu packages imagemagick)
  #:use-module (gnu packages libffi)
  #:use-module (gnu packages libunistring)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages package-management)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages text-editors)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages xfce)
  #:use-module (gnu packages xdisorg)
  #:use-module (gnu packages xorg)
  #:use-module (gnu system nss)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (qubes-release-version qubes-libvchan-xen
                                  qubes-linux-utils-qrexec
                                  qubes-vm-utils
                                  qubesdb-vm
                                  qubes-vm-qrexec
                                  qubes-vm-core
                                  qubes-vm-gui-common
                                  qubes-vm-gui
                                  pipewire-qubes
                                  qubes-dom0-kernel
                                  xen-vchan-libs
                                  xen-network-hotplug-tools
                                  %qubes-vm-headless-packages
                                  %qubes-vm-gui-packages
                                  %qubes-normal-audio-packages
                                  %qubes-normal-network-packages
                                  %qubes-normal-desktop-packages
                                  %qubes-common-packages
                                  qubes-variant-packages
                                  %qubes-network-sysctl-settings
                                  qubes-network-sysctl-helper-forms
                                  xterm-desktop-entry))

;; Network interface sysctl hardening applied to every Qubes-managed VIF.
;; Single source of truth shared by the boot-time all-interfaces applier
;; (qubes-network-sysctl), the post-boot per-managed-VIF applier
;; (qubes-network-uplink), both in (qubes services), and the hotplug
;; per-interface helper installed from qubes-vm-core below.  Defined here in
;; the leaf package module because (qubes services) already depends on
;; (qubes packages); defining it the other way around would create a module
;; import cycle.
(define %qubes-network-sysctl-settings
  '(("ipv4" "accept_source_route" . "0") ("ipv4" "accept_redirects" . "0")
    ("ipv4" "secure_redirects" . "0")
    ("ipv4" "send_redirects" . "0")
    ("ipv4" "drop_unicast_in_l2_multicast" . "1")
    ("ipv6" "accept_source_route" . "-1")
    ("ipv6" "accept_redirects" . "0")
    ("ipv6" "accept_ra" . "0")
    ("ipv6" "accept_dad" . "0")
    ("ipv6" "autoconf" . "0")
    ("ipv6" "drop_unicast_in_l2_multicast" . "1")))

(define (qubes-network-sysctl-helper-forms)
  "Return a list of definition forms implementing the shared per-interface
network sysctl primitives.  The forms are spliced once into both the
build-side generated /usr/lib/qubes/qubes-network-interface-sysctl helper and
the boot/uplink Shepherd service programs in (qubes services), via gexp
ungexp-splicing (#$@), so the write/apply logic is defined a single time.
Each consuming surface must provide a `warn' procedure (the service prelude
and the generated helper both do) and import (ice-9 ftw) for `scandir'."
  '((define (sysctl-path family interface name)
      (string-append "/proc/sys/net/"
                     family
                     "/conf/"
                     interface
                     "/"
                     name))

    (define (write-sysctl path value)
      ;; Skip a knob whose /proc path is absent (e.g. IPv6 disabled), but
      ;; fail loudly if an existing path cannot be written so dropped
      ;; hardening is never swallowed silently.
      (when (file-exists? path)
        (catch #t
               (lambda ()
                 (call-with-output-file path
                   (lambda (port)
                     (display value port))))
               (lambda (key . args)
                 (warn (string-append "failed to write network sysctl: " path))
                 (exit 1)))))

    (define (interface-names family)
      (or (false-if-exception (scandir (string-append "/proc/sys/net/" family
                                                      "/conf")
                                       (lambda (entry)
                                         (not (member entry
                                                      '("." ".."))))))
          '()))

    (define (apply-sysctls-to-iface settings interface)
      (for-each (lambda (setting)
                  (write-sysctl (sysctl-path (car setting) interface
                                             (cadr setting))
                                (cddr setting))) settings))

    (define (apply-sysctls-to-all-ifaces settings)
      (for-each (lambda (setting)
                  (let ((family (car setting)))
                    (for-each (lambda (interface)
                                (write-sysctl (sysctl-path family interface
                                                           (cadr setting))
                                              (cddr setting)))
                              (interface-names family)))) settings))))

(define %qvm-template-repo-query-guix
  ;; upstream: none — this rpm-md query/download helper is original to this
  ;; channel (Guix templates ship no DNF).  Kept as a standalone file under
  ;; files/ rather than an embedded plain-file string so it is
  ;; lint/test-friendly; installed and store-path-substituted below.
  (local-file "files/qvm-template-repo-query-guix.py"))

;;; Qubes VM package definitions

(define %qubes-source-components
  '(("qubes-core-vchan-xen" "v4.2.8"
     "a1337c282ffefcfc13a570683c57bc04813038db"
     "0nb5ky69w0v6xy7dkriagyi8fa2zpq2dnibr90pkf7asi0cib77j")
    ("qubes-linux-utils" "v4.3.17" "ee1e61f487f57d6b5d3ff96dbd8d6b50bd474656"
     "19q2i9gz4v585gw9mpmn1pw1zmykr3awg30rzm4vbfnv5i0czh56")
    ("qubes-core-qubesdb" "v4.3.2" "7d294b2ab922708b552fb2715f6a0333fbc52fcd"
     "1kal2lf4frjk083qd0ql5m8znbzn77pndxhclkl0pbc7v5ycrfyd")
    ("qubes-core-qrexec" "v4.3.12" "cc801b8f630a65dfb2855b829bfc070f6e82f26a"
     "1lbz435sjs3d7pc9ymnwxqi14sc83xdnny5pzwp8c580rraysvd4")
    ("qubes-core-agent-linux" "v4.3.44"
     "1bf7d428c04b921f78eab898b9987c94d1ffb695"
     "0098fk5r9zvvk63g614w5gqzgaa0l6mhk8p06kw8kki57bzy0x5c")
    ("qubes-gui-common" "v4.3.1" "66b879e36d6cd2a01271fc8d4c2c0f3be85d0029"
     "1ilr2wximl82y05f9dha69pjwhks2c73cfh08yxpnbdg5yspcc24")
    ("qubes-gui-agent-linux" "v4.3.17"
     "b801955eaf4cc7bea59401bc428293dbfd866e48"
     "1fybqb195kp8blk73f119lindwfvk48p7980fi6nvwhafibdlmnc")))

(define (qubes-source-field component index)
  "Return field INDEX of COMPONENT's entry in %qubes-source-components."
  (let ((entry (assoc component %qubes-source-components)))
    (unless entry
      (error "unknown Qubes source component" component))
    (list-ref entry index)))

(define (qubes-release-version component)
  "Return COMPONENT's release version, the pinned tag without a leading \"v\"."
  (let ((tag (qubes-source-field component 1)))
    (if (and (> (string-length tag) 0)
             (char=? (string-ref tag 0) #\v))
        (substring tag 1) tag)))

(define* (qubes-release-source component #:key (patches '()))
  "Return a git-fetch origin for COMPONENT pinned to its commit and hash.
PATCHES, when given, is a list of patches (e.g. local-file objects) applied to
the fetched source; it defaults to the empty list."
  (origin
    (method git-fetch)
    (uri (git-reference (url (string-append "https://github.com/QubesOS/"
                                            component ".git"))
                        (commit (qubes-source-field component 2))))
    (file-name (git-file-name component
                              (qubes-source-field component 1)))
    (sha256 (base32 (qubes-source-field component 3)))
    (patches patches)))

(define qubes-dom0-kernel
  (package
    (name "qubes-dom0-kernel")
    (version "0")
    (source
     #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder
      #~(begin
          (mkdir #$output)
          (mkdir (string-append #$output "/lib"))
          (mkdir (string-append #$output "/lib/modules"))
          (call-with-output-file (string-append #$output "/bzImage")
            (lambda (port)
              (display "Qubes dom0 supplies the VM kernel.\n" port))))))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Placeholder kernel for Qubes TemplateVM images")
    (description
     "Placeholder kernel package used by native Qubes TemplateVM
images.  Qubes dom0 supplies the actual VM kernel at boot time, so the template
root image does not need a guest kernel package.")
    (license license:gpl2+)))

(define xen-vchan-libs
  (package
    (name "xen-vchan-libs")
    (version (package-version xen))
    (source
     #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils)
                  (ice-9 ftw)
                  (ice-9 popen)
                  (ice-9 rdelim)
                  (ice-9 regex))
      #:builder
      #~(begin
          (use-modules (guix build utils)
                       (ice-9 ftw)
                       (ice-9 popen)
                       (ice-9 rdelim)
                       (ice-9 regex))

          (define prefixes
            '("libxenvchan" "libxenctrl"
              "libxenstore"
              "libxentoollog"
              "libxengnttab"
              "libxenevtchn"
              "libxencall"
              "libxenforeignmemory"
              "libxendevicemodel"
              "libxentoolcore"))

          (define (string-prefix? prefix value)
            (let ((prefix-length (string-length prefix)))
              (and (>= (string-length value) prefix-length)
                   (string=? prefix
                             (substring value 0 prefix-length)))))

          (define (wanted-library? entry)
            (and (string-match "\\.so" entry)
                 (let loop
                   ((prefixes prefixes))
                   (and (pair? prefixes)
                        (or (string-prefix? (car prefixes) entry)
                            (loop (cdr prefixes)))))))

          (define (copy-entry source destination)
            (let ((stat (lstat source)))
              (case (stat:type stat)
                ((symlink)
                 (symlink (readlink source) destination))
                ((regular)
                 (copy-file source destination)))))

          (define (command-line-output . args)
            (let* ((port (apply open-pipe* OPEN_READ args))
                   (line (read-line port)))
              (close-pipe port)
              (if (eof-object? line) "" line)))

          (define (replace-substring value needle replacement)
            (let ((needle-length (string-length needle)))
              (let loop
                ((start 0)
                 (pieces '()))
                (let ((index (string-contains value needle start)))
                  (if index
                      (loop (+ index needle-length)
                            (cons replacement
                                  (cons (substring value start index) pieces)))
                      (apply string-append
                             (reverse (cons (substring value start) pieces))))))))

          (let ((source-lib (string-append #$xen "/lib"))
                (out-lib (string-append #$output "/lib"))
                (patchelf (string-append #$patchelf "/bin/patchelf")))
            (mkdir-p out-lib)
            (for-each (lambda (entry)
                        (when (wanted-library? entry)
                          (copy-entry (string-append source-lib "/" entry)
                                      (string-append out-lib "/" entry))))
                      (scandir source-lib))
            ;; Guix's Xen libraries carry an RPATH back to the full Xen output,
            ;; which would retain Xen tools, QEMU, firmware, and OVMF in the
            ;; template.  Rewrite copied shared objects to resolve within this
            ;; tiny library subset while preserving libc/libgcc paths.
            (for-each (lambda (entry)
                        (let ((file (string-append out-lib "/" entry)))
                          (when (and (wanted-library? entry)
                                     (eq? (stat:type (lstat file))
                                          'regular))
                            (let* ((rpath (command-line-output patchelf
                                           "--print-rpath" file))
                                   (new-rpath (replace-substring rpath
                                                                 source-lib
                                                                 out-lib)))
                              (when (and (not (string-null? rpath))
                                         (not (string=? rpath new-rpath)))
                                (chmod file #o644)
                                (invoke patchelf "--set-rpath" new-rpath file)
                                (chmod file #o555))))))
                      (scandir out-lib))
            #t))))
    (native-inputs (list patchelf))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Small Xen vchan runtime library subset")
    (description
     "Runtime subset of Xen libraries needed by the Qubes VM-side
vchan and qrexec components, without Xen hypervisor tools, QEMU, or firmware.")
    (license license:gpl2+)))

(define xen-network-hotplug-tools
  (package
    (name "xen-network-hotplug-tools")
    (version (package-version xen))
    (source
     #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out-bin (string-append #$output "/bin"))
                 (out-scripts (string-append #$output "/etc/xen/scripts"))
                 (xen-scripts (string-append #$xen "/etc/xen/scripts"))
                 (rpath (string-append #$xen-vchan-libs "/lib")))
            (mkdir-p out-bin)
            (mkdir-p out-scripts)
            (for-each (lambda (tool)
                        (let ((target (string-append out-bin "/" tool)))
                          (copy-file (string-append #$xen "/bin/" tool) target)
                          (chmod target #o755)
                          (invoke (string-append #$patchelf "/bin/patchelf")
                                  "--set-rpath" rpath target)))
                      '("xenstore-read" "xenstore-write"))
            ;; upstream: xen.git tools/hotplug/Linux/init.d/xen-scripts —
            ;; these helper scripts hardcode the Xen install prefix; rewrite it
            ;; to this package's store path.  Only some scripts embed the
            ;; prefix, so accumulate matches across the whole set and fail
            ;; loudly only if upstream drift removes it from all of them.
            (let ((matched 0))
              (for-each (lambda (script)
                          (let ((target (string-append out-scripts "/" script)))
                            (copy-file (string-append xen-scripts "/" script)
                                       target)
                            (chmod target #o755)
                            (substitute* target
                              ((#$xen)
                               (set! matched
                                     (+ matched 1))
                               #$output))))
                        '("hotplugpath.sh" "locking.sh"
                          "logging.sh"
                          "vif-common.sh"
                          "xen-hotplug-common.sh"
                          "xen-network-common.sh"
                          "xen-script-common.sh"))
              (unless (> matched 0)
                (error "substitute* found no matches"
                       "xen/scripts:xen-network-hotplug-tools")))))))
    (native-inputs (list patchelf))
    (inputs (list xen-vchan-libs))
    (home-page "https://xenproject.org/")
    (synopsis "Small Xen network hotplug subset for Qubes NetVMs")
    (description
     "A small package containing the XenStore tools and Xen network
hotplug helper scripts required by Qubes' VM-side vif-route-qubes backend
script, without adding the full Xen tool stack to native Qubes Guix templates.")
    (license license:gpl2)))

(define qubes-libvchan-xen
  (package
    (name "qubes-libvchan-xen")
    (version (qubes-release-version "qubes-core-vchan-xen"))
    (source
     (qubes-release-source "qubes-core-vchan-xen"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; This upstream makefile builds and installs the VM-side vchan library;
      ;; it does not provide a test target.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make"
                      "all"
                      "CC=gcc"
                      (string-append "PREFIX="
                                     #$output)
                      (string-append "LIBDIR="
                                     #$output "/lib")
                      (string-append "INCLUDEDIR="
                                     #$output "/include")
                      (string-append "LDFLAGS=-L"
                                     #$xen-vchan-libs
                                     "/lib "
                                     "-Wl,-rpath="
                                     #$xen-vchan-libs
                                     "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make"
                      "install"
                      "DESTDIR="
                      (string-append "PREFIX="
                                     #$output)
                      (string-append "LIBDIR="
                                     #$output "/lib")
                      (string-append "INCLUDEDIR="
                                     #$output "/include")))))))
    (native-inputs (list pkg-config xen))
    (inputs (list xen-vchan-libs))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes Xen vchan library")
    (description "VM-side Xen vchan support used by Qubes agents.")
    (license license:gpl2+)))

(define qubes-linux-utils-qrexec
  (package
    (name "qubes-linux-utils-qrexec")
    (version (qubes-release-version "qubes-linux-utils"))
    (source
     (qubes-release-source "qubes-linux-utils"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; This upstream subdirectory builds and installs the qrexec file-copy
      ;; support library; it does not provide a test target.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make"
                      "-C"
                      "qrexec-lib"
                      "all"
                      "CC=gcc"
                      "NO_REBUILD_TABLE=1"
                      (string-append
                       "LDFLAGS=-Wl,--no-undefined,--as-needed,-Bsymbolic -L . -Wl,-rpath="
                       #$output "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make"
                      "-C"
                      "qrexec-lib"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "LIBDIR=/lib"
                      "INCLUDEDIR=/include"))))))
    (native-inputs (list pkg-config))
    (inputs (list icu4c))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes qrexec file-copy support libraries")
    (description
     "Qubes RPC file-copy and pure utility libraries used by VM-side agents.")
    (license license:gpl2+)))

(define qubes-vm-utils
  (package
    (name "qubes-vm-utils")
    (version (qubes-release-version "qubes-linux-utils"))
    (source
     (qubes-release-source "qubes-linux-utils"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The qmemman subdirectory only builds the meminfo-writer program and
      ;; installs its systemd units; it does not provide a test target.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make"
                      "-C"
                      "qmemman"
                      "all"
                      "CC=gcc"
                      (string-append "CFLAGS=-Wall -Wextra -Werror -g -O3 "
                                     "-DUSE_XENSTORE_H -I"
                                     #$xen "/include")
                      (string-append "LDFLAGS=-L"
                                     #$xen
                                     "/lib "
                                     "-Wl,-rpath="
                                     #$xen
                                     "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make"
                      "-C"
                      "qmemman"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "BINDIR=/bin"))))))
    (inputs (list xen))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes VM utility programs")
    (description "VM-side Qubes utility programs, including the memory
information reporter used by Qubes memory ballooning.")
    (license license:gpl2+)))

(define qubesdb-vm
  (package
    (name "qubesdb-vm")
    (version (qubes-release-version "qubes-core-qubesdb"))
    (source
     (qubes-release-source "qubes-core-qubesdb"
                           #:patches
                           (list (local-file
                                  "patches/guix-specific/qubesdb-vm-db-daemon-foreground.patch"))))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The daemon tests expect a live QubesDB/Xen VM environment; this
      ;; package build installs the VM-side daemon, tools, and bindings.
      #:tests? #f
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 regex))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (let ((rpath (string-append "-Wl,-rpath="
                                          #$output "/lib")))
                (invoke "make"
                        "all"
                        "SYSTEMD=0"
                        "CC=gcc"
                        (string-append "LDFLAGS=" rpath)
                        (string-append "APPEND_LDFLAGS=" rpath)))))
          (replace 'install
            (lambda _
              (invoke "make"
                      "-C"
                      "daemon"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "BINDIR=/bin")
              (invoke "make"
                      "-C"
                      "client"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "LIBDIR=/lib"
                      "BINDIR=/bin")
              ;; The upstream client installs hard-linked applets that infer
              ;; the command from argv[0].  In a Guix profile argv[0] is often
              ;; a store/profile path rather than /usr/bin/qubesdb-read, which
              ;; makes the applet print usage and exit 0.  Install explicit
              ;; wrappers so both Qubes scripts and native services get stable
              ;; read/write/list behavior.
              (let ((qubesdb-cmd (string-append #$output "/bin/qubesdb-cmd")))
                (for-each (lambda (entry)
                            (let ((path (string-append #$output "/bin/"
                                                       (car entry)))
                                  (command (cadr entry)))
                              (when (file-exists? path)
                                (delete-file path))
                              (call-with-output-file path
                                (lambda (port)
                                  (format port "#!~a~%exec ~a -c ~a \"$@\"~%"
                                          #$(file-append bash-minimal
                                                         "/bin/sh")
                                          qubesdb-cmd command)))
                              (chmod path #o755)))
                          '(("qubesdb-read" "read")
                            ("qubesdb-write" "write")
                            ("qubesdb-rm" "rm")
                            ("qubesdb-multiread" "multiread")
                            ("qubesdb-list" "list")
                            ("qubesdb-watch" "watch"))))
              (let* ((extensions (find-files "python/build" "^qubesdb.*\\.so$"))
                     (first-extension (and (pair? extensions)
                                           (car extensions)))
                     (python-tag (and first-extension
                                      (string-match
                                       "\\.cpython-([0-9])([0-9]+)"
                                       (basename first-extension)))))
                (unless python-tag
                  (error "no built qubesdb Python extension found"))
                (let ((site (string-append #$output
                                           "/lib/python"
                                           (match:substring python-tag 1)
                                           "."
                                           (match:substring python-tag 2)
                                           "/site-packages")))
                  (mkdir-p site)
                  (for-each (lambda (extension)
                              (copy-file extension
                                         (string-append site "/"
                                                        (basename extension))))
                            extensions)))
              (invoke "make"
                      "-C"
                      "include"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "INCLUDEDIR=/include"))))))
    (native-inputs (list pkg-config python-wrapper python-setuptools))
    (inputs (list bash-minimal qubes-libvchan-xen))
    (home-page "https://www.qubes-os.org/")
    (synopsis "QubesDB VM daemon and client tools")
    (description
     "QubesDB VM-side daemon, command-line client, and Python bindings.")
    (license license:gpl2+)))

(define qubes-vm-qrexec
  (package
    (name "qubes-vm-qrexec")
    (version (qubes-release-version "qubes-core-qrexec"))
    (source
     (qubes-release-source "qubes-core-qrexec"
                           #:patches
                           (list (local-file
                                  "patches/should-upstream/qubes-vm-qrexec-env-buf.patch"))))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; Upstream tests exercise live qrexec/Xen service behavior; this package
      ;; build only installs the VM-side agent and helper programs.
      #:tests? #f
      #:imported-modules `((qubes build utils)
                           ,@%default-gnu-imported-modules)
      #:modules '((qubes build utils)
                  (guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (ice-9 textual-ports)
                  (srfi srfi-1)
                  (srfi srfi-13))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make" "all-base" "PANDOC=true" "CC=gcc")
              ;; qrexec-agent switches QUBESRPC calls to the requested user and
              ;; exports HOME/USER/LOGNAME only in its PAM-enabled code path.
              ;; The upstream Makefile detects PAM through /usr/include, which
              ;; is not meaningful inside a Guix build container, so select PAM
              ;; with the upstream make variable when linux-pam is an input.
              (invoke "make"
                      "all-vm"
                      "PANDOC=true"
                      "CC=gcc"
                      "HAVE_PAM_APPL=1"
                      (string-append "LDFLAGS=-pie -Wl,-z,relro,-z,now "
                                     "-L../libqrexec -Wl,-rpath="
                                     #$output "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make"
                      "install-base"
                      "install-vm"
                      (string-append "DESTDIR="
                                     #$output)
                      "HAVE_PAM_APPL=1"
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "UNITDIR=/lib/systemd/system")
              ;; The VM-side qubes.WaitForSession is provided by
              ;; qubes-core-agent-linux (installed by qubes-vm-core below) and is
              ;; patched there to tolerate a missing systemctl; qrexec only ships
              ;; the dom0 variant, which install-vm does not install.
              (let ()
                (define (directory-entries directory)
                  (or (false-if-exception (scandir directory
                                                   (lambda (entry)
                                                     (not (member entry
                                                                  '("." ".."))))))
                      '()))

                (define (find-directory root name)
                  (let loop
                    ((directory root))
                    (and (path-exists? directory)
                         (or (and (string=? (basename directory) name)
                                  directory)
                             (any (lambda (entry)
                                    (let ((child (string-append directory "/"
                                                                entry)))
                                      (and (non-symlink-directory? child)
                                           (loop child))))
                                  (directory-entries directory))))))

                (define python-directory
                  (or (python-version-directory #$python-pyinotify)
                      (error
                       "could not determine Python site-packages version")))
                (define site
                  (string-append #$output "/lib/" python-directory
                                 "/site-packages"))
                (define pythonpath
                  (cons site
                        (filter-map (lambda (root)
                                      (python-site-packages root
                                                            python-directory))
                                    (list #$python-pyinotify))))

                (mkdir-p site)
                (let ((qrexec-source (find-directory (string-append #$output
                                                      "/gnu/store") "qrexec")))
                  (unless qrexec-source
                    (error "qrexec Python package was not installed"))
                  (delete-path (string-append site "/qrexec"))
                  (copy-recursively qrexec-source
                                    (string-append site "/qrexec")))
                (for-each (lambda (pair)
                            (merge-tree (string-append #$output "/"
                                                       (car pair))
                                        (string-append #$output "/"
                                                       (cdr pair))))
                          '(("usr/bin" . "bin")
                            ("usr/lib/qubes" . "lib/qubes")
                            ("usr/lib/tmpfiles.d" . "lib/tmpfiles.d")
                            ("usr/include" . "include")
                            ("usr/share" . "share")))
                (let ((bindir (string-append #$output "/bin")))
                  (when (path-exists? bindir)
                    (for-each (lambda (name)
                                (let* ((script (string-append bindir "/" name))
                                       (text (false-if-exception (read-text
                                                                  script))))
                                  (when (and text
                                             (string-prefix?
                                              "#!/usr/bin/python3" text)
                                             (string-contains text
                                                              "from qrexec."))
                                    (write-text script
                                                (replace-once text
                                                              "\nfrom qrexec."
                                                              (string-append
                                                               "\nimport sys\nsys.path[:0] = "
                                                               (python-list
                                                                pythonpath)
                                                               "\nfrom qrexec.")
                                                              script)))))
                              (scandir bindir
                                       (lambda (entry)
                                         (not (member entry
                                                      '("." ".."))))))))
                (delete-path (string-append #$output "/gnu"))
                (delete-path (string-append #$output "/usr"))))))))
    (native-inputs (list pkg-config gzip python-setuptools))
    (inputs (list bash-minimal linux-pam python-pyinotify qubes-libvchan-xen
                  python-wrapper))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes qrexec VM agent")
    (description "VM-side qrexec agent and client tools for Qubes RPC.")
    (license license:gpl2+)))

(define qubes-vm-core
  (package
    (name "qubes-vm-core")
    (version (qubes-release-version "qubes-core-agent-linux"))
    (source
     (qubes-release-source "qubes-core-agent-linux"
                           #:patches
                           (list (local-file
                                  "patches/guix-specific/qubes-vm-core-init-functions-skel.patch")
                                 (local-file
                                  "patches/guix-specific/qubes-vm-core-setup-ip-sysctl.patch")
                                 (local-file
                                  "patches/guix-specific/qubes-vm-core-vif-route-sysctl.patch")
                                 (local-file
                                  "patches/should-upstream/qubes-vm-core-wait-for-session-guard.patch"))))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The agent-linux tree is mostly VM filesystem, init, and hook
      ;; integration; its validation is integration-level in a Qubes TemplateVM.
      #:tests? #f
      #:imported-modules `((qubes build utils)
                           ,@%default-gnu-imported-modules)
      #:modules '((qubes build utils)
                  (guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (ice-9 match)
                  (ice-9 textual-ports)
                  (srfi srfi-1)
                  (srfi srfi-13))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'verify-network-sysctl-table
            (lambda _
              ;; Guard against silent drift between the Scheme copy of the
              ;; per-interface network sysctls (%qubes-network-sysctl-settings,
              ;; shared by the boot/uplink services and the vif-route helper)
              ;; and the upstream source of truth.  Parse the per-interface
              ;; ("conf.*") entries of network/81-qubes.conf.optional and error
              ;; the build if they no longer match, so a maintainer is told to
              ;; re-sync on a component bump instead of shipping wrong hardening.
              ;; NOTE: the system-wide entries (max_hbh_opts_length,
              ;; max_dst_opts_length, conf.all.*) and network/80-qubes.conf
              ;; (drop_unsolicited_na) are deliberately out of this per-interface
              ;; table's scope and are not compared here.
              (let* ((entry-key (lambda (entry)
                                  ;; Total order over family, knob, and value
                                  ;; so duplicated knob names across families
                                  ;; cannot cause a false drift on reorder.
                                  (string-append (car entry) "\x00"
                                                 (cadr entry) "\x00"
                                                 (cddr entry))))
                     (sort-entries (lambda (entries)
                                     (sort entries
                                           (lambda (a b)
                                             (string<? (entry-key a)
                                                       (entry-key b))))))
                     (expected (sort-entries '#$%qubes-network-sysctl-settings))
                     (file "network/81-qubes.conf.optional")
                     (lines (string-split (call-with-input-file file
                                            get-string-all) #\newline))
                     (parsed (filter-map (lambda (line)
                                           (let ((trimmed (string-trim-both
                                                           line)))
                                             (and (not (string-null? trimmed))
                                                  (not (string-prefix? "#"
                                                        trimmed))
                                                  (let ((eq (string-index
                                                             trimmed #\=)))
                                                    (and eq
                                                         (let* ((key (string-trim-right
                                                                      (substring
                                                                       trimmed
                                                                       0 eq)))
                                                                (value (string-trim
                                                                        (substring
                                                                         trimmed
                                                                         (+ eq
                                                                          1))))
                                                                (parts (string-split
                                                                        key
                                                                        #\.)))
                                                           (match parts
                                                             (("net" family
                                                               "conf" "*" name)
                                                              (cons* family
                                                                     name
                                                                     value))
                                                             (_ #f))))))))
                                         lines))
                     (actual (sort-entries parsed)))
                (unless (equal? expected actual)
                  (error (string-append
                          "%qubes-network-sysctl-settings drifted from upstream "
                          "network/81-qubes.conf.optional; re-sync the table")
                          'expected expected
                          'upstream actual)))))
          (replace 'build
            (lambda _
              (invoke "make"
                      "-C"
                      "qubes-rpc"
                      (string-append "VERSION="
                                     #$(qubes-release-version
                                        "qubes-core-agent-linux"))
                      "CC=gcc"
                      "release=Guix"
                      (string-append "LDFLAGS=-pie -Wl,-rpath="
                                     #$qubes-linux-utils-qrexec "/lib"))
              (invoke "make"
                      "-C"
                      "misc"
                      (string-append "VERSION="
                                     #$(qubes-release-version
                                        "qubes-core-agent-linux"))
                      "CC=gcc"
                      "release=Guix")))
          (replace 'install
            (lambda _
              (invoke "make"
                      "install-corevm"
                      (string-append "DESTDIR="
                                     #$output)
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "SYSTEM_DROPIN_DIR=/lib/systemd/system"
                      "USER_DROPIN_DIR=/lib/systemd/user"
                      "PYTHON=python3"
                      "DIST=guix"
                      "release=Guix")
              (invoke "make"
                      "install-netvm"
                      (string-append "DESTDIR="
                                     #$output)
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "SYSTEM_DROPIN_DIR=/lib/systemd/system"
                      "USER_DROPIN_DIR=/lib/systemd/user"
                      "PYTHON=python3"
                      "DIST=guix"
                      "release=Guix")
              (invoke "make"
                      "-C"
                      "qubes-rpc"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "BINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc")
              (invoke "make" "-C" "qubes-rpc/thunar" "install"
                      (string-append "DESTDIR="
                                     #$output))
              (invoke "make"
                      "-C"
                      "network"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "BINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc")
              ;; install-corevm intentionally skips packaging-specific payloads
              ;; that RPM/Debian specs install separately.  The post-install
              ;; qrexec hooks need these helpers to report supported features,
              ;; sync application menus, and expose /usr/share/qubes/marker-vm.
              (mkdir-p (string-append #$output "/usr/share/applications"))
              (invoke "make" "-C" "misc" "install"
                      (string-append "DESTDIR="
                                     #$output))
              (invoke "make" "-C" "app-menu" "install"
                      (string-append "DESTDIR="
                                     #$output))
              (invoke "make"
                      "-C"
                      "filesystem"
                      "install"
                      (string-append "DESTDIR="
                                     #$output)
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc"
                      "STATEDIR=/var/lib")
              (let ()
                (define (patch-file-once path needle replacement)
                  (write-text path
                              (replace-once (read-text path) needle
                                            replacement path)))

                (define (write-guile-script path expression)
                  (mkdir-p (dirname path))
                  (call-with-output-file path
                    (lambda (port)
                      (display "#!/run/current-system/profile/bin/guile -s
"
                               port)
                      (display "!#\n" port)
                      (write expression port)
                      (newline port)))
                  (chmod path #o755))

                (define (write-python-wrapper path pythonpath module)
                  (write-text path
                              (string-append "#!"
                                             (which "python3")
                                             "\n"
                                             "import sys\n"
                                             "sys.path[:0] = "
                                             (python-list pythonpath)
                                             "\n"
                                             "from "
                                             module
                                             " import main\n"
                                             "if __name__ == '__main__':\n"
                                             "    raise SystemExit(main())\n"))
                  (chmod path #o755))

                (define python-directory
                  (or (python-version-directory #$python-pygobject)
                      (error
                       "could not determine Python site-packages version")))
                (define site
                  (string-append #$output "/lib/" python-directory
                                 "/site-packages"))
                (define extra-pythonpath
                  (filter-map (lambda (root)
                                (python-site-packages root python-directory))
                              (list #$qubesdb-vm
                                    #$python-dbus
                                    #$python-pygobject
                                    #$python-pyxdg)))
                (define pythonpath
                  (cons site extra-pythonpath))
                (define bindir
                  (string-append #$output "/bin"))
                (define qubes-libdir
                  (string-append #$output "/lib/qubes"))

                (for-each (lambda (pair)
                            (merge-tree (string-append #$output "/"
                                                       (car pair))
                                        (string-append #$output "/"
                                                       (cdr pair))))
                          '(("usr/bin" . "bin") ("usr/lib" . "lib")
                            ("usr/share" . "share")))
                (delete-path (string-append #$output "/usr"))
                (mkdir-p site)
                (delete-path (string-append site "/qubesagent"))
                (copy-recursively "build/lib/qubesagent"
                                  (string-append site "/qubesagent"))
                (mkdir-p bindir)

                (let ((postinstall (string-append #$output
                                    "/etc/qubes-rpc/qubes.PostInstall")))
                  (when (path-exists? postinstall)
                    ;; Qubes RPC services do not necessarily run through a login
                    ;; shell.  Give post-install hooks the profile-visible commands
                    ;; used by the Guix VM.
                    (patch-file-once postinstall
                     "
for script in /etc/qubes/post-install.d/*.sh; do
"
                     "
export PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin${PATH:+:$PATH}

for script in /etc/qubes/post-install.d/*.sh; do
")))

                (let ((get-image-rgba (string-append #$output
                                       "/etc/qubes-rpc/qubes.GetImageRGBA")))
                  (when (path-exists? get-image-rgba)
                    ;; Icon extraction is a qrexec service, not a login shell.
                    ;; Make the Guix profile tools and icon data visible there.
                    (patch-file-once get-image-rgba "set -e\n"
                     "set -e
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin${PATH:+:$PATH}
export XDG_DATA_DIRS=/run/current-system/profile/share:/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
")))

                (let ((xdg-icon (string-append qubes-libdir "/xdg-icon")))
                  (when (path-exists? xdg-icon)
                    (patch-file-once xdg-icon
                                     "import xdg.IconTheme\nimport sys\n"
                                     (string-append
                                                    "import sys\nsys.path[:0] = "
                                                    (python-list pythonpath)
                                                    "\nimport xdg.IconTheme\n"))))

                (let ((filecopy (string-append #$output
                                 "/etc/qubes-rpc/qubes.Filecopy")))
                  (when (path-exists? filecopy)
                    ;; Guix exposes setuid/setgid programs from a runtime
                    ;; privileged directory instead of trusting mode bits inside
                    ;; the store.  Resolve qfile-unpacker through that runtime
                    ;; copy before falling back to upstream's absolute RPC path.
                    (patch-file-once filecopy
                     "exec /usr/lib/qubes/qfile-unpacker $arg\n"
                     "for unpacker in /run/setuid-programs/qfile-unpacker /run/privileged/bin/qfile-unpacker /usr/lib/qubes/qfile-unpacker; do
    if [ -x \"$unpacker\" ]; then
        exec \"$unpacker\" $arg
    fi
done
echo \"qfile-unpacker not found\" >&2
exit 127
")))

                (write-text (string-append #$output
                             "/etc/qubes/rpc-config/qubes.PostInstall")
                            "force-user = 'root'\n")

                (mkdir-p qubes-libdir)
                (write-guile-script (string-append qubes-libdir
                                     "/guix-updates-proxy-forwarder")
                                    '(begin
                                       (execl
                                        "/run/current-system/profile/bin/qrexec-client-vm"
                                        "qrexec-client-vm"
                                        "--use-stdin-socket" ""
                                        "qubes.UpdatesProxy")))
                (let ((repo-query (string-append qubes-libdir
                                                 "/qvm-template-repo-query"))
                      (dnf-repo-query (string-append qubes-libdir
                                       "/qvm-template-repo-query.dnf"))
                      (guix-repo-query (string-append qubes-libdir
                                        "/qvm-template-repo-query-guix")))
                  (copy-file #$%qvm-template-repo-query-guix guix-repo-query)
                  ;; upstream: none — this helper is original to this channel
                  ;; (files/qvm-template-repo-query-guix.py).  Rewrite its three
                  ;; runtime anchors (python3 shebang, curl, zstd) to absolute
                  ;; store paths; fail loudly per anchor so the installed copy
                  ;; can never silently keep a non-store path on drift.
                  (let ((python-matched 0)
                        (curl-matched 0)
                        (zstd-matched 0))
                    (substitute* guix-repo-query
                      (("#!/run/current-system/profile/bin/python3")
                       (set! python-matched
                             (+ python-matched 1))
                       (string-append "#!"
                                      #$python "/bin/python3"))
                      (("\\[\"curl\"")
                       (set! curl-matched
                             (+ curl-matched 1))
                       (string-append "[\""
                                      #$curl "/bin/curl\""))
                      (("\\[\"zstd\"")
                       (set! zstd-matched
                             (+ zstd-matched 1))
                       (string-append "[\""
                                      #$zstd "/bin/zstd\"")))
                    (unless (> python-matched 0)
                      (error "substitute* found no matches"
                             "qvm-template-repo-query-guix: python3 shebang"))
                    (unless (> curl-matched 0)
                      (error "substitute* found no matches"
                             "qvm-template-repo-query-guix: curl invocation"))
                    (unless (> zstd-matched 0)
                      (error "substitute* found no matches"
                             "qvm-template-repo-query-guix: zstd invocation")))
                  (chmod guix-repo-query #o755)
                  (when (path-exists? repo-query)
                    (rename-file repo-query dnf-repo-query)
                    (write-text repo-query
                                (string-append "#!"
                                 #$bash-minimal
                                 "/bin/bash\n"
                                 "set -e\n"
                                 "script_dir=\"$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd -P)\"
"
                                 "if command -v dnf5 >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v dnf4 >/dev/null 2>&1; then
"
                                 "    exec \"$script_dir/qvm-template-repo-query.dnf\" \"$@\"
"
                                 "fi\n"
                                 "exec \"$script_dir/qvm-template-repo-query-guix\" \"$@\"
"))
                    (chmod repo-query #o755)))
                (write-guile-script (string-append qubes-libdir
                                     "/qubes-network-interface-sysctl")
                                    ;; '#$ splices the shared sysctl table and #$@ splices the
                                    ;; shared helper procedures (qubes-network-sysctl-helper-forms)
                                    ;; into this build-side helper, so the per-interface sysctl
                                    ;; logic is defined once and reused by the boot/uplink Shepherd
                                    ;; services in (qubes services).
                                    '(begin
                                       (use-modules (ice-9 ftw)
                                                    (ice-9 match)
                                                    (srfi srfi-1)
                                                    (srfi srfi-13))

                                       (define settings
                                         '#$%qubes-network-sysctl-settings)

                                       (define (warn message)
                                         (display message
                                                  (current-error-port))
                                         (newline (current-error-port)))

                                       #$@(qubes-network-sysctl-helper-forms)

                                       (define (arg-prefix arg)
                                         (and (string-prefix? "--prefix=" arg)
                                              (substring arg
                                                         (string-length
                                                          "--prefix="))))

                                       ;; Parse to (family . interface) and apply only that
                                       ;; family's settings, preserving the upstream systemd-sysctl
                                       ;; --prefix contract: a /net/ipv4/conf/IF prefix applies the
                                       ;; ipv4 knobs to IF, /net/ipv6/conf/IF the ipv6 knobs, and
                                       ;; non-conf (e.g. neigh) or unknown-family prefixes apply
                                       ;; nothing.
                                       (define (prefix->target prefix)
                                         (match (string-split prefix #\/)
                                           (("" "net" family "conf" interface)
                                            (and (member family
                                                         '("ipv4" "ipv6"))
                                                 (cons family interface)))
                                           (_ #f)))

                                       (for-each (match-lambda
                                                   ((family . interface) (apply-sysctls-to-iface
                                                                          (filter (lambda
                                                                                          (setting)

                                                                                    (string=?
                                                                                     (car
                                                                                      setting)
                                                                                     family))
                                                                           settings)
                                                                          interface)))
                                                 (delete-duplicates (filter-map
                                                                     prefix->target
                                                                     (filter-map
                                                                      arg-prefix
                                                                      (cdr (command-line))))
                                                                    equal?))))
                (for-each (lambda (helper)
                            (let ((destination (string-append qubes-libdir "/"
                                                              helper)))
                              (copy-file (string-append "package-managers/"
                                                        helper) destination)
                              (chmod destination #o755)))
                          '("upgrades-installed-check"
                            "upgrades-status-notify"))

                (let ((installed-check (string-append qubes-libdir
                                        "/upgrades-installed-check")))
                  (unless (string-contains (read-text installed-check)
                                           "## Guix System")
                    (patch-file-once installed-check
                                     "elif [ -e /etc/arch-release ]; then\n"
                                     (string-append
                                      "elif [ -e /run/current-system ]; then\n"
                                      "    ## Guix System\n"
                                      "    # There is no cheap metadata-only Guix System update check comparable to
"
                                      "    # dnf check-update or apt-get -s upgrade.  The Qubes vmupdate backend
"
                                      "    # reports system/profile changes while reconfiguring; this helper only
"
                                      "    # clears the post-update notification state after that succeeds.
"
                                      "    echo true\n"
                                      "    exit_code=0\n"
                                      "elif [ -e /etc/arch-release ]; then\n"))))

                (let ((features-request (string-append bindir
                                         "/qvm-features-request")))
                  (when (path-exists? features-request)
                    (patch-file-once features-request "import argparse\n"
                                     (string-append
                                                    "import sys\nsys.path[:0] = "
                                                    (python-list pythonpath)
                                                    "\n\nimport argparse\n"))
                    ;; Native Guix templates use Shepherd, not systemd.  Treat a
                    ;; successful post-install RPC as the qrexec-agent active
                    ;; signal when systemctl is absent.
                    (patch-file-once features-request
                     "def is_active(service):
    status = subprocess.call([\"systemctl\", \"is-active\", \"--quiet\", service])
    return status == 0
"
                     "def is_active(service):
    try:
        status = subprocess.call([\"systemctl\", \"is-active\", \"--quiet\", service])
    except FileNotFoundError:
        return service == \"qubes-qrexec-agent\"
    return status == 0
")))

                (let ((session-autostart (string-append bindir
                                          "/qubes-session-autostart")))
                  (when (path-exists? session-autostart)
                    (patch-file-once session-autostart "import sys\n"
                                     (string-append
                                                    "import sys\nsys.path[:0] = "
                                                    (python-list pythonpath)
                                                    "\n"))))
                (let ((start-app (string-append #$output
                                  "/etc/qubes-rpc/qubes.StartApp")))
                  (when (path-exists? start-app)
                    (patch-file-once start-app "import sys, os, pwd\n"
                                     (string-append
                                      "import sys, os, pwd\nsys.path[:0] = "
                                      (python-list pythonpath)
                                      "\n"
                                      "os.environ.setdefault(\n"
                                      "    'XDG_DATA_DIRS',\n"
                                      "    '/run/current-system/profile/share:"
                                      "/usr/local/share:/usr/share')\n"))))
                (let ((desktop-run (string-append bindir "/qubes-desktop-run")))
                  (when (path-exists? desktop-run)
                    (patch-file-once desktop-run
                                     "from qubesagent.xdg import launch
import sys
"
                                     (string-append
                                      "import sys\nsys.path[:0] = "
                                      (python-list pythonpath)
                                      "\nfrom qubesagent.xdg import launch\n"))))
                (let ((xdg-launcher (string-append site "/qubesagent/xdg.py")))
                  (when (path-exists? xdg-launcher)
                    (patch-file-once xdg-launcher "import functools\n\n"
                                     (string-append "import functools\n"
                                      "import os\n\n"
                                      "_gi_typelib_path = '"
                                      #$glib
                                      "/lib/girepository-1.0'\n"
                                      "os.environ['GI_TYPELIB_PATH'] = _gi_typelib_path + "
                                      "(':' + os.environ['GI_TYPELIB_PATH'] "
                                      "if os.environ.get('GI_TYPELIB_PATH') else '')

"))))

                (for-each (lambda (entry)
                            (write-python-wrapper (string-append bindir "/"
                                                                 (car entry))
                                                  pythonpath
                                                  (cdr entry)))
                          '(("qubes-firewall" . "qubesagent.firewall")
                            ("qubes-vmexec" . "qubesagent.vmexec")))
                (delete-path (string-append #$output "/gnu"))
                (for-each (lambda (stale)
                            (delete-path (string-append #$output "/usr/bin/"
                                                        stale)))
                          '("qubes-firewall" "qubes-vmexec"))))))))
    (native-inputs (list desktop-file-utils
                         pandoc
                         pkg-config
                         python-wrapper
                         python-setuptools
                         shared-mime-info))
    (inputs (list bash-minimal
                  conntrack-tools
                  coreutils
                  gawk
                  grep
                  iproute
                  glib
                  nftables
                  procps
                  sed
                  python-dbus
                  python-pygobject
                  python-pyxdg
                  qubes-linux-utils-qrexec
                  qubesdb-vm
                  qubes-vm-qrexec
                  socat))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes Linux VM core scripts")
    (description
     "Core VM-side Qubes scripts, RPC services, and compatibility files.")
    (license license:gpl2+)))

(define qubes-vm-gui-common
  (package
    (name "qubes-vm-gui-common")
    (version (qubes-release-version "qubes-gui-common"))
    (source
     (qubes-release-source "qubes-gui-common"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("include" "include"))))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes GUI protocol headers")
    (description "Common Qubes GUI protocol headers.")
    (license license:gpl2+)))

(define qubes-vm-gui
  (package
    (name "qubes-vm-gui")
    (version (qubes-release-version "qubes-gui-agent-linux"))
    (source
     (qubes-release-source "qubes-gui-agent-linux"
                           #:patches
                           (list (local-file
                                  "patches/guix-specific/qubes-vm-gui-config-shell.patch"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw)
                  (srfi srfi-13))
      ;; GUI agent tests require a running Qubes GUI/Xen display environment;
      ;; this package build installs the VM-side GUI agent and Xorg helpers.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              ;; Build the GUI/Xorg pieces needed for Qubes application
              ;; forwarding without pulling in the audio-specific
              ;; PulseAudio/PipeWire module targets.
              (let ((shell (which "sh")))
                (setenv "CONFIG_SHELL" shell)
                (setenv "SHELL" shell))
              (setenv "CPPFLAGS"
                      (string-append "-I"
                                     #$xen "/include"))
              (setenv "LDFLAGS"
                      (string-append "-L"
                                     #$xen-vchan-libs
                                     "/lib "
                                     "-Wl,-rpath="
                                     #$xen-vchan-libs
                                     "/lib"))
              (invoke "make" "gui-agent/qubes-gui"
                      "gui-agent/qubes-gui-runuser"
                      "xf86-qubes-common/libxf86-qubes-common.so" "CC=gcc")
              ;; The top-level Qubes Makefile invokes generated configure
              ;; scripts directly. Build these helpers explicitly so Guix can
              ;; run those generated scripts through CONFIG_SHELL.
              (for-each (lambda (directory)
                          (with-directory-excursion directory
                            (invoke (getenv "CONFIG_SHELL") "./autogen.sh"))
                          (invoke "make" "-C" directory "CC=gcc"))
                        '("xf86-input-mfndev" "xf86-video-dummy"))))
          (replace 'install
            (lambda _
              (define (move-profile-tree source destination)
                (when (file-exists? source)
                  (mkdir-p destination)
                  (for-each (lambda (entry)
                              (let ((from (string-append source "/" entry))
                                    (to (string-append destination "/" entry)))
                                (when (file-exists? to)
                                  (delete-file-recursively to))
                                (rename-file from to)))
                            (scandir source
                                     (lambda (entry)
                                       (not (member entry
                                                    '("." ".."))))))))

              (invoke "make"
                      "install-common"
                      "install-systemd"
                      (string-append "DESTDIR="
                                     #$output)
                      "LIBDIR=/lib"
                      "USRLIBDIR=/lib"
                      "SYSLIBDIR=/lib")
              ;; qrexec-fork-server daemonizes itself.  Keep upstream's XDG
              ;; autostart launcher as the single owner of that user-session
              ;; daemon instead of supervising it from Shepherd.
              (unless (file-exists? (string-append #$output
                                     "/etc/xdg/autostart/qubes-qrexec-fork-server.desktop"))
                (error "missing qrexec-fork-server.desktop"))
              (install-file "appvm-scripts/etc/sysconfig/desktop"
                            (string-append #$output "/etc/sysconfig"))
              (for-each (lambda (script)
                          (install-file script
                                        (string-append #$output
                                         "/etc/X11/xinit/xinitrc.d")))
                        '("appvm-scripts/etc/X11/xinit/xinitrc.d/20qt-x11-no-mitshm.sh"
                          "appvm-scripts/etc/X11/xinit/xinitrc.d/20qt-gnome-desktop-session-id.sh"
                          "appvm-scripts/etc/X11/xinit/xinitrc.d/50guivm-windows-prefix.sh"
                          "appvm-scripts/etc/X11/xinit/xinitrc.d/60xfce-desktop.sh"))
              ;; The upstream non-GuiVM path starts xinit through
              ;; qubes-gui-runuser so Xorg itself runs as the default user.
              ;; In this Guix System image there is no distro Xorg wrapper or
              ;; logind setup granting an unprivileged user access to vt07, so
              ;; Xorg exits before the Qubes GUI socket appears.  Keep the
              ;; session side unprivileged, but let root own xinit/Xorg.
              ;; Guix xinit's default xinitrc sources its immutable store
              ;; xinitrc.d, not the profile hook above, so run qubes-session
              ;; directly.  The upstream XDG autostart launcher remains the
              ;; owner of qrexec-fork-server; qubes.WaitForSession waits for
              ;; that server's socket.  The -ac flag is a review-sensitive
              ;; compatibility choice for this root-owned Xorg/user-session
              ;; split: the first-review image does not yet provide a distro
              ;; logind/xauth handoff that would otherwise authorize the
              ;; default user's Qubes session client.
              ;; upstream: qubes-gui-agent-linux qubes-run-xorg — the
              ;; qubes-xorg-wrapper invocation and the xinit/qubes-session exec
              ;; line.
              (let ((wrapper-matched 0)
                    (exec-matched 0))
                (substitute* (string-append #$output "/usr/bin/qubes-run-xorg")
                  (("qubes-xorg-wrapper \\$DISPLAY_XORG -nolisten")
                   (set! wrapper-matched
                         (+ wrapper-matched 1))
                   "qubes-xorg-wrapper $DISPLAY_XORG -modulepath /run/current-system/profile/lib/xorg/modules -fp /run/current-system/profile/share/fonts/X11/misc -nolisten")
                  (("exec /usr/bin/qubes-gui-runuser \"\\$DEFAULT_USER\" /bin/sh -l -c \"exec /usr/bin/xinit \\$XSESSION -- /usr/lib/qubes/qubes-xorg-wrapper :0 -nolisten tcp vt07 -wr -config xorg-qubes.conf > ~/.xsession-errors 2>&1\"")
                   (set! exec-matched
                         (+ exec-matched 1))
                   "exec /usr/bin/xinit /usr/bin/qubes-gui-runuser \"$DEFAULT_USER\" /usr/bin/env DISPLAY=:0 XDG_CONFIG_DIRS=/run/current-system/profile/etc/xdg XDG_DATA_DIRS=/run/current-system/profile/share GI_TYPELIB_PATH=/run/current-system/profile/lib/girepository-1.0 PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin /usr/bin/qubes-session qubes-session -- /usr/lib/qubes/qubes-xorg-wrapper :0 -modulepath /run/current-system/profile/lib/xorg/modules -fp /run/current-system/profile/share/fonts/X11/misc -nolisten tcp vt07 -wr -config xorg-qubes.conf -ac > \"/home/$DEFAULT_USER/.xsession-errors\" 2>&1"))
                (unless (> wrapper-matched 0)
                  (error "substitute* found no matches"
                   "qubes-gui-agent-linux:qubes-run-xorg modulepath wrapper"))
                (unless (> exec-matched 0)
                  (error "substitute* found no matches"
                   "qubes-gui-agent-linux:qubes-run-xorg xinit exec line")))
              ;; install-common follows the distribution FHS and places the
              ;; agent under /usr.  Guix profiles do not merge /usr/bin into
              ;; /bin, and the compatibility activation links /usr/lib/qubes
              ;; to profile/lib/qubes, so normalize those trees into the
              ;; profile-visible locations.
              (move-profile-tree (string-append #$output "/usr/bin")
                                 (string-append #$output "/bin"))
              (move-profile-tree (string-append #$output "/usr/lib")
                                 (string-append #$output "/lib"))
              (move-profile-tree (string-append #$output "/usr/share")
                                 (string-append #$output "/share"))
              (move-profile-tree (string-append #$output "/usr/include")
                                 (string-append #$output "/include"))
              (let ((qubes-session (string-append #$output
                                                  "/bin/qubes-session")))
                (when (file-exists? qubes-session)
                  ;; upstream: qubes-gui-agent-linux qubes-session — the
                  ;; "export QUBES_ENV_SOURCED=1" environment marker.
                  (let ((matched 0))
                    (substitute* qubes-session
                      (("export QUBES_ENV_SOURCED=1\n")
                       (set! matched
                             (+ matched 1))
                       (string-append "export QUBES_ENV_SOURCED=1\n"
                        "\n"
                        "# The native Guix session is started directly from xinit,
"
                        "# so make the GUI/profile environment explicit before
"
                        "# XDG autostart launches qrexec-fork-server.  Desktop
"
                        "# application launches inherit that daemon environment.
"
                        ": \"${DISPLAY:=:0}\"\n"
                        ": \"${XDG_RUNTIME_DIR:=/tmp/qubes-runtime-$(id -u)}\"
"
                        ": \"${XDG_CONFIG_DIRS:=/run/current-system/profile/etc/xdg}\"
"
                        ": \"${XDG_DATA_DIRS:=/run/current-system/profile/share}\"
"
                        ": \"${GI_TYPELIB_PATH:=/run/current-system/profile/lib/girepository-1.0}\"
"
                        ": \"${SSL_CERT_DIR:=/etc/ssl/certs}\"\n"
                        ": \"${SSL_CERT_FILE:=/etc/ssl/certs/ca-certificates.crt}\"
"
                        ": \"${GIT_SSL_CAINFO:=/etc/ssl/certs/ca-certificates.crt}\"
"
                        ": \"${CURL_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}\"
"
                        ": \"${XDG_CACHE_HOME:=/var/tmp/guix-cache-${USER:-user}}\"
"
                        "mkdir -p \"$XDG_RUNTIME_DIR\"\n"
                        "chmod 700 \"$XDG_RUNTIME_DIR\"\n"
                        ": \"${DBUS_SESSION_BUS_ADDRESS:=unix:path=$XDG_RUNTIME_DIR/bus}\"
"
                        "if [ ! -S \"$XDG_RUNTIME_DIR/bus\" ]; then
"
                        "    dbus-daemon --session --address=\"$DBUS_SESSION_BUS_ADDRESS\" --fork --nopidfile
"
                        "fi\n"
                        "PATH=\"/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}\"
"
                        "export DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
"
                        "export XDG_CONFIG_DIRS XDG_DATA_DIRS GI_TYPELIB_PATH
"
                        "export SSL_CERT_DIR SSL_CERT_FILE GIT_SSL_CAINFO CURL_CA_BUNDLE XDG_CACHE_HOME PATH
")))
                    (unless (> matched 0)
                      (error "substitute* found no matches"
                             "qubes-gui-agent-linux:qubes-session")))
                  ;; upstream: qubes-gui-agent-linux qubes-session — the
                  ;; "dbus-update-activation-environment --systemd --all" call.
                  (let ((matched 0))
                    (substitute* qubes-session
                      (("dbus-update-activation-environment --systemd --all")
                       (set! matched
                             (+ matched 1))
                       "dbus-update-activation-environment --all || true"))
                    (unless (> matched 0)
                      (error "substitute* found no matches"
                             "qubes-gui-agent-linux:qubes-session")))))
              (let* ((python-site-packages
                      (lambda (package)
                        (let* ((python-lib (string-append package "/lib"))
                               (python-directory
                                (car (scandir python-lib
                                              (lambda (entry)
                                                (string-prefix? "python"
                                                                entry))))))
                          (string-append python-lib "/" python-directory
                                         "/site-packages"))))
                     (pythonpath (map python-site-packages
                                      (list #$python-xcffib
                                            #$python-cffi
                                            #$python-pycparser)))
                     (icon-sender (string-append #$output
                                                 "/lib/qubes/icon-sender")))
                (when (file-exists? icon-sender)
                  ;; upstream: qubes-gui-agent-linux icon-sender — the
                  ;; "import xcffib" statement.
                  (let ((matched 0))
                    (substitute* icon-sender
                      (("import xcffib")
                       (set! matched
                             (+ matched 1))
                       (string-append "import sys\n" "sys.path[:0] = ['"
                                      (string-join pythonpath "', '") "']\n"
                                      "import xcffib")))
                    (unless (> matched 0)
                      (error "substitute* found no matches"
                             "qubes-gui-agent-linux:icon-sender")))))
              ;; Upstream installs these Qubes RPC entries as FHS-relative
              ;; symlinks into /usr/bin.  After normalizing /usr/bin into the
              ;; Guix profile's /bin, keep the qrexec services executable.
              (for-each (lambda (entry)
                          (let ((link (string-append #$output
                                                     "/etc/qubes-rpc/"
                                                     (car entry))))
                            (false-if-exception (delete-file link))
                            (symlink (string-append "../../bin/"
                                                    (cdr entry)) link)))
                        '(("qubes.SetMonitorLayout" . "qubes-set-monitor-layout")
                          ("qubes.GuiVMSession" . "qubes-start-xephyr")))
              (when (file-exists? (string-append #$output "/usr"))
                (delete-file-recursively (string-append #$output "/usr")))))
          (add-after 'install 'set-xorg-driver-runpath
            (lambda _
              (for-each (lambda (driver)
                          (invoke "patchelf" "--add-rpath"
                                  (string-append #$output "/lib")
                                  (string-append #$output
                                                 "/lib/xorg/modules/drivers/"
                                                 driver)))
                        '("qubes_drv.so" "dummyqbs_drv.so")))))))
    (native-inputs (list autoconf
                         automake
                         libtool
                         patchelf
                         pkg-config
                         xen))
    (inputs (list dbus
                  libunistring
                  libx11
                  libxcomposite
                  libxcursor
                  libxdamage
                  libxext
                  libxfixes
                  libxt
                  linux-pam
                  pixman
                  qubes-libvchan-xen
                  qubes-vm-gui-common
                  qubesdb-vm
                  xen-vchan-libs
                  xorg-server))
    (propagated-inputs (list python-cffi python-pycparser python-xcffib))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes GUI agent")
    (description "VM-side Qubes GUI agent for X11 application forwarding.")
    (license license:gpl2+)))

(define pipewire-qubes
  (package
    (name "pipewire-qubes")
    (version (qubes-release-version "qubes-gui-agent-linux"))
    (source
     (qubes-release-source "qubes-gui-agent-linux"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; Upstream has no standalone test target for this PipeWire module; its
      ;; validation is runtime audio behavior against a Qubes AudioVM.
      #:tests? #f
      #:modules '((guix build gnu-build-system)
                  (guix build utils))
      #:phases
      #~(modify-phases %standard-phases
          ;; The pipewire/ subdirectory ships a plain Makefile; the top-level
          ;; autotools bootstrap and configure are only for the GUI agent.
          (delete 'bootstrap)
          (delete 'configure)
          (replace 'build
            (lambda _
              ;; The upstream Makefile resolves PipeWire, SPA, and vchan flags
              ;; through pkg-config (libpipewire-0.3, vchan-xen) and links
              ;; -lqubesdb directly.  Provide explicit include and library
              ;; search paths so the module finds spa/pipewire/vchan headers
              ;; and the QubesDB client library, with RUNPATH entries so the
              ;; loaded module resolves them at runtime from the profile.
              (setenv "CPPFLAGS"
                      (string-append "-I"
                                     #$pipewire
                                     "/include/pipewire-0.3 "
                                     "-I"
                                     #$pipewire
                                     "/include/spa-0.2 "
                                     "-I"
                                     #$qubesdb-vm
                                     "/include "
                                     "-I"
                                     #$qubes-libvchan-xen
                                     "/include/vchan-xen"))
              (setenv "LDFLAGS"
                      (string-append "-L"
                                     #$qubesdb-vm
                                     "/lib "
                                     "-L"
                                     #$pipewire
                                     "/lib "
                                     "-L"
                                     #$qubes-libvchan-xen
                                     "/lib "
                                     "-Wl,-rpath="
                                     #$qubesdb-vm
                                     "/lib "
                                     "-Wl,-rpath="
                                     #$pipewire
                                     "/lib "
                                     "-Wl,-rpath="
                                     #$qubes-libvchan-xen
                                     "/lib"))
              (invoke "make" "-C" "pipewire" "qubes-pw-module.so" "CC=gcc")))
          (replace 'install
            (lambda _
              ;; Install only what a Shepherd-managed Guix template needs: the
              ;; PipeWire module, the config drop-in that loads it, and an XDG
              ;; autostart launcher.  The upstream systemd user-preset and
              ;; user-unit drop-in are systemd-specific; this template has no
              ;; systemd --user, so it starts PipeWire and WirePlumber from the
              ;; per-user GUI session through the same XDG autostart mechanism
              ;; the GUI agent already uses for qrexec-fork-server.  Keeping the
              ;; launcher here, rather than editing qubes-vm-gui, avoids
              ;; rebuilding the GUI agent and keeps audio self-contained.  Both
              ;; PipeWire and this module install under the same profile
              ;; subdirectories, so PipeWire's default config search merges the
              ;; drop-in and finds libpipewire-module-qubes by name.
              (let* ((modules (string-append #$output "/lib/pipewire-0.3"))
                     (confd (string-append #$output
                                           "/share/pipewire/pipewire.conf.d"))
                     (autostart (string-append #$output "/etc/xdg/autostart"))
                     (bin (string-append #$output "/bin"))
                     (launcher (string-append bin "/qubes-pipewire-start"))
                     (license-dir (string-append #$output
                                   "/share/licenses/pipewire-qubes")))
                (install-file "pipewire/qubes-pw-module.so" modules)
                (rename-file (string-append modules "/qubes-pw-module.so")
                             (string-append modules
                                            "/libpipewire-module-qubes.so"))
                (chmod (string-append modules "/libpipewire-module-qubes.so")
                       #o755)
                (install-file "pipewire/30_qubes.conf" confd)
                (chmod (string-append confd "/30_qubes.conf") #o644)
                (install-file "pipewire/COPYING" license-dir)
                (chmod (string-append license-dir "/COPYING") #o644)

                ;; Session launcher: start PipeWire (+ its PulseAudio-API shim)
                ;; and WirePlumber once per GUI session, after qubes-session has
                ;; set up XDG_RUNTIME_DIR and the session D-Bus.  PipeWire loads
                ;; the bundled 30_qubes.conf drop-in from the profile and
                ;; connects to the Qubes AudioVM over vchan.
                (mkdir-p bin)
                (call-with-output-file launcher
                  (lambda (port)
                    (format port
                     "#!~a
# SPDX-License-Identifier: GPL-2.0-or-later
# Start PipeWire and WirePlumber for Qubes audio in the GUI user session.
set -e
profile=/run/current-system/profile
export PIPEWIRE_MODULE_DIR=\"$profile/lib/pipewire-0.3\"
export SPA_PLUGIN_DIR=\"$profile/lib/spa-0.2\"
if [ -d \"$profile/share/pipewire/pipewire.conf.d\" ]; then
    export PIPEWIRE_CONFIG_DIR=\"$profile/share/pipewire\"
fi
# Only one PipeWire instance per session.
if [ -n \"$XDG_RUNTIME_DIR\" ] && [ -S \"$XDG_RUNTIME_DIR/pipewire-0\" ]; then
    exit 0
fi
\"$profile/bin/pipewire\" &
\"$profile/bin/pipewire-pulse\" &
\"$profile/bin/wireplumber\" &
exit 0
"
                     #$(file-append bash-minimal "/bin/sh"))))
                (chmod launcher #o755)
                (mkdir-p autostart)
                (call-with-output-file (string-append autostart
                                        "/qubes-pipewire.desktop")
                  (lambda (port)
                    (display
                     "[Desktop Entry]
Name=Qubes Audio (PipeWire)
Comment=Start PipeWire and WirePlumber for Qubes audio
Exec=/usr/bin/qubes-pipewire-start
Terminal=false
Type=Application
OnlyShowIn=X-QUBES;
X-GNOME-Autostart-Phase=Initialization
"
                     port)))
                (chmod (string-append autostart "/qubes-pipewire.desktop")
                       #o644)))))))
    (native-inputs (list pkg-config))
    (inputs (list bash-minimal pipewire qubes-libvchan-xen qubesdb-vm))
    (home-page "https://www.qubes-os.org/")
    (synopsis "PipeWire module for Qubes VM audio")
    (description
     "PipeWire module that enables sound support in Qubes VMs.  It
connects the VM-side PipeWire daemon to the Qubes AudioVM over vchan, providing
the playback sink and recording source that Qubes audio uses.  This is the
PipeWire equivalent of the older PulseAudio Qubes module.")
    (license license:gpl2+)))

(define %qubes-vm-headless-packages
  (list qubes-libvchan-xen
        qubes-vm-utils
        qubesdb-vm
        qubes-vm-qrexec
        qubes-vm-core
        xen-network-hotplug-tools))

(define %qubes-vm-gui-packages
  (append %qubes-vm-headless-packages
          (list qubes-vm-gui-common qubes-vm-gui)))

(define xterm-desktop-entry
  (package
    (name "xterm-desktop-entry")
    (version (package-version xterm))
    (source
     #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((applications (string-append #$output "/share/applications")))
            (mkdir-p applications)
            (call-with-output-file (string-append applications
                                                  "/xterm.desktop")
              (lambda (port)
                (display "[Desktop Entry]
Name=XTerm
Comment=Terminal emulator for the X Window System
Exec=xterm
Terminal=false
Type=Application
Icon=xterm-color_48x48
Categories=System;TerminalEmulator;
Keywords=shell;prompt;command;commandline;cmd;
StartupWMClass=XTerm
"
                         port)))))))
    (home-page (package-home-page xterm))
    (synopsis "Desktop entry for xterm")
    (description
     "Install a desktop entry for xterm when the distribution package does not provide one.")
    (license (package-license xterm))))

(define %qubes-common-packages
  (delete-duplicates (append %qubes-vm-gui-packages
                             %base-packages
                             ;; Note: do not add guile here.  The guix package below propagates
                             ;; its own guile, and listing a second guile (for example the
                             ;; standalone guile-3.0) makes the profile contain two conflicting
                             ;; guile entries.  guix's propagated guile provides
                             ;; /run/current-system/profile/bin/guile, which the Qubes runtime
                             ;; scripts (the ACPI poweroff helper and the generated qrexec
                             ;; helpers) rely on.
                             ;;
                             ;; glibc is added for getent, which Qubes' init/functions uses to
                             ;; enumerate accounts during private-volume home setup; python
                             ;; provides the python3 interpreter the Qubes qrexec/vmexec and
                             ;; agent helpers run with.  Neither is part of %base-packages.
                             (list acpid
                                   adwaita-icon-theme
                                   conntrack-tools
                                   curl
                                   dbus
                                   e2fsprogs
                                   font-alias
                                   font-misc-misc
                                   git
                                   glibc
                                   graphicsmagick
                                   guix
                                   hicolor-icon-theme
                                   inetutils
                                   iproute
                                   kmod
                                   librsvg
                                   nano
                                   nftables
                                   nss-certs
                                   python
                                   python-dbus
                                   python-pygobject
                                   python-pyxdg
                                   setxkbmap
                                   socat
                                   sudo
                                   tango-icon-theme
                                   xdpyinfo
                                   xev
                                   xinput
                                   xinit
                                   xmodmap
                                   xorg-server
                                   xprop
                                   xrandr
                                   xrdb
                                   xsetroot
                                   xterm
                                   xterm-desktop-entry
                                   xwininfo
                                   zenity
                                   zstd))))

(define %qubes-normal-desktop-packages
  ;; Keep the normal template intentionally small, but provide the basic
  ;; application classes Qubes desktop tests and users expect to discover:
  ;; terminal, file manager, text editor, and document viewer.
  (list evince mousepad thunar xfce4-terminal))

(define %qubes-normal-audio-packages
  ;; The non-minimal template provides Qubes audio.  PipeWire is the VM-side
  ;; audio daemon, WirePlumber is its session/policy manager, and
  ;; pipewire-qubes is the module that bridges PipeWire to the Qubes AudioVM
  ;; over vchan.  qubes-session starts pipewire and wireplumber in the per-user
  ;; GUI session, where PipeWire loads the bundled 30_qubes.conf drop-in.  The
  ;; minimal template, like Qubes' own minimal templates, ships without audio.
  (list pipewire wireplumber pipewire-qubes))

(define %qubes-normal-network-packages
  ;; The non-minimal template can act as a network provider (sys-net /
  ;; sys-firewall / a custom NetVM or ProxyVM), which needs dnsmasq to serve
  ;; DHCP and forward DNS to downstream qubes.  Qubes' own full templates ship
  ;; dnsmasq for exactly this role; the upstream network integration tests
  ;; (qubes.tests.integ.network) also require it in the template under test.
  ;; The minimal template, like Qubes' own minimal templates, omits it.
  (list dnsmasq))

(define (qubes-variant-packages variant)
  (case variant
    ((minimal)
     %qubes-common-packages)
    ((normal)
     (append %qubes-normal-desktop-packages %qubes-normal-audio-packages
             %qubes-normal-network-packages %qubes-common-packages))
    (else (error "unsupported Qubes Guix template variant" variant))))
