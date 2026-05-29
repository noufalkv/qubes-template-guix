#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
preflight_script="$script_dir/guest-update-proxy-preflight.sh"
template_name="${TEMPLATE_NAME:-guix}"
update_timeout="${GUIX_CENTRAL_VMUPDATE_TIMEOUT:-3600}"
proxy_probe_url="${GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL:-https://codeberg.org/guix/guix.git}"
log_dir=""
qubes_update_log_dir="${QUBES_GUIX_UPDATES_LOG_DIR:-/var/log/qubes/qubes-update}"
update_log=""

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-central-vmupdate-dom0.sh [options]

Run Qubes' centralized VM updater against a Guix TemplateVM.

This script validates the dom0 `qubes-vm-update` path.  It assumes the dom0
updater already contains the Guix vmupdate backend, for example from the
matching qubes-core-admin-linux review patch.  It does not install or patch
dom0.

Options:
  -t, --template NAME       TemplateVM name. Default: guix.
      --timeout SECONDS     Timeout for qubes-vm-update. Default: 3600.
      --proxy-probe-url URL URL to probe through the raw Qubes updates proxy
                            before running qubes-vm-update. Default:
                            https://codeberg.org/guix/guix.git.
  -l, --log-dir DIR         Directory for copied logs. Default:
                            /tmp/qubes-guix-central-vmupdate-TEMPLATE.PID.
  -h, --help                Show this help.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'test-guix-central-vmupdate failed: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -t|--template)
                require_arg "$@"
                template_name=$2
                shift 2
                ;;
            --timeout)
                require_arg "$@"
                update_timeout=$2
                shift 2
                ;;
            --proxy-probe-url)
                require_arg "$@"
                proxy_probe_url=$2
                shift 2
                ;;
            -l|--log-dir)
                require_arg "$@"
                log_dir=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

check_requirements() {
    [ -n "$template_name" ] || die "empty template name"
    [ -n "$proxy_probe_url" ] || die "empty proxy probe URL"
    case "$update_timeout" in
        *[!0-9]*|'') die "timeout must be a positive integer" ;;
    esac
    [ "$update_timeout" -gt 0 ] || die "timeout must be greater than zero"

    need qvm-check
    need qvm-prefs
    need qvm-run
    need qubes-vm-update
    need timeout
}

log_vm_prefs() {
    local vm="$1"
    local label="$2"

    qvm-prefs "$vm" klass 2>/dev/null |
        sed "s/^/dom0 $label klass: /" || true
    qvm-prefs "$vm" netvm 2>/dev/null |
        sed "s/^/dom0 $label netvm: /" || true
    if qvm-check --running "$vm" >/dev/null 2>&1; then
        echo "dom0 $label state: running"
    else
        echo "dom0 $label state: not-running-or-unavailable"
    fi
}

log_updatevm_context() {
    local updatevm

    if ! command -v qubes-prefs >/dev/null 2>&1; then
        echo 'dom0 updatevm: <qubes-prefs unavailable>'
        return
    fi

    updatevm=$(qubes-prefs updatevm 2>/dev/null || true)
    printf 'dom0 updatevm: %s\n' "${updatevm:-<unset>}"

    echo 'dom0 qubes.UpdatesProxy policy entries:'
    if grep -Rhs '^[[:space:]]*qubes[.]UpdatesProxy[[:space:]]' \
        /etc/qubes/policy.d 2>/dev/null; then
        :
    else
        echo 'dom0 qubes.UpdatesProxy policy entries: <none found>'
    fi

    if qvm-check sys-net >/dev/null 2>&1; then
        echo 'dom0 standard update target sys-net: present'
        log_vm_prefs sys-net sys-net
    else
        echo 'dom0 standard update target sys-net: absent-or-unavailable'
    fi

    case "${updatevm:-}" in
        ''|None) return ;;
    esac

    log_vm_prefs "$updatevm" updatevm
}

prepare_dom0_context() {
    qvm-check "$template_name" >/dev/null 2>&1 ||
        die "template does not exist: $template_name"
    [ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
        die "source is not a TemplateVM: $template_name"

    log_dir="${log_dir:-/tmp/qubes-guix-central-vmupdate-$template_name.$$}"
    mkdir -p "$log_dir"
    log_updatevm_context | tee "$log_dir/updatevm-context.log"
}

qubes_update_log_paths() {
    {
        printf '%s\n' \
            "$qubes_update_log_dir/qubes-vm-update.log" \
            "$qubes_update_log_dir/update-agent.log" \
            "$qubes_update_log_dir/$template_name.log" \
            "$qubes_update_log_dir/update-$template_name.log"
        find "$qubes_update_log_dir" \
            -maxdepth 1 -type f \
            \( -name '*vm-update*.log' -o \
               -name 'update-agent.log' -o \
               -name "*$template_name*.log" \) \
            -print 2>/dev/null || true
    } | sort -u
}

reset_qubes_update_logs() {
    local log

    while IFS= read -r log; do
        [ -n "$log" ] || continue
        [ -e "$log" ] || continue
        : >"$log" || true
    done < <(qubes_update_log_paths)
}

copy_qubes_update_logs() {
    local log
    local prefix
    local safe_name

    while IFS= read -r log; do
        [ -n "$log" ] || continue
        [ -r "$log" ] || continue
        case "$log" in
            "$qubes_update_log_dir"/*) prefix=dom0-qubes-update ;;
            *) prefix=dom0-qubes-log ;;
        esac
        safe_name="$(basename "$log")"
        cp -a "$log" "$log_dir/$prefix-$safe_name" || true
    done < <(qubes_update_log_paths)
}

update_evidence_logs() {
    printf '%s\n' "$update_log"
    find "$log_dir" -maxdepth 1 -type f \
        \( -name 'dom0-qubes-update-*.log' -o \
           -name 'dom0-qubes-log-*.log' \) \
        -print 2>/dev/null || true
}

logs_have() {
    local grep_mode="$1"
    local pattern="$2"
    local log

    while IFS= read -r log; do
        [ -n "$log" ] || continue
        [ -r "$log" ] || continue
        grep "$grep_mode" -q -- "$pattern" "$log" && return 0
    done < <(update_evidence_logs | sort -u)
    return 1
}

logs_have_fixed() {
    logs_have -F "$1"
}

logs_have_regex() {
    logs_have -E "$1"
}

dump_log_tail() {
    local log

    for log in "$log_dir"/*.log; do
        [ -r "$log" ] || continue
        printf -- '--- %s tail ---\n' "${log##*/}" >&2
        tail -120 "$log" >&2 || true
    done
}

guest_failure_diagnostics() {
    cat <<'__QUBES_GUIX_GUEST__'
set -eu

show_file_tail() {
    file=$1
    [ -e "$file" ] || return 0
    printf -- '--- guest %s tail ---\n' "$file"
    tail -200 "$file" 2>&1 || true
}

show_dir_listing() {
    dir=$1
    [ -e "$dir" ] || return 0
    printf -- '--- guest %s listing ---\n' "$dir"
    find "$dir" -maxdepth 3 -mindepth 1 -printf '%y %p\n' 2>&1 |
        sort | tail -200 || true
}

date -u '+guest utc: %Y-%m-%dT%H:%M:%SZ' || true
printf 'guest qube: %s\n' "$(qubesdb-read /name 2>/dev/null || hostname || true)"
show_dir_listing /run/qubes-update
show_dir_listing /tmp/qubes-vm-update-guix-config
show_dir_listing /tmp/qubes-vm-update-guix-cache
printf -- '--- guest disk space ---\n'
df -h 2>&1 || true
printf -- '--- guest guix processes ---\n'
ps -efww 2>&1 | grep '[g]uix' || true
if command -v herd >/dev/null 2>&1; then
    printf -- '--- guest herd status guix-daemon ---\n'
    herd status guix-daemon 2>&1 || true
    printf -- '--- guest herd status qubes-updates-proxy-forwarder ---\n'
    herd status qubes-updates-proxy-forwarder 2>&1 || true
fi
show_file_tail /var/log/qubes/qubes-update/update-agent.log
show_file_tail /var/log/qubes/qubes-update.log
show_file_tail /var/log/guix-daemon.log
show_file_tail /var/log/messages
show_file_tail /tmp/qubes-guix-proxy-preflight.err
show_file_tail /tmp/qubes-guix-proxy-preflight.out
if [ -d /var/log/guix ]; then
    printf -- '--- guest recent Guix build logs ---\n'
    find /var/log/guix -type f -printf '%T@ %p\n' 2>/dev/null |
        sort -n | tail -8 | sed 's/^[^ ]* //' |
        while IFS= read -r log; do
            [ -n "$log" ] || continue
            printf -- '--- guest %s tail ---\n' "$log"
            case "$log" in
                *.gz) gzip -cd "$log" 2>&1 | tail -120 || true ;;
                *) tail -120 "$log" 2>&1 || true ;;
            esac
        done
fi
__QUBES_GUIX_GUEST__
}

collect_guest_failure_logs() {
    qvm-run --pass-io --no-gui --user root "$template_name" \
        "sh -eu -c $(quote "$(guest_failure_diagnostics)")" \
        >"$log_dir/guest-after-failure.log" 2>&1 || true
}

fail_with_logs() {
    local message="$1"
    local collect_guest="${2:-0}"

    if [ "$collect_guest" = "1" ]; then
        collect_guest_failure_logs
    fi
    dump_log_tail
    die "$message; logs in $log_dir"
}

run_guest_script() {
    local script="$1"
    local path="$2"
    local log="$3"
    shift 3
    local command arg

    command="$(cat <<EOF
cat >$(quote "$path") <<'__QUBES_GUIX_TEST__'
$script
__QUBES_GUIX_TEST__
chmod 0700 $(quote "$path")
$(quote "$path")
EOF
)"
    for arg in "$@"; do
        command+=" $(quote "$arg")"
    done

    qvm-run --pass-io --no-gui --user root "$template_name" "$command" \
        2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
}

run_guest_step() {
    local script="$1"
    local path="$2"
    local log="$3"
    local message="$4"
    local status
    shift 4

    set +e
    run_guest_script "$script" "$path" "$log" "$@"
    status=$?
    set -e

    [ "$status" -eq 0 ] ||
        fail_with_logs "$message failed with status $status"
}

guest_central_preflight() {
    cat <<'__QUBES_GUIX_GUEST__'
set -eu

test -e /run/current-system
test -r /etc/config.scm
test -r /etc/qubes-guix-channel/modules/qubes/packages.scm
test -x /usr/bin/python3
test -x /usr/lib/qubes/upgrades-installed-check
test -x /usr/lib/qubes/upgrades-status-notify
__QUBES_GUIX_GUEST__
}

run_preflight() {
    [ -r "$preflight_script" ] ||
        die "missing guest preflight helper: $preflight_script"

    run_guest_step \
        "$(cat "$preflight_script")" \
        /tmp/qubes-guix-central-vmupdate-preflight.sh \
        "$log_dir/preflight.log" \
        "central updater proxy preflight" \
        "$proxy_probe_url" \
        60

    run_guest_step \
        "$(guest_central_preflight)" \
        /tmp/qubes-guix-central-vmupdate-guest-checks.sh \
        "$log_dir/guest-preflight.log" \
        "central updater guest preflight"
}

run_central_update() {
    local status

    update_log="$log_dir/qubes-vm-update.log"
    reset_qubes_update_logs
    set +e
    timeout "$update_timeout" qubes-vm-update \
        --targets "$template_name" \
        --force-update \
        --force-upgrade \
        --max-concurrency 1 \
        --show-output \
        --no-cleanup \
        --just-print-progress \
        2>&1 | tee "$update_log"
    status=${PIPESTATUS[0]}
    set -e

    copy_qubes_update_logs

    [ "$status" -eq 0 ] ||
        fail_with_logs "qubes-vm-update failed with status $status" 1
}

check_central_update_logs() {
    if logs_have_regex \
        'Only Debian, RedHat.*ArchLinux|NotImplementedError|Package manager not found|Request refused|qubes[.]UpdatesProxy'; then
        fail_with_logs "qubes-vm-update log shows unsupported Guix or update-proxy failure" 1
    fi

    logs_have_fixed 'Skipping separate Guix refresh; Guix System reconfigure uses the installed system Guix and /etc/config.scm.' ||
        fail_with_logs "qubes-vm-update log did not show Guix refresh handoff" 1
    if logs_have_fixed 'Guix System already matches /etc/config.scm; skipping reconfigure.'; then
        :
    else
        logs_have_fixed 'Reconfiguring Guix System from /etc/config.scm using the installed system Guix.' ||
            fail_with_logs "qubes-vm-update log did not show Guix system reconfigure or no-op evidence" 1
        logs_have_fixed 'Reconfigured Guix System.' ||
            fail_with_logs "qubes-vm-update log did not show successful Guix system reconfigure" 1
    fi
    logs_have_fixed 'Updated packages:' ||
        fail_with_logs "qubes-vm-update log did not show package update metadata" 1
    if ! logs_have_regex '(^|[[:space:]])guix-system[[:space:]]+/gnu/store/|(^|[[:space:]])[^[:space:]]+:[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/gnu/store/'; then
        fail_with_logs "qubes-vm-update log did not show Guix package metadata entries" 1
    fi
}

guest_postcheck() {
    cat <<'__QUBES_GUIX_GUEST__'
set -eu
test -e /run/current-system
test -d /gnu/store
herd status guix-daemon >/tmp/qubes-guix-daemon.status
grep -F 'It is running' /tmp/qubes-guix-daemon.status >/dev/null
guix --version >/tmp/qubes-guix-version.out
test "$(/usr/lib/qubes/upgrades-installed-check)" = true
__QUBES_GUIX_GUEST__
}

run_postcheck() {
    run_guest_step \
        "$(guest_postcheck)" \
        /tmp/qubes-guix-central-vmupdate-postcheck.sh \
        "$log_dir/postcheck.log" \
        "central updater postcheck"
}

main() {
    parse_args "$@"
    check_requirements
    prepare_dom0_context
    run_preflight
    run_central_update
    check_central_update_logs
    run_postcheck

    printf 'central Guix qubes-vm-update check passed: %s\n' "$template_name"
}

main "$@"
