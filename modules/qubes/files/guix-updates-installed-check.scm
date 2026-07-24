;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Resolve the configured Guix channels with Guix itself, then compare the
;;; authenticated revisions with the revisions used for the running system.

(use-modules (guix channels)
             (guix scripts pull)
             (guix store)
             (ice-9 format)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (fail message . arguments)
  (apply format (current-error-port)
         (string-append "guix update check: " message "~%")
         arguments)
  (exit 1))

(define (hex-commit? value)
  (and (string? value)
       (= (string-length value) 40)
       (every (lambda (character)
                (or (char-numeric? character)
                    (memv character '(#\a #\b #\c #\d #\e #\f))))
              (string->list value))))

(define (channel-revision? revision)
  (match revision
    (((? symbol?) (? hex-commit?)) #t)
    (_ #f)))

(define (read-value file description)
  (unless (file-exists? file)
    (fail "~a is missing: ~a" description file))
  (call-with-input-file file
    (lambda (port)
      (let ((value (read port)))
        (unless (eof-object? (read port))
          (fail "~a has trailing data: ~a" description file))
        value))))

(define (validate-revisions revisions description file)
  (unless (and (list? revisions)
               (not (null? revisions))
               (every channel-revision? revisions))
    (fail "invalid ~a: ~a" description file))
  (let ((names (map car revisions)))
    (unless (= (length names) (length (delete-duplicates names eq?)))
      (fail "duplicate channel in ~a: ~a" description file)))
  revisions)

(define (read-applied-state file)
  (validate-revisions (read-value file "applied channel state")
                      "applied channel state"
                      file))

(define (read-cache file)
  (match (read-value file "successful update-check cache")
    (('guix-update-check-cache 1 (? string? channels-text) revisions)
     (list channels-text
           (validate-revisions revisions
                               "successful update-check cache"
                               file)))
    (_
     (fail "invalid successful update-check cache: ~a" file))))

(define (read-text file)
  (unless (file-exists? file)
    (fail "channels file is missing: ~a" file))
  (call-with-input-file file get-string-all))

(define (write-cache file channels-text revisions)
  (let ((temporary (string-append file ".tmp." (number->string (getpid)))))
    (catch #t
      (lambda ()
        (call-with-output-file temporary
          (lambda (port)
            (write `(guix-update-check-cache 1 ,channels-text ,revisions) port)
            (newline port)))
        (chmod temporary #o600)
        (rename-file temporary file))
      (lambda (key . arguments)
        (false-if-exception (delete-file temporary))
        (apply throw key arguments)))))

(define (revision->channel revision)
  (match revision
    ((name commit)
     (channel
      (name name)
      ;; latest-channel-instances only reads the name and commit from its
      ;; current-channels argument.  The configured channel supplies the URL,
      ;; branch, and authentication introduction used for the actual fetch.
      (url "file:///nonexistent/qubes-update-check-current-channel")
      (commit commit)))))

(define (instance->revision instance)
  (list (channel-name (channel-instance-channel instance))
        (channel-instance-commit instance)))

(define (sort-revisions revisions)
  (sort revisions
        (lambda (left right)
          (string<? (symbol->string (car left))
                    (symbol->string (car right))))))

(define (configured-channels file)
  ;; Match `guix pull -C FILE`: evaluate the local file in the restricted
  ;; channel environment and authenticate every channel that has an
  ;; introduction.  A local channel file may intentionally contain a trusted
  ;; development channel without one, which is the same warning policy used by
  ;; `guix pull -C`.
  (channel-list `((channel-file . ,file)
                  (isolated-channel-evaluation? . #t)
                  (require-trusted-channels . default))))

(define (resolve-latest channels applied)
  (with-store store
    (latest-channel-instances
     store channels
     #:current-channels (map revision->channel applied))))

(define (check-without-refresh applied channels-file cache-file)
  (match (read-cache cache-file)
    ((cached-channels-text cached-revisions)
     ;; A cache from a different channels file cannot safely clear a pending
     ;; notification.  Leave dom0's state unchanged until a full check succeeds.
     (unless (string=? cached-channels-text (read-text channels-file))
       (fail "channels changed since the last successful update check"))
     ;; Equality proves that the checked revisions were applied.  Inequality
     ;; alone cannot distinguish an older, partially updated generation from a
     ;; newer generation that was applied before the next periodic check.
     (unless (equal? (sort-revisions applied)
                     (sort-revisions cached-revisions))
       (fail "applied revisions differ from the last successful update check"))
     (display "true\n"))))

(define (check-with-refresh applied state-file channels-file cache-file)
  (let* ((channels-text (read-text channels-file))
         (channels (configured-channels channels-file))
         (resolved (resolve-latest channels applied))
         (old (sort-revisions applied))
         (new (sort-revisions (map instance->revision resolved))))
    ;; Do not associate the fetched revisions with different configuration if
    ;; an administrator rewrites channels.scm while the network check runs.
    (unless (string=? channels-text (read-text channels-file))
      (fail "channels changed during the update check"))
    (unless (equal? applied (read-applied-state state-file))
      (fail "applied channel state changed during the update check"))
    ;; Publish the cache before stdout.  If persistence fails, the notifier sees
    ;; a nonzero result and preserves its previous state.
    (write-cache cache-file channels-text new)
    (display (if (equal? old new) "true\n" "false\n"))))

(define (main arguments)
  (match arguments
    ((state-file channels-file cache-file . rest)
     (unless (or (null? rest) (equal? rest '("skip-refresh")))
       (fail "usage: STATE-FILE CHANNELS-FILE CACHE-FILE [skip-refresh]"))
     (let ((applied (read-applied-state state-file)))
       (if (pair? rest)
           (check-without-refresh applied channels-file cache-file)
           (check-with-refresh applied state-file channels-file cache-file))))
    (_
     (fail "usage: STATE-FILE CHANNELS-FILE CACHE-FILE [skip-refresh]"))))

(main (cdr (command-line)))
