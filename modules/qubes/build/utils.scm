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
  "Return a truthy value when PATH names an existing file system entry,
following the @code{lstat} semantics (a dangling symlink still counts as
existing).  Return @code{#f} otherwise."
  (false-if-exception (lstat path)))

(define (non-symlink-directory? path)
  "Return @code{#t} when PATH is a real directory and not a symbolic link to
one, and @code{#f} otherwise."
  (let ((st (false-if-exception (lstat path))))
    (and st
         (eq? (stat:type st)
              'directory))))

(define (delete-path path)
  "Delete PATH if it exists, recursing into it when it is a real directory and
unlinking it directly otherwise.  Do nothing when PATH is absent."
  (when (path-exists? path)
    (if (non-symlink-directory? path)
        (delete-file-recursively path)
        (delete-file path))))

(define (merge-tree source destination)
  "Move every entry under SOURCE into DESTINATION, merging recursively when an
entry is a real directory on both sides and overwriting otherwise.  SOURCE is
emptied as it is consumed; do nothing when SOURCE does not exist."
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
              (scandir source (lambda (entry) (not (member entry '("." ".."))))))))

(define (python-version-directory root)
  "Return the name (e.g. @code{\"python3.10\"}) of the first
@file{python*} subdirectory under ROOT's @file{lib} directory, or @code{#f}
when ROOT has no such directory."
  (let* ((lib (string-append root "/lib"))
         (entries (and (path-exists? lib)
                       (scandir lib (lambda (entry) (string-prefix? "python" entry))))))
    (and entries
         (pair? entries)
         (car entries))))

(define (python-site-packages root python-directory)
  "Return ROOT's @file{lib/PYTHON-DIRECTORY/site-packages} path when it
exists, or @code{#f} otherwise.  PYTHON-DIRECTORY is a name such as the value
returned by @code{python-version-directory}."
  (let ((site (string-append root "/lib/" python-directory
                             "/site-packages")))
    (and (path-exists? site) site)))

(define (read-text path)
  "Read and return the entire contents of the file at PATH as a string."
  (call-with-input-file path
    get-string-all))

(define (write-text path text)
  "Write the string TEXT to the file at PATH, creating PATH's parent directory
first when necessary."
  (mkdir-p (dirname path))
  (call-with-output-file path
    (lambda (port)
      (display text port))))

(define (replace-once text needle replacement context)
  "Return TEXT with the first occurrence of the substring NEEDLE replaced by
REPLACEMENT.  Raise an error mentioning CONTEXT when NEEDLE is not present, so
that source drift fails the build loudly."
  (let ((index (string-contains text needle)))
    (unless index
      (error "expected text not found" context))
    (string-append (substring text 0 index) replacement
                   (substring text (+ index (string-length needle))))))

(define (python-quote text)
  "Return TEXT as a single-quoted Python string literal, escaping backslashes,
single quotes, and newlines so the result is safe to embed in generated Python
source."
  (call-with-output-string (lambda (port)
                             (display "'" port)
                             (string-for-each (lambda (char)
                                                (case char
                                                  ((#\\ #\')
                                                   (display "\\" port)
                                                   (display char port))
                                                  ((#\newline)
                                                   (display "\\n" port))
                                                  (else (display
                                                         char
                                                         port))))
                                              text)
                             (display "'" port))))

(define (python-list entries)
  "Return ENTRIES, a list of strings, rendered as a Python list literal of
single-quoted strings (e.g. @code{[\"a\" \"b\"]} becomes @code{['a', 'b']})."
  (string-append "[" (string-join (map python-quote entries) ", ") "]"))
