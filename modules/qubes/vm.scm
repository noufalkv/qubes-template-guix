;; SPDX-License-Identifier: GPL-3.0-or-later
;; Umbrella module re-exporting the split Qubes channel modules.

(define-module (qubes vm)
  #:use-module (qubes packages)
  #:use-module (qubes services)
  #:use-module (qubes system)
  #:re-export (qubes-release-version qubes-libvchan-xen
                                     qubes-linux-utils-qrexec
                                     qubes-vm-utils
                                     qubesdb-vm
                                     qubes-vm-qrexec
                                     qubes-vm-core
                                     qubes-vm-gui-common
                                     qubes-vm-gui
                                     pipewire-qubes
                                     qubes-dom0-kernel
                                     %qubes-vm-headless-packages
                                     %qubes-vm-gui-packages
                                     %qubes-normal-audio-packages
                                     %qubes-normal-desktop-packages
                                     %qubes-common-packages
                                     qubes-variant-packages
                                     %qubes-network-sysctl-settings
                                     %qubes-privileged-programs
                                     %qubes-system-services
                                     qubes-host-name
                                     qubes-operating-system
                                     xterm-desktop-entry))
