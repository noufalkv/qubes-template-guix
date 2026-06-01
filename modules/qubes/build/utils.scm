;;; utils.scm --- Shared build-side install-phase helpers for Qubes packages
;;;
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; These helpers run inside the build environment (gnu-build-system install
;;; phases) of the Qubes VM packages.  They were previously duplicated verbatim
;;; across qubes-vm-qrexec and qubes-vm-core; this module is the single source
;;; of truth.  Bodies are byte-for-byte the previous definitions, except
;;; WRITE-TEXT, which uses the mkdir-p superset (creating the parent directory
;;; is a no-op when it already exists, so existing call sites are unaffected).

(define-module (qubes build utils)
  #:use-module (guix build utils)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:export (path-exists?
            non-symlink-directory?
            delete-path
            merge-tree
            python-version-directory
            python-site-packages
            read-text
            write-text
            replace-once
            python-quote
            python-list))

(define (path-exists? path)
  (false-if-exception (lstat path)))

(define (non-symlink-directory? path)
  (let ((st (false-if-exception (lstat path))))
    (and st
         (eq? (stat:type st)
              'directory))))

(define (delete-path path)
  (when (path-exists? path)
    (if (non-symlink-directory? path)
        (delete-file-recursively path)
        (delete-file path))))

(define (merge-tree source destination)
  (when (path-exists? source)
    (mkdir-p destination)
    (for-each (lambda (name)
                (let ((from (string-append source "/" name))
                      (to (string-append destination "/" name)))
                  (if (and (non-symlink-directory? from)
                           (non-symlink-directory? to))
                      (begin
                        (merge-tree from to)
                        (rmdir from))
                      (begin
                        (delete-path to)
                        (rename-file from to)))))
              (scandir source
                       (lambda (entry)
                         (not (member entry
                                      '("." ".."))))))))

(define (python-version-directory root)
  (let* ((lib (string-append root "/lib"))
         (entries (and (path-exists? lib)
                       (scandir lib
                                (lambda (entry)
                                  (string-prefix? "python"
                                                  entry))))))
    (and entries
         (pair? entries)
         (car entries))))

(define (python-site-packages root python-directory)
  (let ((site (string-append root "/lib/" python-directory
                             "/site-packages")))
    (and (path-exists? site) site)))

(define (read-text path)
  (call-with-input-file path
    get-string-all))

(define (write-text path text)
  (mkdir-p (dirname path))
  (call-with-output-file path
    (lambda (port)
      (display text port))))

(define (replace-once text needle replacement context)
  (let ((index (string-contains text needle)))
    (unless index
      (error "expected text not found" context))
    (string-append (substring text 0 index) replacement
                   (substring text
                              (+ index
                                 (string-length needle))))))

(define (python-quote text)
  (call-with-output-string (lambda (port)
                             (display "'" port)
                             (string-for-each (lambda (char)
                                                (case char
                                                  ((#\\ #\')
                                                   (display
                                                    "\\" port)
                                                   (display
                                                    char port))
                                                  ((#\newline)
                                                   (display
                                                    "\\n" port))
                                                  (else (display
                                                         char
                                                         port))))
                                              text)
                             (display "'" port))))

(define (python-list entries)
  (string-append "["
                 (string-join (map python-quote entries) ", ")
                 "]"))
