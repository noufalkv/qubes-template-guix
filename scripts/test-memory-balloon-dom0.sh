#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

template_name="${TEMPLATE_NAME:-guix}"
appvm_name="${APPVM_NAME:-}"
initial_memory="${INITIAL_MEMORY:-400}"
max_memory="${MAX_MEMORY:-1600}"
allocation_mb="${ALLOCATION_MB:-900}"
min_growth="${MIN_GROWTH:-128}"
timeout_seconds="${TIMEOUT_SECONDS:-180}"
keep_appvm=0
replace_existing=0
appvm_created=0

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-memory-balloon-dom0.sh [options]

Exercise Qubes dynamic memory ballooning for a Guix AppVM.

Options:
  -t, --template NAME       TemplateVM to test. Default: guix.
  -a, --appvm NAME          AppVM to create. Default: TEMPLATE-balloon-test.
  -m, --memory MB           Initial memory preference. Default: 400.
  -M, --maxmem MB           Maximum memory preference. Default: 1600.
  -A, --allocate MB         Guest allocation pressure. Default: 900.
  -g, --min-growth MB       Required dom0-observed growth. Default: 128.
  -T, --timeout SECONDS     Poll timeout. Default: 180.
  -R, --replace-existing    Remove an existing test AppVM first.
  -k, --keep-appvm          Leave the test AppVM after the run.
  -h, --help                Show this help.

The script creates a disposable review AppVM from the template, starts a Guile
process that touches a large bytevector, and polls `xl list` in dom0 for memory
growth.  It verifies dynamic behavior beyond merely checking that
meminfo-writer is running.  Use it only in a disposable or nested review dom0.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

positive_int() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9]*)
            die "$name must be a positive integer"
            ;;
    esac
    [ "$value" -gt 0 ] || die "$name must be greater than zero"
}

vm_exists() {
    qvm-ls --raw-list 2>/dev/null | grep -Fxq "$1"
}

domain_memory_mb() {
    local name="$1"
    xl list "$name" 2>/dev/null | awk -v vm="$name" '$1 == vm { print $3 }'
}

run_guest() {
    qvm-run --pass-io --no-gui "$appvm_name" "$@"
}

guest_cleanup_balloon() {
    cat <<'__QUBES_GUIX_GUEST__'
if [ -f /tmp/qubes-guix-balloon.pid ]; then
    kill "$(cat /tmp/qubes-guix-balloon.pid)" >/dev/null 2>&1 || true
fi
rm -f /tmp/qubes-guix-balloon.pid \
      /tmp/qubes-guix-balloon.log \
      /tmp/qubes-guix-balloon.scm
__QUBES_GUIX_GUEST__
}

guest_meminfo_checks() {
    cat <<'__QUBES_GUIX_GUEST__'
test -e /run/qubes-service/meminfo-writer
test -s /var/run/meminfo-writer.pid
kill -0 "$(cat /var/run/meminfo-writer.pid)"
pgrep -x meminfo-writer >/dev/null
command -v guile >/dev/null
__QUBES_GUIX_GUEST__
}

guest_balloon_pressure() {
    printf 'export ALLOCATION_MB=%q\n' "$allocation_mb"
    cat <<'__QUBES_GUIX_GUEST__'
cat >/tmp/qubes-guix-balloon.scm <<'__QUBES_GUIX_BALLOON_SCM__'
(use-modules (rnrs bytevectors))
(define allocation-mb (string->number (getenv "ALLOCATION_MB")))
(define size (* allocation-mb 1024 1024))
(define data (make-bytevector size 0))
(let loop ((index 0))
  (when (< index size)
    (bytevector-u8-set! data index 1)
    (loop (+ index 4096))))
(sleep 120)
__QUBES_GUIX_BALLOON_SCM__
guile /tmp/qubes-guix-balloon.scm \
    >/tmp/qubes-guix-balloon.log 2>&1 &
printf '%s\n' "$!" >/tmp/qubes-guix-balloon.pid
__QUBES_GUIX_GUEST__
}

cleanup() {
    [ "$appvm_created" -eq 1 ] || return 0

    run_guest "$(guest_cleanup_balloon)" >/dev/null 2>&1 || true
    if [ "$keep_appvm" -eq 0 ] && vm_exists "$appvm_name"; then
        qvm-shutdown --wait "$appvm_name" >/dev/null 2>&1 || true
        qvm-remove --force "$appvm_name" >/dev/null 2>&1 || true
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -t|--template)
                require_arg "$@"
                template_name="$2"
                shift 2
                ;;
            -a|--appvm)
                require_arg "$@"
                appvm_name="$2"
                shift 2
                ;;
            -m|--memory)
                require_arg "$@"
                initial_memory="$2"
                shift 2
                ;;
            -M|--maxmem)
                require_arg "$@"
                max_memory="$2"
                shift 2
                ;;
            -A|--allocate)
                require_arg "$@"
                allocation_mb="$2"
                shift 2
                ;;
            -g|--min-growth)
                require_arg "$@"
                min_growth="$2"
                shift 2
                ;;
            -T|--timeout)
                require_arg "$@"
                timeout_seconds="$2"
                shift 2
                ;;
            -R|--replace-existing)
                replace_existing=1
                shift
                ;;
            -k|--keep-appvm)
                keep_appvm=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

validate_options() {
    [ -n "$template_name" ] || die "empty template name"
    appvm_name="${appvm_name:-$template_name-balloon-test}"

    positive_int "--memory" "$initial_memory"
    positive_int "--maxmem" "$max_memory"
    positive_int "--allocate" "$allocation_mb"
    positive_int "--min-growth" "$min_growth"
    positive_int "--timeout" "$timeout_seconds"
    [ "$max_memory" -gt "$initial_memory" ] ||
        die "--maxmem must be greater than --memory"
}

check_requirements() {
    need awk
    need qvm-create
    need qvm-ls
    need qvm-prefs
    need qvm-remove
    need qvm-run
    need qvm-shutdown
    need qvm-start
    need xl
}

ensure_template_available() {
    vm_exists "$template_name" ||
        die "template VM does not exist: $template_name"
    [ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
        die "source is not a TemplateVM: $template_name"
}

prepare_appvm() {
    if vm_exists "$appvm_name"; then
        [ "$replace_existing" -eq 1 ] ||
            die "test AppVM already exists: $appvm_name; pass --replace-existing"
        qvm-shutdown --wait "$appvm_name" >/dev/null 2>&1 || true
        qvm-remove --force "$appvm_name"
    fi

    qvm-create -C AppVM -t "$template_name" --label red "$appvm_name"
    appvm_created=1
    qvm-prefs "$appvm_name" memory "$initial_memory"
    qvm-prefs "$appvm_name" maxmem "$max_memory"
    qvm-start "$appvm_name"
}

run_balloon_check() {
    local before
    local best
    local current
    local deadline

    run_guest "$(guest_meminfo_checks)" >/dev/null

    before="$(domain_memory_mb "$appvm_name")"
    [ -n "$before" ] ||
        die "could not read initial domain memory for $appvm_name"

    run_guest "$(guest_balloon_pressure)" >/dev/null

    deadline=$((SECONDS + timeout_seconds))
    best="$before"
    while [ "$SECONDS" -lt "$deadline" ]; do
        current="$(domain_memory_mb "$appvm_name")"
        if [ -n "$current" ]; then
            [ "$current" -gt "$best" ] && best="$current"
            if [ $((current - before)) -ge "$min_growth" ]; then
                printf 'memory balloon check passed: %s grew from %s MiB to %s MiB\n' \
                    "$appvm_name" "$before" "$current"
                return 0
            fi
        fi
        sleep 5
    done

    run_guest \
        'cat /tmp/qubes-guix-balloon.log 2>/dev/null || true' >&2 || true
    die "memory did not grow by at least $min_growth MiB for $appvm_name; before=$before best=$best"
}

main() {
    parse_args "$@"
    validate_options
    check_requirements
    ensure_template_available
    prepare_appvm
    run_balloon_check
}

trap cleanup EXIT
main "$@"
