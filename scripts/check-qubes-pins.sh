#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
packages_file="$repo_root/modules/qubes/packages.scm"

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

# Mode/state set by argument parsing.
mode="check"
assume_yes=0

# Temporary directories to remove on exit.
tmp_dirs=()
cleanup() {
    local d
    for d in "${tmp_dirs[@]:-}"; do
        [ -n "$d" ] && rm -rf -- "$d"
    done
    return 0
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
usage: check-qubes-pins.sh [--write [--yes]] [-h|--help]

  (no args)    read-only freshness check of the pinned Qubes source
               components in modules/qubes/packages.scm; exits non-zero
               if any pin is stale.  Output is unchanged from before.

  --write      refresh ONLY stale entries: for each component whose pinned
               tag/commit differs from the latest upstream series tag,
               recompute (tag commit sha256), print a unified diff, and
               prompt for confirmation before writing.  When every pin is
               already current this makes ZERO changes (idempotent).
  --yes, -y    with --write, skip the interactive confirmation prompt.
  -h, --help   show this help and exit.

Computing a fresh base32 sha256 requires `guix` (it clones the component,
checks out the commit, removes .git, and runs `guix hash -rx`).  Run
--write on a host that has guix (the build host, e.g. dev-0508); on a host
without guix the read-only check still works and --write is a no-op when
all pins are current.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --write) mode="write" ;;
            --yes|-y) assume_yes=1 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*)
                printf 'error: unknown argument: %s\n' "$1" >&2
                usage >&2
                exit 2
                ;;
            *)
                printf 'error: unexpected argument: %s\n' "$1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
    if [ $# -gt 0 ]; then
        printf 'error: unexpected argument: %s\n' "$1" >&2
        usage >&2
        exit 2
    fi
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

# Like read_pinned_sources but also emits the pinned sha256, tab-separated:
#   name<TAB>tag<TAB>commit<TAB>sha256
# Used only by --write; the read-only path keeps read_pinned_sources intact.
read_pinned_sources_full() {
    guile -q -s /dev/stdin "$packages_file" <<'GUILE'
(use-modules (ice-9 match))

(define file (cadr (command-line)))

(define (components-from-form form)
  (match form
    (('define '%qubes-source-components ('quote components)) components)
    (_ #f)))

(define (print-component component)
  (match component
    ((name version commit hash)
     (format #t "~a\t~a\t~a\t~a\n" name version commit hash))
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

# Replace exactly one literal occurrence of $2 with $3 inside file $1.
# Aborts if the search token is absent or matches more than once, so a
# rewrite can never touch an unintended location.
apply_literal_replacement() {
    local file="$1" old="$2" new="$3"
    guile -q -s /dev/stdin "$file" "$old" "$new" <<'GUILE'
(use-modules (ice-9 textual-ports))

(define args (cdr (command-line)))
(define file (list-ref args 0))
(define old  (list-ref args 1))
(define new  (list-ref args 2))

(define content
  (call-with-input-file file get-string-all))

(define (count-occurrences hay needle)
  (let ((nlen (string-length needle)))
    (if (= nlen 0)
        0
        (let loop ((start 0) (n 0))
          (let ((idx (string-contains hay needle start)))
            (if idx (loop (+ idx nlen) (+ n 1)) n))))))

(define n (count-occurrences content old))
(unless (= n 1)
  (format (current-error-port)
          "error: expected exactly 1 occurrence of token, found ~a: ~s\n"
          n old)
  (exit 1))

(define idx (string-contains content old))
(define result
  (string-append (substring content 0 idx)
                 new
                 (substring content (+ idx (string-length old)))))

(call-with-output-file file
  (lambda (port) (put-string port result)))
GUILE
}

# Compute the git-fetch base32 sha256 for (component, commit): clone, check
# out the commit, drop .git, and run `guix hash -rx`.  Fails cleanly if guix
# is unavailable so a wrong hash is never emitted.
compute_component_sha256() {
    local component="$1" commit="$2"
    command -v guix >/dev/null 2>&1 || {
        printf 'error: guix not found in PATH; cannot recompute the nar hash for %s.\n' \
            "$component" >&2
        printf '       Run --write on a host that has guix (the build host, e.g. dev-0508).\n' >&2
        exit 1
    }

    local url="https://github.com/QubesOS/$component.git"
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qubes-pin.XXXXXX")"
    tmp_dirs+=("$dir")
    local checkout="$dir/src"

    if git clone --quiet --depth 1 "$url" "$checkout" 2>/dev/null \
        && git -C "$checkout" fetch --quiet --depth 1 origin "$commit" 2>/dev/null \
        && git -C "$checkout" checkout --quiet "$commit" 2>/dev/null; then
        :
    else
        rm -rf -- "$checkout"
        git clone --quiet "$url" "$checkout"
        git -C "$checkout" checkout --quiet "$commit"
    fi

    local head
    head="$(git -C "$checkout" rev-parse HEAD)"
    if [ "$head" != "$commit" ]; then
        printf 'error: checkout of %s did not land on %s (got %s)\n' \
            "$component" "$commit" "$head" >&2
        exit 1
    fi

    rm -rf -- "$checkout/.git"
    guix hash -rx "$checkout"
}

verify_diff_range() {
    local lo hi
    local line plus start cnt end out_of_range=0

    lo=$(grep -n -m 1 '^(define %qubes-source-components' "$packages_file" | cut -d: -f1)
    if [ -z "$lo" ]; then
        printf 'error: could not find (define %%qubes-source-components in %s\n' "$packages_file" >&2
        exit 1
    fi

    hi=$(awk -v start="$lo" '
        BEGIN { balance = 0; in_string = 0; escaped = 0 }
        NR < start { next }
        {
            for (i = 1; i <= length($0); i++) {
                ch = substr($0, i, 1)
                if (in_string) {
                    if (escaped) {
                        escaped = 0
                    } else if (ch == "\\") {
                        escaped = 1
                    } else if (ch == """) {
                        in_string = 0
                    }
                } else {
                    if (ch == """) {
                        in_string = 1
                    } else if (ch == "(") {
                        balance++
                    } else if (ch == ")") {
                        balance--
                        if (balance == 0) {
                            print NR
                            exit
                        }
                    }
                }
            }
        }
    ' "$packages_file")
    if [ -z "$hi" ]; then
        printf 'error: could not determine closing line for (define %%qubes-source-components in %s\n' "$packages_file" >&2
        exit 1
    fi

    while IFS= read -r line; do
        case "$line" in
            @@*)
                plus="${line#*+}"
                plus="${plus%% *}"
                start="${plus%%,*}"
                if [ "$plus" = "$start" ]; then
                    cnt=1
                else
                    cnt="${plus#*,}"
                fi
                if [ "$cnt" -eq 0 ]; then
                    end="$start"
                else
                    end=$((start + cnt - 1))
                fi
                if [ "$start" -lt "$lo" ] || [ "$end" -gt "$hi" ]; then
                    printf 'error: rewrite touched lines %s-%s outside the pin table (%s-%s)\n' \
                        "$start" "$end" "$lo" "$hi" >&2
                    out_of_range=1
                fi
                ;;
        esac
    done < <(git -C "$repo_root" diff -U0 -- "$packages_file")
    [ "$out_of_range" -eq 0 ]
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

write_pinned_sources() {
    local pinned_sources
    local component version commit oldsha
    local series latest_tag latest_commit new_sha
    local stale=0
    local -a rep_old rep_new
    local nrep=0

    pinned_sources="$(read_pinned_sources_full)"
    while IFS=$'\t' read -r component version commit oldsha; do
        [ -n "$component" ] || continue
        series="${version%.*}."
        latest_tag="$(latest_series_tag "$component" "$series")"
        if [ -z "$latest_tag" ]; then
            printf 'error: no upstream tags found for %s series %s\n' \
                "$component" "$series" >&2
            exit 1
        fi
        latest_commit="$(tag_commit "$component" "$latest_tag")"

        if [ "$version" = "$latest_tag" ] && [ "$commit" = "$latest_commit" ]; then
            printf 'ok: %s %s %s\n' "$component" "$version" "$commit"
            continue
        fi

        stale=1
        printf 'stale: %s %s@%s -> %s@%s\n' \
            "$component" "$version" "$commit" "$latest_tag" "$latest_commit" >&2
        new_sha="$(compute_component_sha256 "$component" "$latest_commit")"

        # Token replacements, anchored on globally-unique substrings.  The
        # tag shares a line with the (unique) "(\"name\" prefix; the commit
        # and sha256 are themselves unique across the whole file.
        rep_old+=("(\"$component\" \"$version\"")
        rep_new+=("(\"$component\" \"$latest_tag\"")
        rep_old+=("\"$commit\"")
        rep_new+=("\"$latest_commit\"")
        rep_old+=("\"$oldsha\"")
        rep_new+=("\"$new_sha\"")
        nrep=$((nrep + 3))
    done <<< "$pinned_sources"

    if [ "$stale" -eq 0 ]; then
        printf 'all pins current; no changes.\n'
        return 0
    fi

    local workdir work backup i
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/qubes-pin-write.XXXXXX")"
    tmp_dirs+=("$workdir")
    work="$workdir/packages.scm.new"
    backup="$workdir/packages.scm.orig"
    cp -- "$packages_file" "$work"
    cp -- "$packages_file" "$backup"

    for ((i = 0; i < nrep; i++)); do
        apply_literal_replacement "$work" "${rep_old[i]}" "${rep_new[i]}"
    done

    printf '\nProposed change to modules/qubes/packages.scm:\n\n'
    git --no-pager diff --no-index -- "$packages_file" "$work" || true
    printf '\n'

    if [ "$assume_yes" -ne 1 ]; then
        local reply
        printf 'Apply these changes to modules/qubes/packages.scm? [y/N] '
        read -r reply || reply=""
        case "$reply" in
            y|Y|yes|YES) ;;
            *)
                printf 'aborted; no changes written.\n' >&2
                return 0
                ;;
        esac
    fi

    cp -- "$work" "$packages_file"

    if ! verify_diff_range; then
        cp -- "$backup" "$packages_file"
        printf 'error: refused write; restored original packages.scm\n' >&2
        exit 1
    fi

    printf 'updated modules/qubes/packages.scm\n'
}

main() {
    parse_args "$@"
    check_requirements
    case "$mode" in
        write) write_pinned_sources ;;
        *) check_pinned_sources ;;
    esac
}

main "$@"
