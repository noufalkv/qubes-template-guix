;; SPDX-License-Identifier: GPL-3.0-or-later
(define-module (qubes systems guix-template)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages certs)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages package-management)
  #:use-module (gnu packages python)
  #:use-module (gnu packages xfce)
  #:use-module (gnu packages xorg)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services networking)
  #:use-module (gnu system nss)
  #:use-module (guix gexp)
  #:use-module (srfi srfi-1)
  #:use-module (qubes packages qubes-vm)
  #:use-module (qubes services qubes-vm)
  #:export (qubes-template-operating-system))

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
    virtual-terminal))

(define %qubes-base-services-with-lean-udev
  (modify-services %base-services
    (udev-service-type config =>
      (udev-configuration
       (inherit config)
       (rules '())))))

(define %qubes-minimal-base-services
  (filter (lambda (service)
            (not (memq (service-type-name (service-kind service))
                       %qubes-omitted-base-service-types)))
          %qubes-base-services-with-lean-udev))

(define %qubes-loopback-networking-services
  (list (service static-networking-service-type
                 (list %loopback-static-networking))))

(define* (qubes-dom0-kernel-bootloader-config _config _entries
                                              #:key
                                              #:allow-other-keys)
  (define (entry->gexp entry)
    (let ((label (menu-entry-label entry))
          (linux (menu-entry-linux entry))
          (initrd (menu-entry-initrd entry))
          (arguments (menu-entry-linux-arguments entry)))
      #~(begin
          ;; guix system init copies the closure of the bootloader config.  The
          ;; comments below deliberately reference the generated boot entry so
          ;; the native root image receives the full system closure even though
          ;; Qubes dom0 provides the actual VM kernel.
          (format port "# entry: ~a\n# linux: ~a\n# initrd: ~a\n# args:"
                  #$label #$linux #$initrd)
          (for-each (lambda (argument)
                      (format port " ~a" argument))
                    (list #$@arguments))
          (newline port))))

  (computed-file
   "qubes-dom0-kernel.cfg"
   #~(call-with-output-file #$output
       (lambda (port)
         (display "Qubes dom0 supplies the VM kernel; no guest bootloader is installed.\n"
                  port)
         #$@(map entry->gexp _entries)))
   #:options '(#:local-build? #t
               #:substitutable? #f)))

(define qubes-dom0-kernel-bootloader
  (bootloader
   (name 'qubes-dom0-kernel)
   ;; Keep this to an already-needed package so the bootloader record does not
   ;; pull GRUB, QEMU, or firmware into a template that never boots itself.
   (package bash-minimal)
   (installer #~(lambda (_bootloader _device _mount-point) #t))
   (configuration-file "/boot/qubes-dom0-kernel.cfg")
   (configuration-file-generator qubes-dom0-kernel-bootloader-config)))

(define %qubes-common-packages
  (append %qubes-vm-gui-packages
          (list acpid bash coreutils diffutils e2fsprogs findutils gawk
                glibc grep guile-3.0 guix gzip iproute kmod nss-certs procps
                python python-pygobject python-pyxdg sed setxkbmap shadow
                socat sudo tar util-linux
                xdpyinfo xev xinput xinit xmodmap xprop xrandr xrdb
                xsetroot xwininfo
                dbus xorg-server xterm)))

(define (qubes-variant-packages variant)
  (case variant
    ((minimal)
     (cons qubes-xterm-desktop-entry %qubes-common-packages))
    ((normal)
     (cons xfce4-terminal %qubes-common-packages))
    (else
     (error "unsupported Qubes Guix template variant" variant))))

(define* (qubes-template-operating-system #:key (variant 'normal))
  (operating-system
    (host-name (case variant
                 ((minimal) "guix-minimal-qubes")
                 (else "guix-qubes")))
    (timezone "Etc/UTC")
    (locale "en_US.utf8")

    ;; Qubes normally supplies the VM kernel from dom0. A bootloader is still
    ;; required by the Guix record, but build-native-rootfs.sh uses --no-bootloader.
    (bootloader
     (bootloader-configuration
      (bootloader qubes-dom0-kernel-bootloader)
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

    (privileged-programs %default-privileged-programs)
    (sudoers-file
     (plain-file "sudoers"
                 "root ALL=(ALL) ALL
%wheel ALL=(ALL) NOPASSWD:ALL
user ALL=(ALL) NOPASSWD:ALL
"))

    (services
     (append %qubes-loopback-networking-services
             (list (service dbus-root-service-type))
             %qubes-vm-gui-services
             %qubes-minimal-base-services))

    (name-service-switch %mdns-host-lookup-nss)))
