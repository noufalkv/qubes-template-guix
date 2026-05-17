;; SPDX-License-Identifier: GPL-3.0-or-later
(use-modules (gnu services)
             (gnu system)
             (gnu system accounts)
             (gnu system file-systems)
             (guix gexp)
             (ice-9 match)
             (qubes services qubes-vm)
             (qubes systems guix-template)
             (srfi srfi-1)
             (srfi srfi-26))

(define (fail format-string . args)
  (apply format (current-error-port) format-string args)
  (newline (current-error-port))
  (exit 1))

(define (assert condition format-string . args)
  (unless condition
    (apply fail format-string args)))

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

(define (check-system variant)
  (let* ((os (qubes-template-operating-system #:variant variant))
         (names (service-names os)))
    (assert (equal? (map swap-space-target
                         (operating-system-swap-devices os))
                    '("/dev/xvdc1"))
            "~a swap devices do not match standard Qubes /dev/xvdc1"
            variant)
    (assert (equal? (operating-system-privileged-programs os)
                    %default-privileged-programs)
            "~a does not preserve Guix default privileged programs"
            variant)
    (for-each (lambda (name)
                (assert (memq name names)
                        "~a missing required Qubes service: ~a"
                        variant name))
              '(qubes-db qubes-meminfo-writer qubes-qrexec-agent
                qubes-gui-agent qubes-guix-update-proxy))
    (check-sudoers variant os)
    (check-user-account variant os)
    (check-meminfo-writer variant os)))

(for-each check-system '(normal minimal))
(display "Guix system contract check passed")
(newline)
