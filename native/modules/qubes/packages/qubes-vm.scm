;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (qubes packages qubes-vm)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages haskell-xyz)
  #:use-module (gnu packages icu4c)
  #:use-module (gnu packages image)
  #:use-module (gnu packages libunistring)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages pulseaudio)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages xdisorg)
  #:use-module (gnu packages xorg)
  #:export (qubes-dom0-kernel
            xen-vchan-libs
            qubes-libvchan-xen
            qubes-linux-utils-qrexec
            qubes-vm-utils
            qubesdb-vm
            qubes-vm-qrexec
            qubes-vm-core
            qubes-vm-gui-common
            qubes-vm-gui
            qubes-xterm-desktop-entry
            %qubes-vm-headless-packages
            %qubes-vm-gui-packages))

(define %qubes-source-components
  '(("qubes-core-vchan-xen" "v4.2.8"
     "a1337c282ffefcfc13a570683c57bc04813038db"
     "0nb5ky69w0v6xy7dkriagyi8fa2zpq2dnibr90pkf7asi0cib77j")
    ("qubes-linux-utils" "v4.3.17"
     "ee1e61f487f57d6b5d3ff96dbd8d6b50bd474656"
     "19q2i9gz4v585gw9mpmn1pw1zmykr3awg30rzm4vbfnv5i0czh56")
    ("qubes-core-qubesdb" "v4.3.2"
     "7d294b2ab922708b552fb2715f6a0333fbc52fcd"
     "1kal2lf4frjk083qd0ql5m8znbzn77pndxhclkl0pbc7v5ycrfyd")
    ("qubes-core-qrexec" "v4.3.12"
     "cc801b8f630a65dfb2855b829bfc070f6e82f26a"
     "1lbz435sjs3d7pc9ymnwxqi14sc83xdnny5pzwp8c580rraysvd4")
    ("qubes-core-agent-linux" "v4.3.42"
     "37dd9cd76aa74669b80b849a650f35b982d922ec"
     "13xsvgrdq3ihr0ryf4js03cyb4hns9i496m5bhbrfiwqcxyv3g41")
    ("qubes-gui-common" "v4.3.1"
     "66b879e36d6cd2a01271fc8d4c2c0f3be85d0029"
     "1ilr2wximl82y05f9dha69pjwhks2c73cfh08yxpnbdg5yspcc24")
    ("qubes-gui-agent-linux" "v4.3.16"
     "bd8c395df20e64845ac4b3324552aebca32fea96"
     "1pp5s1ghg9hha9rlc7v3lscbvpfyhl9zpjknci9nq5h1630a8hck")))

(define (qubes-source-field component index)
  (let ((entry (assoc component %qubes-source-components)))
    (unless entry
      (error "unknown Qubes source component" component))
    (list-ref entry index)))

(define (qubes-release-version component)
  (let ((tag (qubes-source-field component 1)))
    (if (and (> (string-length tag) 0)
             (char=? (string-ref tag 0) #\v))
        (substring tag 1)
        tag)))

(define (qubes-release-source component)
  (origin
    (method git-fetch)
    (uri (git-reference
          (url (string-append "https://github.com/QubesOS/" component ".git"))
          (commit (qubes-source-field component 2))))
    (file-name (string-append component "-" (qubes-source-field component 1)
                              "-checkout"))
    (sha256 (base32 (qubes-source-field component 3)))))

(define-public qubes-dom0-kernel
  (package
    (name "qubes-dom0-kernel")
    (version "0")
    (source #f)
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
    (description "Placeholder kernel package used by native Qubes TemplateVM
images.  Qubes dom0 supplies the actual VM kernel at boot time, so the template
root image does not need a guest kernel package.")
    (license license:gpl2+)))

(define-public xen-vchan-libs
  (package
    (name "xen-vchan-libs")
    (version (package-version xen))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils) (ice-9 ftw) (ice-9 popen)
                  (ice-9 rdelim) (ice-9 regex))
      #:builder
      #~(begin
          (use-modules (guix build utils)
                       (ice-9 ftw)
                       (ice-9 popen)
                       (ice-9 rdelim)
                       (ice-9 regex))

          (define prefixes
            '("libxenvchan" "libxenctrl" "libxenstore" "libxentoollog"
              "libxengnttab" "libxenevtchn" "libxencall"
              "libxenforeignmemory" "libxendevicemodel" "libxentoolcore"))

          (define (string-prefix? prefix value)
            (let ((prefix-length (string-length prefix)))
              (and (>= (string-length value) prefix-length)
                   (string=? prefix (substring value 0 prefix-length)))))

          (define (wanted-library? entry)
            (and (string-match "\\.so" entry)
                 (let loop ((prefixes prefixes))
                   (and (pair? prefixes)
                        (or (string-prefix? (car prefixes) entry)
                            (loop (cdr prefixes)))))))

          (define (copy-entry source destination)
            (let ((stat (lstat source)))
              (case (stat:type stat)
                ((symlink) (symlink (readlink source) destination))
                ((regular) (copy-file source destination)))))

          (define (command-line-output . args)
            (let* ((port (apply open-pipe* OPEN_READ args))
                   (line (read-line port)))
              (close-pipe port)
              (if (eof-object? line) "" line)))

          (define (replace-substring value needle replacement)
            (let ((needle-length (string-length needle)))
              (let loop ((start 0) (pieces '()))
                (let ((index (string-contains value needle start)))
                  (if index
                      (loop (+ index needle-length)
                            (cons replacement
                                  (cons (substring value start index) pieces)))
                      (apply string-append
                             (reverse
                              (cons (substring value start) pieces))))))))

          (let ((source-lib (string-append #$xen "/lib"))
                (out-lib (string-append #$output "/lib"))
                (patchelf (string-append #$patchelf "/bin/patchelf")))
            (mkdir-p out-lib)
            (for-each
             (lambda (entry)
               (when (wanted-library? entry)
                 (copy-entry (string-append source-lib "/" entry)
                             (string-append out-lib "/" entry))))
             (scandir source-lib))
            ;; Guix's Xen libraries carry an RPATH back to the full Xen output,
            ;; which would retain Xen tools, QEMU, firmware, and OVMF in the
            ;; template.  Rewrite copied shared objects to resolve within this
            ;; tiny library subset while preserving libc/libgcc paths.
            (for-each
             (lambda (entry)
               (let ((file (string-append out-lib "/" entry)))
                 (when (and (wanted-library? entry)
                            (eq? (stat:type (lstat file)) 'regular))
                   (let* ((rpath (command-line-output
                                  patchelf "--print-rpath" file))
                          (new-rpath
                           (replace-substring rpath source-lib out-lib)))
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
    (description "Runtime subset of Xen libraries needed by the Qubes VM-side
vchan and qrexec components, without Xen hypervisor tools, QEMU, or firmware.")
    (license license:gpl2+)))

(define-public qubes-libvchan-xen
  (package
    (name "qubes-libvchan-xen")
    (version (qubes-release-version "qubes-core-vchan-xen"))
    (source (qubes-release-source "qubes-core-vchan-xen"))
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
              (invoke "make" "all"
                      "CC=gcc"
                      (string-append "PREFIX=" #$output)
                      (string-append "LIBDIR=" #$output "/lib")
                      (string-append "INCLUDEDIR=" #$output "/include")
                      (string-append "LDFLAGS=-L" #$xen-vchan-libs "/lib "
                                     "-Wl,-rpath=" #$xen-vchan-libs "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "install"
                      "DESTDIR="
                      (string-append "PREFIX=" #$output)
                      (string-append "LIBDIR=" #$output "/lib")
                      (string-append "INCLUDEDIR=" #$output "/include")))))))
    (native-inputs (list pkg-config xen))
    ;; Guix package name may need adjustment depending on the Guix channel.
    (inputs (list xen-vchan-libs))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes Xen vchan library")
    (description "VM-side Xen vchan support used by Qubes agents.")
    (license license:gpl2+)))

(define-public qubes-linux-utils-qrexec
  (package
    (name "qubes-linux-utils-qrexec")
    (version (qubes-release-version "qubes-linux-utils"))
    (source (qubes-release-source "qubes-linux-utils"))
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
              (invoke "make" "-C" "qrexec-lib" "all"
                      "CC=gcc"
                      "NO_REBUILD_TABLE=1"
                      (string-append
                       "LDFLAGS=-Wl,--no-undefined,--as-needed,-Bsymbolic -L . -Wl,-rpath="
                       #$output "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "-C" "qrexec-lib" "install"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "INCLUDEDIR=/include"))))))
    (native-inputs (list pkg-config))
    (inputs (list icu4c))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes qrexec file-copy support libraries")
    (description "Qubes RPC file-copy and pure utility libraries used by VM-side agents.")
    (license license:gpl2+)))

(define-public qubes-vm-utils
  (package
    (name "qubes-vm-utils")
    (version (qubes-release-version "qubes-linux-utils"))
    (source (qubes-release-source "qubes-linux-utils"))
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
              (invoke "make" "-C" "qmemman" "all"
                      "CC=gcc"
                      (string-append "CFLAGS=-Wall -Wextra -Werror -g -O3 "
                                     "-DUSE_XENSTORE_H -I" #$xen "/include")
                      (string-append "LDFLAGS=-L" #$xen "/lib "
                                     "-Wl,-rpath=" #$xen "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "-C" "qmemman" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin"))))))
    (inputs (list xen))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes VM utility programs")
    (description "VM-side Qubes utility programs, including the memory
information reporter used by Qubes memory ballooning.")
    (license license:gpl2+)))

(define-public qubesdb-vm
  (package
    (name "qubesdb-vm")
    (version (qubes-release-version "qubes-core-qubesdb"))
    (source (qubes-release-source "qubes-core-qubesdb"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The daemon tests expect a live QubesDB/Xen VM environment; this
      ;; package build installs the VM-side daemon, tools, and bindings.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'run-vm-daemon-in-foreground
            (lambda _
              ;; Shepherd tracks the process it starts.  The upstream daemon
              ;; forks when built without systemd support, which leaves
              ;; duplicate VM-side QubesDB daemons racing for the same vchan.
              (substitute* "daemon/db-daemon.c"
                (("    if \\(1\\) \\{")
                 "    if (0) {"))))
          (replace 'build
            (lambda _
              (let ((rpath (string-append "-Wl,-rpath=" #$output "/lib")))
                (invoke "make" "all" "SYSTEMD=0" "CC=gcc"
                        (string-append "LDFLAGS=" rpath)
                        (string-append "APPEND_LDFLAGS=" rpath)))))
          (replace 'install
            (lambda _
              (invoke "make" "-C" "daemon" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin")
              (invoke "make" "-C" "client" "install"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "BINDIR=/bin")
              (setenv "QUBESDB_OUTPUT" #$output)
              (invoke "python3" "-c"
                      "import glob, os, shutil, sys
out = os.environ['QUBESDB_OUTPUT']
site = os.path.join(out, 'lib', f'python{sys.version_info.major}.{sys.version_info.minor}', 'site-packages')
os.makedirs(site, exist_ok=True)
extensions = glob.glob('python/build/lib*/qubesdb*.so')
assert extensions, 'no built qubesdb Python extension found'
for extension in extensions:
    shutil.copy2(extension, site)")
              (invoke "make" "-C" "include" "install"
                      (string-append "DESTDIR=" #$output)
                      "INCLUDEDIR=/include"))))))
    (native-inputs (list pkg-config python-wrapper))
    (inputs (list qubes-libvchan-xen))
    (home-page "https://www.qubes-os.org/")
    (synopsis "QubesDB VM daemon and client tools")
    (description "QubesDB VM-side daemon, command-line client, and Python bindings.")
    (license license:gpl2+)))

(define-public qubes-vm-qrexec
  (package
    (name "qubes-vm-qrexec")
    (version (qubes-release-version "qubes-core-qrexec"))
    (source (qubes-release-source "qubes-core-qrexec"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; Upstream tests exercise live qrexec/Xen service behavior; this package
      ;; build only installs the VM-side agent and helper programs.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'support-guix-login-shell-paths
            (lambda _
              ;; The qrexec-agent environment buffer needs to hold Guix store
              ;; paths such as /gnu/store/...-bash-minimal/bin/bash.
              (substitute* "agent/qrexec-agent.c"
                (("    char env_buf\\[64\\];")
                 "    char env_buf[PATH_MAX];"))))
          (replace 'build
            (lambda _
              (invoke "make" "all-base" "PANDOC=true" "CC=gcc")
              ;; qrexec-agent switches QUBESRPC calls to the requested user and
              ;; exports HOME/USER/LOGNAME only in its PAM-enabled code path.
              ;; The upstream Makefile detects PAM through /usr/include, which
              ;; is not meaningful inside a Guix build container, so select PAM
              ;; with the upstream make variable when linux-pam is an input.
              (invoke "make" "all-vm" "PANDOC=true" "CC=gcc"
                      "HAVE_PAM_APPL=1"
                      (string-append "LDFLAGS=-pie -Wl,-z,relro,-z,now "
                                     "-L../libqrexec -Wl,-rpath="
                                     #$output "/lib"))))
          (replace 'install
            (lambda _
              (invoke "make" "install-base" "install-vm"
                      (string-append "DESTDIR=" #$output)
                      "HAVE_PAM_APPL=1"
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "UNITDIR=/lib/systemd/system")
              ;; Upstream qubes.WaitForSession assumes systemd --user is
              ;; available after qrexec-fork-server appears.  Native Guix
              ;; templates use Shepherd, so keep the same qrexec-fork-server
              ;; readiness boundary and omit the systemd-only final check.
              (call-with-output-file (string-append #$output
                                                    "/etc/qubes-rpc/qubes.WaitForSession")
                (lambda (port)
                  (display "#!/bin/sh
set -eu

if command -v qrexec-client >/dev/null 2>&1; then
    exit 0
fi

if test \"$(qubesdb-read --default=True /qubes-gui-enabled)\" != True; then
    exit 0
fi

user=\"$(qubesdb-read /default-user 2>/dev/null || echo user)\"
timeout=\"${QUBES_WAIT_FOR_SESSION_TIMEOUT:-300}\"
elapsed=0
socket=\"/var/run/qubes/qrexec-server.$user.sock\"

while test \"$elapsed\" -lt \"$timeout\"; do
    if test -S \"$socket\"; then
        exit 0
    fi
    elapsed=$((elapsed + 1))
    sleep 1
done

echo \"Timed out waiting for Guix Qubes session socket: $socket\" >&2
exit 1
" port)))
              (chmod (string-append #$output
                                     "/etc/qubes-rpc/qubes.WaitForSession")
                     #o755)
              (setenv "QUBES_QREXEC_OUTPUT" #$output)
              (setenv "QUBES_QREXEC_EXTRA_PYTHON_ROOTS" #$python-pyinotify)
              (invoke "python3" "-c"
                      "import os, pathlib, shutil, sys
out = pathlib.Path(os.environ['QUBES_QREXEC_OUTPUT'])
extra_roots = [pathlib.Path(root) for root in os.environ['QUBES_QREXEC_EXTRA_PYTHON_ROOTS'].split(':') if root]
site = out / 'lib' / f'python{sys.version_info.major}.{sys.version_info.minor}' / 'site-packages'
extra_pythonpath = [str(root / 'lib' / f'python{sys.version_info.major}.{sys.version_info.minor}' / 'site-packages') for root in extra_roots]
site.mkdir(parents=True, exist_ok=True)
for package in ('qrexec',):
    src = next((out / 'gnu').glob(f'store/*/lib/python*/site-packages/{package}'))
    shutil.copytree(src, site / package, dirs_exist_ok=True)
for src, dst in [('usr/bin', 'bin'), ('usr/lib/qubes', 'lib/qubes'),
                 ('usr/lib/tmpfiles.d', 'lib/tmpfiles.d'),
                 ('usr/include', 'include'), ('usr/share', 'share')]:
    src_path = out / src
    if src_path.exists():
        dst_path = out / dst
        dst_path.mkdir(parents=True, exist_ok=True)
        for item in src_path.iterdir():
            target = dst_path / item.name
            if target.exists() or target.is_symlink():
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            shutil.move(str(item), str(target))
for script in (out / 'bin').iterdir():
    if not script.is_file() or script.is_symlink():
        continue
    try:
        text = script.read_text()
    except UnicodeDecodeError:
        continue
    if text.startswith('#!/usr/bin/python3') and 'from qrexec.' in text:
        pythonpath = [str(site)] + extra_pythonpath
        text = text.replace('\\nfrom qrexec.', f'\\nimport sys\\nsys.path[:0] = {pythonpath!r}\\nfrom qrexec.', 1)
        script.write_text(text)
shutil.rmtree(out / 'gnu', ignore_errors=True)
shutil.rmtree(out / 'usr', ignore_errors=True)"))))))
    (native-inputs (list pkg-config gzip))
    (inputs (list bash-minimal linux-pam python-pyinotify qubes-libvchan-xen
                  python-wrapper))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes qrexec VM agent")
    (description "VM-side qrexec agent and client tools for Qubes RPC.")
    (license license:gpl2+)))

(define-public qubes-vm-core
  (package
    (name "qubes-vm-core")
    (version (qubes-release-version "qubes-core-agent-linux"))
    (source (qubes-release-source "qubes-core-agent-linux"))
    (build-system gnu-build-system)
    (arguments
     (list
      ;; The agent-linux tree is mostly VM filesystem, init, and hook
      ;; integration; its validation is integration-level in a Qubes TemplateVM.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'dereference-guix-skel-in-home-init
            (lambda _
              ;; Guix exposes /etc/skel as a generated symlink to a store
              ;; directory.  Qubes' home initializer uses cp -a -T, which would
              ;; otherwise preserve that top-level symlink as the user's home.
              (substitute* "init/functions"
                (("cp \"-af\\$enable_selinux\" -T /etc/skel \"\\$home_root/\\$homedirwithouthome\"")
                 "skel_source=$(readlink -f /etc/skel || echo /etc/skel)\n            cp \"-af$enable_selinux\" -T \"$skel_source\" \"$home_root/$homedirwithouthome\""))))
          (replace 'build
            (lambda _
              (invoke "make" "-C" "qubes-rpc"
                      (string-append
                       "VERSION="
                       #$(qubes-release-version "qubes-core-agent-linux"))
                      "CC=gcc"
                      "release=Guix"
                      (string-append "LDFLAGS=-pie -Wl,-rpath="
                                     #$qubes-linux-utils-qrexec "/lib"))
              (invoke "make" "-C" "misc"
                      (string-append
                       "VERSION="
                       #$(qubes-release-version "qubes-core-agent-linux"))
                      "CC=gcc"
                      "release=Guix")))
          (replace 'install
            (lambda _
              (invoke "make" "install-corevm"
                      (string-append "DESTDIR=" #$output)
                      "SBINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSLIBDIR=/lib"
                      "SYSTEM_DROPIN_DIR=/lib/systemd/system"
                      "USER_DROPIN_DIR=/lib/systemd/user"
                      "PYTHON=python3"
                      "DIST=guix"
                      "release=Guix")
              (invoke "make" "-C" "qubes-rpc" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc")
              (invoke "make" "-C" "network" "install"
                      (string-append "DESTDIR=" #$output)
                      "BINDIR=/bin"
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc")
              ;; install-corevm intentionally skips packaging-specific payloads
              ;; that RPM/Debian specs install separately.  The post-install
              ;; qrexec hooks need these helpers to report supported features,
              ;; sync application menus, and expose /usr/share/qubes/marker-vm.
              (mkdir-p (string-append #$output "/usr/share/applications"))
              (invoke "make" "-C" "misc" "install"
                      (string-append "DESTDIR=" #$output))
              (invoke "make" "-C" "app-menu" "install"
                      (string-append "DESTDIR=" #$output))
              (invoke "make" "-C" "filesystem" "install"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "SYSCONFDIR=/etc"
                      "STATEDIR=/var/lib")
              (setenv "QUBES_VM_CORE_OUTPUT" #$output)
              (setenv "QUBES_VM_CORE_EXTRA_PYTHON_ROOTS"
                      (string-join (list #$qubesdb-vm #$python-pygobject
                                         #$python-pyxdg)
                                   ":"))
              (invoke "python3" "-c"
                      "import os, shutil, sys
out = os.environ['QUBES_VM_CORE_OUTPUT']
extra_roots = [root for root in os.environ['QUBES_VM_CORE_EXTRA_PYTHON_ROOTS'].split(':') if root]
site = os.path.join(out, 'lib', f'python{sys.version_info.major}.{sys.version_info.minor}', 'site-packages')
extra_pythonpath = [os.path.join(root, 'lib', f'python{sys.version_info.major}.{sys.version_info.minor}', 'site-packages') for root in extra_roots]
def merge_tree(source, destination):
    if not os.path.exists(source):
        return
    os.makedirs(destination, exist_ok=True)
    for name in os.listdir(source):
        from_path = os.path.join(source, name)
        to_path = os.path.join(destination, name)
        if os.path.isdir(from_path) and not os.path.islink(from_path) and os.path.isdir(to_path) and not os.path.islink(to_path):
            merge_tree(from_path, to_path)
            os.rmdir(from_path)
        else:
            if os.path.lexists(to_path):
                if os.path.isdir(to_path) and not os.path.islink(to_path):
                    shutil.rmtree(to_path)
                else:
                    os.unlink(to_path)
            os.rename(from_path, to_path)
for source, destination in [('usr/bin', 'bin'), ('usr/lib', 'lib'), ('usr/share', 'share')]:
    merge_tree(os.path.join(out, source), os.path.join(out, destination))
shutil.rmtree(os.path.join(out, 'usr'), ignore_errors=True)
os.makedirs(site, exist_ok=True)
shutil.copytree('build/lib/qubesagent', os.path.join(site, 'qubesagent'), dirs_exist_ok=True)
bindir = os.path.join(out, 'bin')
os.makedirs(bindir, exist_ok=True)
postinstall = os.path.join(out, 'etc', 'qubes-rpc', 'qubes.PostInstall')
if os.path.exists(postinstall):
    text = open(postinstall).read()
    # Qubes RPC services do not necessarily run through a login shell.  Give
    # post-install hooks the profile-visible commands used by the Guix VM.
    text = text.replace(
        '''

for script in /etc/qubes/post-install.d/*.sh; do
''',
        '''

export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin${PATH:+:$PATH}

for script in /etc/qubes/post-install.d/*.sh; do
''')
    open(postinstall, 'w').write(text)
postinstall_config = os.path.join(out, 'etc', 'qubes', 'rpc-config',
                                  'qubes.PostInstall')
os.makedirs(os.path.dirname(postinstall_config), exist_ok=True)
with open(postinstall_config, 'w') as config:
    # The post-install hooks update root-owned template state and may perform
    # privileged maintenance such as fstrim.  Match the root execution expected
    # by Qubes integration tests.
    config.write(\"force-user = 'root'\\n\")
updates_proxy_forwarder = os.path.join(out, 'lib', 'qubes',
                                       'guix-updates-proxy-forwarder')
with open(updates_proxy_forwarder, 'w') as script:
    script.write('''#!/bin/sh
exec qrexec-client-vm --use-stdin-socket '' qubes.UpdatesProxy
''')
os.chmod(updates_proxy_forwarder, 0o755)
features_hook = os.path.join(out, 'etc', 'qubes', 'post-install.d',
                             '10-qubes-core-agent-features.sh')
if os.path.exists(features_hook):
    text = open(features_hook).read()
    if 'supported-service.meminfo-writer=1' not in text:
        raise SystemExit('Qubes features hook no longer advertises meminfo-writer')
    text = text.replace(
        '''advertise_systemd_service() {
    qsrv=$1
    shift
    for unit in \"$@\"; do
        if systemctl -q is-enabled \"$unit\" 2>/dev/null; then
            qvm-features-request supported-service.\"$qsrv\"=1
        fi
    done
}
''',
        '''advertise_systemd_service() {
    qsrv=$1
    shift
    if ! command -v systemctl >/dev/null 2>&1; then
        case \"$qsrv\" in
            updates-proxy-setup)
                qvm-features-request supported-service.\"$qsrv\"=1
                ;;
        esac
        return
    fi
    for unit in \"$@\"; do
        if systemctl -q is-enabled \"$unit\" 2>/dev/null; then
            qvm-features-request supported-service.\"$qsrv\"=1
        fi
    done
}
''')
    open(features_hook, 'w').write(text)
features_request = os.path.join(bindir, 'qvm-features-request')
if os.path.exists(features_request):
    text = open(features_request).read()
    pythonpath = [site] + extra_pythonpath
    text = text.replace(
        '''import argparse
''',
        f'''import sys
sys.path[:0] = {pythonpath!r}

import argparse
''',
        1)
    # Native Guix templates use Shepherd, not systemd.  The post-install RPC
    # itself proves qrexec-agent is active, so preserve feature reporting when
    # systemctl is absent.
    text = text.replace(
        '''def is_active(service):
    status = subprocess.call([\"systemctl\", \"is-active\", \"--quiet\", service])
    return status == 0
''',
        '''def is_active(service):
    try:
        status = subprocess.call([\"systemctl\", \"is-active\", \"--quiet\", service])
    except FileNotFoundError:
        return service == \"qubes-qrexec-agent\"
    return status == 0
''')
    open(features_request, 'w').write(text)
session_autostart = os.path.join(bindir, 'qubes-session-autostart')
if os.path.exists(session_autostart):
    text = open(session_autostart).read()
    pythonpath = [site] + extra_pythonpath
    text = text.replace(
        '''import sys
''',
        f'''import sys
sys.path[:0] = {pythonpath!r}
''',
        1)
    open(session_autostart, 'w').write(text)
for name, module in [('qubes-firewall', 'qubesagent.firewall'), ('qubes-vmexec', 'qubesagent.vmexec')]:
    with open(os.path.join(bindir, name), 'w') as script:
        pythonpath = [site] + extra_pythonpath
        script.write(f'''#!/usr/bin/env python3
import sys
sys.path[:0] = {pythonpath!r}
from {module} import main
if __name__ == '__main__':
    raise SystemExit(main())
''')
    os.chmod(os.path.join(bindir, name), 0o755)
shutil.rmtree(os.path.join(out, 'gnu'), ignore_errors=True)
for stale in ('qubes-firewall', 'qubes-vmexec'):
    try:
        os.remove(os.path.join(out, 'usr', 'bin', stale))
    except FileNotFoundError:
        pass"))))))
    (native-inputs (list desktop-file-utils pandoc pkg-config python-wrapper
                         shared-mime-info))
    (inputs (list bash-minimal coreutils gawk grep iproute procps sed
                  python-pygobject python-pyxdg
                  qubes-linux-utils-qrexec
                  qubesdb-vm qubes-vm-qrexec socat))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes Linux VM core scripts")
    (description "Core VM-side Qubes scripts, RPC services, and compatibility files.")
    (license license:gpl2+)))

(define-public qubes-vm-gui-common
  (package
    (name "qubes-vm-gui-common")
    (version (qubes-release-version "qubes-gui-common"))
    (source (qubes-release-source "qubes-gui-common"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("include" "include"))))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes GUI protocol headers")
    (description "Common Qubes GUI protocol headers.")
    (license license:gpl2+)))

(define-public qubes-vm-gui
  (package
    (name "qubes-vm-gui")
    (version (qubes-release-version "qubes-gui-agent-linux"))
    (source (qubes-release-source "qubes-gui-agent-linux"))
    (build-system gnu-build-system)
    (arguments
     (list
      #:modules '((guix build gnu-build-system)
                  (guix build utils)
                  (ice-9 ftw))
      ;; GUI agent tests require a running Qubes GUI/Xen display environment;
      ;; this package build installs the VM-side GUI agent and Xorg helpers.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (add-after 'unpack 'patch-generated-configure-invocation
            (lambda _
              ;; The Xorg driver helper scripts generate configure scripts
              ;; after Guix's shebang patching phase. Invoke those generated
              ;; scripts through the profile shell instead of relying on
              ;; /bin/sh inside the build container.
              (substitute* '("xf86-input-mfndev/autogen.sh"
                             "xf86-video-dummy/autogen.sh")
                (("\\$srcdir/configure")
                 "${CONFIG_SHELL:-sh} $srcdir/configure"))
              (substitute* "Makefile"
                (("&& \\./configure")
                 "&& ${CONFIG_SHELL:-sh} ./configure"))))
          (replace 'build
            (lambda _
              ;; Build the GUI/Xorg pieces needed for Qubes application
              ;; forwarding without pulling in the audio-specific
              ;; PulseAudio/PipeWire module targets.
              (let ((shell (which "sh")))
                (setenv "CONFIG_SHELL" shell)
                (setenv "SHELL" shell))
              (setenv "CPPFLAGS" (string-append "-I" #$xen "/include"))
              (setenv "LDFLAGS" (string-append "-L" #$xen-vchan-libs "/lib "
                                                "-Wl,-rpath="
                                                #$xen-vchan-libs "/lib"))
              (invoke "make"
                      "gui-agent/qubes-gui"
                      "gui-agent/qubes-gui-runuser"
                      "xf86-qubes-common/libxf86-qubes-common.so"
                      "CC=gcc")
              ;; The top-level Qubes Makefile invokes generated configure
              ;; scripts directly. Build these helpers explicitly so Guix can
              ;; run those generated scripts through CONFIG_SHELL.
              (for-each
               (lambda (directory)
                 (with-directory-excursion directory
                   (invoke (getenv "CONFIG_SHELL") "./autogen.sh"))
                 (invoke "make" "-C" directory "CC=gcc"))
               '("xf86-input-mfndev" "xf86-video-dummy"))))
          (replace 'install
            (lambda _
              (define (move-profile-tree source destination)
                (when (file-exists? source)
                  (mkdir-p destination)
                  (for-each
                   (lambda (entry)
                     (let ((from (string-append source "/" entry))
                           (to (string-append destination "/" entry)))
                       (when (file-exists? to)
                         (delete-file-recursively to))
                       (rename-file from to)))
                   (scandir source
                            (lambda (entry)
                              (not (member entry '("." ".."))))))))

              (invoke "make" "install-common" "install-systemd"
                      (string-append "DESTDIR=" #$output)
                      "LIBDIR=/lib"
                      "USRLIBDIR=/lib"
                      "SYSLIBDIR=/lib")
              ;; qrexec-fork-server daemonizes itself.  Keep upstream's XDG
              ;; autostart launcher as the single owner of that user-session
              ;; daemon instead of supervising it from Shepherd.
              (unless (file-exists?
                       (string-append #$output
                                      "/etc/xdg/autostart/qubes-qrexec-fork-server.desktop"))
                (error "missing qrexec-fork-server.desktop"))
              (install-file "appvm-scripts/etc/sysconfig/desktop"
                            (string-append #$output "/etc/sysconfig"))
              (for-each
               (lambda (script)
                 (install-file
                  script
                  (string-append #$output "/etc/X11/xinit/xinitrc.d")))
               '("appvm-scripts/etc/X11/xinit/xinitrc.d/20qt-x11-no-mitshm.sh"
                 "appvm-scripts/etc/X11/xinit/xinitrc.d/20qt-gnome-desktop-session-id.sh"
                 "appvm-scripts/etc/X11/xinit/xinitrc.d/50guivm-windows-prefix.sh"
                 "appvm-scripts/etc/X11/xinit/xinitrc.d/60xfce-desktop.sh"))
              ;; Keep the Arch-style distribution hook for profiles whose
              ;; xinitrc sources /etc/X11/xinit/xinitrc.d.
              (call-with-output-file
                  (string-append #$output
                                 "/etc/X11/xinit/xinitrc.d/z-qubes-session.sh")
                (lambda (port)
                  (display "#!/bin/sh
echo \"Starting qubes-session...\"
exec /usr/bin/qubes-session
" port)))
              (chmod (string-append #$output
                                     "/etc/X11/xinit/xinitrc.d/z-qubes-session.sh")
                     #o755)
              ;; The upstream non-GuiVM path starts xinit through
              ;; qubes-gui-runuser so Xorg itself runs as the default user.
              ;; In this Guix System image there is no distro Xorg wrapper or
              ;; logind setup granting an unprivileged user access to vt07, so
              ;; Xorg exits before the Qubes GUI socket appears.  Keep the
              ;; session side unprivileged, but let root own xinit/Xorg.
              ;; Guix xinit's default xinitrc sources its immutable store
              ;; xinitrc.d, not the profile hook above, so run qubes-session
              ;; directly.  The separate Shepherd qrexec fork-server service
              ;; waits for the display socket before exposing
              ;; qubes.WaitForSession.
              (substitute* (string-append #$output "/usr/bin/qubes-run-xorg")
                (("qubes-xorg-wrapper \\$DISPLAY_XORG -nolisten")
                 "qubes-xorg-wrapper $DISPLAY_XORG -modulepath /run/current-system/profile/lib/xorg/modules -nolisten")
                (("exec /usr/bin/qubes-gui-runuser \"\\$DEFAULT_USER\" /bin/sh -l -c \"exec /usr/bin/xinit \\$XSESSION -- /usr/lib/qubes/qubes-xorg-wrapper :0 -nolisten tcp vt07 -wr -config xorg-qubes.conf > ~/.xsession-errors 2>&1\"")
                 "exec /usr/bin/xinit /usr/bin/qubes-gui-runuser \"$DEFAULT_USER\" /bin/sh -l -c \"exec /usr/bin/qubes-session\" -- /usr/lib/qubes/qubes-xorg-wrapper :0 -modulepath /run/current-system/profile/lib/xorg/modules -nolisten tcp vt07 -wr -config xorg-qubes.conf -ac > \"/home/$DEFAULT_USER/.xsession-errors\" 2>&1"))
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
              ;; Upstream installs these Qubes RPC entries as FHS-relative
              ;; symlinks into /usr/bin.  After normalizing /usr/bin into the
              ;; Guix profile's /bin, keep the qrexec services executable.
              (for-each
               (lambda (entry)
                 (let ((link (string-append #$output "/etc/qubes-rpc/"
                                            (car entry))))
                   (false-if-exception (delete-file link))
                   (symlink (string-append "../../bin/" (cdr entry)) link)))
               '(("qubes.SetMonitorLayout" . "qubes-set-monitor-layout")
                 ("qubes.GuiVMSession" . "qubes-start-xephyr")))
              (when (file-exists? (string-append #$output "/usr"))
                (delete-file-recursively (string-append #$output "/usr")))))
          (add-after 'install 'set-xorg-driver-runpath
            (lambda _
              (for-each
               (lambda (driver)
                 (invoke "patchelf" "--add-rpath"
                         (string-append #$output "/lib")
                         (string-append #$output "/lib/xorg/modules/drivers/"
                                        driver)))
               '("qubes_drv.so" "dummyqbs_drv.so")))))))
    (native-inputs (list autoconf automake libtool patchelf pkg-config xen))
    (inputs (list dbus libunistring libx11 libxcomposite libxcursor
                  libxdamage libxext libxfixes libxt linux-pam pixman
                  qubes-libvchan-xen qubes-vm-gui-common qubesdb-vm
                  xen-vchan-libs xorg-server))
    (propagated-inputs (list python-xcffib))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Qubes GUI agent")
    (description "VM-side Qubes GUI agent for X11 application forwarding.")
    (license license:gpl2+)))

(define-public qubes-xterm-desktop-entry
  (package
    (name "qubes-xterm-desktop-entry")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder
      #~(begin
          (mkdir #$output)
          (mkdir (string-append #$output "/share"))
          (mkdir (string-append #$output "/share/applications"))
          (call-with-output-file
              (string-append #$output "/share/applications/xterm.desktop")
            (lambda (port)
              (display "[Desktop Entry]
Type=Application
Name=XTerm
Comment=Terminal emulator
Exec=xterm
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
" port))))))
    (home-page "https://www.qubes-os.org/")
    (synopsis "Desktop entry for xterm in the Qubes minimal Guix template")
    (description "Small desktop entry package that exposes xterm to Qubes
appmenu discovery in the minimal native GNU Guix System TemplateVM.")
    (license license:gpl3+)))

(define %qubes-vm-headless-packages
  (list qubes-libvchan-xen qubes-vm-utils qubesdb-vm qubes-vm-qrexec
        qubes-vm-core))

(define %qubes-vm-gui-packages
  (append %qubes-vm-headless-packages
          (list qubes-vm-gui-common qubes-vm-gui)))
