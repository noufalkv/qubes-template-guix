#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
packages_file="$repo_root/modules/qubes/packages.scm"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: missing required command: %s\n' "$1" >&2
        exit 1
    }
}

latest_series_tag() {
    local component="$1"
    local series="$2"
    local url="https://github.com/QubesOS/$component.git"
    local _sha ref latest=""

    while read -r _sha ref; do
        latest="${ref#refs/tags/}"
    done < <(git ls-remote --refs --tags --sort=v:refname \
        "$url" "refs/tags/${series}*")
    printf '%s\n' "$latest"
}

tag_commit() {
    local component="$1"
    local tag="$2"
    local url="https://github.com/QubesOS/$component.git"
    local refs
    local peeled
    local direct
    local sha ref

    refs="$(git ls-remote --tags "$url" "refs/tags/$tag" "refs/tags/$tag^{}")"
    peeled=""
    direct=""
    while read -r sha ref; do
        case "$ref" in
            *'^{}') peeled="$sha" ;;
            "refs/tags/$tag") direct="$sha" ;;
        esac
    done <<< "$refs"
    if [ -n "$peeled" ]; then
        printf '%s\n' "$peeled"
        return
    fi
    [ -n "$direct" ] || {
        printf 'error: could not resolve %s %s\n' "$component" "$tag" >&2
        exit 1
    }
    printf '%s\n' "$direct"
}

read_pinned_sources() {
    guile -q -s /dev/stdin "$packages_file" <<'GUILE'
(use-modules (ice-9 match))

(define file (cadr (command-line)))

(define (components-from-form form)
  (match form
    (('define '%qubes-source-components ('quote components)) components)
    (_ #f)))

(define (print-component component)
  (match component
    ((name version commit _hash)
     (format #t "~a ~a ~a\n" name version commit))
    (_
     (format (current-error-port)
             "error: malformed %%qubes-source-components entry: ~s\n"
             component)
     (exit 1))))

(call-with-input-file file
  (lambda (port)
    (let loop ()
      (let ((form (read port)))
        (cond
         ((eof-object? form)
          (format (current-error-port)
                  "error: %%qubes-source-components not found in ~a\n"
                  file)
          (exit 1))
         ((components-from-form form)
          => (lambda (components)
               (for-each print-component components)))
         (else
          (loop)))))))
GUILE
}

check_requirements() {
    need git
    need guile
}

check_pinned_sources() {
    local pinned_sources
    local failed=0
    local component version commit series latest_tag latest_commit

    pinned_sources="$(read_pinned_sources)"
    while read -r component version commit; do
        [ -n "$component" ] || continue
        series="${version%.*}."
        latest_tag="$(latest_series_tag "$component" "$series")"
        if [ -z "$latest_tag" ]; then
            printf 'error: no upstream tags found for %s series %s\n' \
                "$component" "$series" >&2
            failed=1
            continue
        fi
        latest_commit="$(tag_commit "$component" "$latest_tag")"
        if [ "$version" != "$latest_tag" ]; then
            printf 'stale version: %s is %s, latest %s tag is %s\n' \
                "$component" "$version" "$series" "$latest_tag" >&2
            failed=1
            continue
        fi
        if [ "$commit" != "$latest_commit" ]; then
            printf 'stale commit: %s %s is %s, upstream tag points to %s\n' \
                "$component" "$version" "$commit" "$latest_commit" >&2
            failed=1
            continue
        fi
        printf 'ok: %s %s %s\n' "$component" "$version" "$commit"
    done <<< "$pinned_sources"

    [ "$failed" -eq 0 ]
}

main() {
    check_requirements
    check_pinned_sources
}

main "$@"
