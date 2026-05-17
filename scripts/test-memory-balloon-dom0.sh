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

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

[ -n "$template_name" ] || die "empty template name"
appvm_name="${appvm_name:-$template_name-balloon-test}"

is_uint "$initial_memory" || die "--memory must be an integer"
is_uint "$max_memory" || die "--maxmem must be an integer"
is_uint "$allocation_mb" || die "--allocate must be an integer"
is_uint "$min_growth" || die "--min-growth must be an integer"
is_uint "$timeout_seconds" || die "--timeout must be an integer"
[ "$max_memory" -gt "$initial_memory" ] ||
    die "--maxmem must be greater than --memory"
[ "$allocation_mb" -gt 0 ] || die "--allocate must be positive"
[ "$min_growth" -gt 0 ] || die "--min-growth must be positive"

need awk
need qvm-create
need qvm-ls
need qvm-prefs
need qvm-remove
need qvm-run
need qvm-shutdown
need qvm-start
need xl

vm_exists() {
    qvm-ls --raw-list 2>/dev/null | grep -Fxq "$1"
}

domain_memory_mb() {
    local name="$1"
    xl list "$name" 2>/dev/null | awk -v vm="$name" '$1 == vm { print $3 }'
}

cleanup() {
    qvm-run --pass-io --no-gui "$appvm_name" \
        'if [ -f /tmp/qubes-guix-balloon.pid ]; then
             kill "$(cat /tmp/qubes-guix-balloon.pid)" >/dev/null 2>&1 || true
         fi
         rm -f /tmp/qubes-guix-balloon.pid \
               /tmp/qubes-guix-balloon.log \
               /tmp/qubes-guix-balloon.scm' >/dev/null 2>&1 || true
    if [ "$keep_appvm" -eq 0 ] && vm_exists "$appvm_name"; then
        qvm-shutdown --wait "$appvm_name" >/dev/null 2>&1 || true
        qvm-remove --force "$appvm_name" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

vm_exists "$template_name" || die "template VM does not exist: $template_name"
[ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
    die "source is not a TemplateVM: $template_name"

if vm_exists "$appvm_name"; then
    [ "$replace_existing" -eq 1 ] ||
        die "test AppVM already exists: $appvm_name; pass --replace-existing"
    qvm-shutdown --wait "$appvm_name" >/dev/null 2>&1 || true
    qvm-remove --force "$appvm_name"
fi

qvm-create -C AppVM -t "$template_name" --label red "$appvm_name"
qvm-prefs "$appvm_name" memory "$initial_memory"
qvm-prefs "$appvm_name" maxmem "$max_memory"
qvm-start "$appvm_name"

qvm-run --pass-io --no-gui "$appvm_name" \
    'test -e /run/qubes-service/meminfo-writer
     test -s /var/run/meminfo-writer.pid
     kill -0 "$(cat /var/run/meminfo-writer.pid)"
     pgrep -x meminfo-writer >/dev/null
     command -v guile >/dev/null' >/dev/null

pressure_command="$(cat <<'__QUBES_GUIX_BALLOON_PRESSURE__'
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
ALLOCATION_MB="__ALLOCATION_MB__" \
    guile /tmp/qubes-guix-balloon.scm \
    >/tmp/qubes-guix-balloon.log 2>&1 &
printf '%s\n' "$!" >/tmp/qubes-guix-balloon.pid
__QUBES_GUIX_BALLOON_PRESSURE__
)"
pressure_command="${pressure_command/__ALLOCATION_MB__/$allocation_mb}"

before="$(domain_memory_mb "$appvm_name")"
[ -n "$before" ] || die "could not read initial domain memory for $appvm_name"

qvm-run --pass-io --no-gui "$appvm_name" "$pressure_command" >/dev/null

deadline=$((SECONDS + timeout_seconds))
best="$before"
while [ "$SECONDS" -lt "$deadline" ]; do
    current="$(domain_memory_mb "$appvm_name")"
    if [ -n "$current" ]; then
        [ "$current" -gt "$best" ] && best="$current"
        if [ $((current - before)) -ge "$min_growth" ]; then
            printf 'memory balloon check passed: %s grew from %s MiB to %s MiB\n' \
                "$appvm_name" "$before" "$current"
            exit 0
        fi
    fi
    sleep 5
done

qvm-run --pass-io --no-gui "$appvm_name" \
    'cat /tmp/qubes-guix-balloon.log 2>/dev/null || true' >&2 || true
die "memory did not grow by at least $min_growth MiB for $appvm_name; before=$before best=$best"
