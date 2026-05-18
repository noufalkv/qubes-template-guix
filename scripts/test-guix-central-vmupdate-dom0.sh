#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

template_name="${TEMPLATE_NAME:-guix}"
update_timeout="${GUIX_CENTRAL_VMUPDATE_TIMEOUT:-3600}"
proxy_probe_url="${GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL:-https://git.savannah.gnu.org/git/guix.git}"
log_dir=""
qubes_update_log_dir="${QUBES_GUIX_UPDATES_LOG_DIR:-/var/log/qubes/qubes-update}"
qubes_legacy_log_dir="${QUBES_GUIX_LEGACY_UPDATE_LOG_DIR:-/var/log/qubes}"

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
                            https://git.savannah.gnu.org/git/guix.git.
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

log_updatevm_context() {
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
        qvm-prefs sys-net klass 2>/dev/null |
            sed 's/^/dom0 sys-net klass: /' || true
        qvm-prefs sys-net netvm 2>/dev/null |
            sed 's/^/dom0 sys-net netvm: /' || true
        if qvm-check --running sys-net >/dev/null 2>&1; then
            echo 'dom0 sys-net state: running'
        else
            echo 'dom0 sys-net state: not-running-or-unavailable'
        fi
    else
        echo 'dom0 standard update target sys-net: absent-or-unavailable'
    fi

    case "${updatevm:-}" in
        ''|None) return ;;
    esac

    qvm-prefs "$updatevm" klass 2>/dev/null |
        sed 's/^/dom0 updatevm klass: /' || true
    qvm-prefs "$updatevm" netvm 2>/dev/null |
        sed 's/^/dom0 updatevm netvm: /' || true
    if qvm-check --running "$updatevm" >/dev/null 2>&1; then
        echo 'dom0 updatevm state: running'
    else
        echo 'dom0 updatevm state: not-running-or-unavailable'
    fi
}

qvm-check "$template_name" >/dev/null 2>&1 ||
    die "template does not exist: $template_name"
[ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
    die "source is not a TemplateVM: $template_name"

log_dir="${log_dir:-/tmp/qubes-guix-central-vmupdate-$template_name.$$}"
mkdir -p "$log_dir"
log_updatevm_context | tee "$log_dir/updatevm-context.log"

qubes_update_log_paths() {
    {
        printf '%s\n' \
            "$qubes_update_log_dir/qubes-vm-update.log" \
            "$qubes_update_log_dir/update-agent.log" \
            "$qubes_update_log_dir/$template_name.log" \
            "$qubes_update_log_dir/update-$template_name.log" \
            "$qubes_legacy_log_dir/qubes-vm-update.log" \
            "$qubes_legacy_log_dir/update-$template_name.log"
        find "$qubes_update_log_dir" "$qubes_legacy_log_dir" \
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
            "$qubes_legacy_log_dir"/*) prefix=dom0-qubes-legacy ;;
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
           -name 'dom0-qubes-legacy-*.log' -o \
           -name 'dom0-qubes-log-*.log' \) \
        -print 2>/dev/null || true
}

logs_have_fixed() {
    local pattern="$1"
    local log

    while IFS= read -r log; do
        [ -n "$log" ] || continue
        [ -r "$log" ] || continue
        grep -Fq "$pattern" "$log" && return 0
    done < <(update_evidence_logs | sort -u)
    return 1
}

logs_have_regex() {
    local pattern="$1"
    local log

    while IFS= read -r log; do
        [ -n "$log" ] || continue
        [ -r "$log" ] || continue
        grep -Eq "$pattern" "$log" && return 0
    done < <(update_evidence_logs | sort -u)
    return 1
}

dump_log_tail() {
    local log

    for log in "$log_dir"/*.log; do
        [ -r "$log" ] || continue
        printf -- '--- %s tail ---\n' "${log##*/}" >&2
        tail -120 "$log" >&2 || true
    done
}

collect_guest_failure_logs() {
    local guest_log_script

    guest_log_script=$(cat <<'__QUBES_GUIX_GUEST__'
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
show_file_tail /tmp/qubes-guix-central-proxy-probe.err
show_file_tail /tmp/qubes-guix-central-proxy-probe.out
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
)

    qvm-run --pass-io --no-gui --user root "$template_name" \
        "sh -eu -c $(quote "$guest_log_script")" \
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

guest_preflight=$(cat <<'__QUBES_GUIX_GUEST__'
set -eu
proxy_probe_url=$1

proxy_probe_request() {
    case "$proxy_probe_url" in
        http://*)
            host=${proxy_probe_url#http://}
            host=${host%%/*}
            printf 'GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' \
                "$proxy_probe_url" "$host"
            ;;
        https://*)
            host=${proxy_probe_url#https://}
            host=${host%%/*}
            case "$host" in
                *:*) connect_host=$host ;;
                *) connect_host=$host:443 ;;
            esac
            printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' \
                "$connect_host" "$connect_host"
            ;;
        *)
            echo "unsupported proxy probe URL: $proxy_probe_url" >&2
            return 1
            ;;
    esac
}

check_no_direct_default_route() {
    if ip route show default 2>/dev/null | grep -q . ||
        ip -6 route show default 2>/dev/null | grep -q .; then
        echo 'source TemplateVM has a direct default route' >&2
        echo 'refusing to count this run as Qubes updates-proxy proof' >&2
        return 1
    fi
}

check_raw_proxy() {
    command -v socat >/dev/null 2>&1 || {
        echo 'socat not found in guest; cannot run raw proxy probe' >&2
        return 1
    }

    rm -f /tmp/qubes-guix-central-proxy-probe.out \
        /tmp/qubes-guix-central-proxy-probe.err
    set +e
    proxy_probe_request |
        timeout 60 socat -t 2 - TCP:127.0.0.1:8082 \
            >/tmp/qubes-guix-central-proxy-probe.out \
            2>/tmp/qubes-guix-central-proxy-probe.err
    proxy_probe_status=$?
    set -e

    first_line=$(sed -n '1s/\r$//p' \
        /tmp/qubes-guix-central-proxy-probe.out)
    if [ "$proxy_probe_status" -ne 0 ] && [ -z "$first_line" ]; then
        dump_raw_proxy_probe_failure
        return 1
    fi

    case "$first_line" in
        HTTP/*\ 2*|HTTP/*\ 3*) ;;
        *)
            echo "raw proxy probe did not return HTTP success: ${first_line:-<empty>}" >&2
            dump_raw_proxy_probe_failure
            return 1
            ;;
    esac
    echo "raw proxy probe passed: $first_line"
}

dump_raw_proxy_probe_failure() {
    printf 'raw proxy probe exit status: %s\n' "$proxy_probe_status" >&2
    printf 'raw proxy probe first response line: %s\n' "${first_line:-<empty>}" >&2
    if [ -s /tmp/qubes-guix-central-proxy-probe.out ]; then
        echo 'raw proxy probe response head:' >&2
        sed -n '1,20p' /tmp/qubes-guix-central-proxy-probe.out >&2 || true
    fi
    if [ -s /tmp/qubes-guix-central-proxy-probe.err ]; then
        echo 'raw proxy probe stderr:' >&2
        sed -n '1,40p' /tmp/qubes-guix-central-proxy-probe.err >&2 || true
    fi
    if command -v herd >/dev/null 2>&1; then
        echo 'qubes-updates-proxy-forwarder status after failed raw probe:' >&2
        herd status qubes-updates-proxy-forwarder >&2 || true
    fi
    if [ -r /var/log/qubes-updates-proxy-forwarder.log ]; then
        echo 'qubes-updates-proxy-forwarder log tail:' >&2
        tail -80 /var/log/qubes-updates-proxy-forwarder.log >&2 || true
        if grep -Fq 'Request refused' \
            /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null; then
            echo 'likely dom0 updates-proxy policy refusal:' >&2
            echo 'the guest forwarder reached qrexec-client-vm, but dom0 refused qubes.UpdatesProxy.' >&2
            echo 'check that the standard Qubes qubes.UpdatesProxy policy is present' >&2
            echo 'and that its default target, normally sys-net, exists and provides the updates proxy.' >&2
        fi
    fi
}

test -e /run/current-system
test -r /etc/config.scm
test -r /etc/guix/channels.scm
test -x /usr/bin/python3
test -x /run/qubes/bin/guix
test -r /etc/profile.d/qubes-guix-update-proxy.sh
. /usr/lib/qubes/init/functions
qsvc updates-proxy-setup >/dev/null
if qsvc qubes-updates-proxy >/dev/null 2>&1; then
    echo 'local qubes-updates-proxy service is enabled; TemplateVM should forward instead'
    exit 1
fi
herd status qubes-guix-update-proxy >/tmp/qubes-guix-update-proxy.status
grep -F 'It is stopped' /tmp/qubes-guix-update-proxy.status >/dev/null
herd status qubes-updates-proxy-forwarder >/tmp/qubes-updates-proxy-forwarder.status
grep -F 'It is running' /tmp/qubes-updates-proxy-forwarder.status >/dev/null
check_no_direct_default_route
check_raw_proxy
__QUBES_GUIX_GUEST__
)

set +e
qvm-run --pass-io --no-gui --user root "$template_name" \
    "cat >/tmp/qubes-guix-central-vmupdate-preflight.sh <<'__QUBES_GUIX_TEST__'
$guest_preflight
__QUBES_GUIX_TEST__
chmod 0700 /tmp/qubes-guix-central-vmupdate-preflight.sh
/tmp/qubes-guix-central-vmupdate-preflight.sh $(quote "$proxy_probe_url")" \
    2>&1 | tee "$log_dir/preflight.log"
preflight_status=${PIPESTATUS[0]}
set -e

[ "$preflight_status" -eq 0 ] ||
    fail_with_logs "central updater preflight failed with status $preflight_status"

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
    --no-progress \
    2>&1 | tee "$update_log"
update_status=${PIPESTATUS[0]}
set -e

copy_qubes_update_logs

[ "$update_status" -eq 0 ] ||
    fail_with_logs "qubes-vm-update failed with status $update_status" 1

if logs_have_regex \
    'Only Debian, RedHat.*ArchLinux|NotImplementedError|Package manager not found|Request refused|qubes[.]UpdatesProxy'; then
    fail_with_logs "qubes-vm-update log shows unsupported Guix or update-proxy failure" 1
fi

logs_have_fixed 'Refreshing Guix channel metadata from master.' ||
    fail_with_logs "qubes-vm-update log did not show Guix refresh" 1
logs_have_fixed 'Reconfiguring Guix System from /etc/config.scm using master.' ||
    fail_with_logs "qubes-vm-update log did not show Guix system reconfigure" 1
logs_have_fixed 'Reconfigured Guix System.' ||
    fail_with_logs "qubes-vm-update log did not show successful Guix system reconfigure" 1
logs_have_fixed 'Updated packages:' ||
    fail_with_logs "qubes-vm-update log did not show package update metadata" 1

guest_postcheck=$(cat <<'__QUBES_GUIX_GUEST__'
set -eu
test -e /run/current-system
test -d /gnu/store
herd status guix-daemon >/tmp/qubes-guix-daemon.status
grep -F 'It is running' /tmp/qubes-guix-daemon.status >/dev/null
guix --version >/tmp/qubes-guix-version.out
__QUBES_GUIX_GUEST__
)

qvm-run --pass-io --no-gui --user root "$template_name" \
    "cat >/tmp/qubes-guix-central-vmupdate-postcheck.sh <<'__QUBES_GUIX_TEST__'
$guest_postcheck
__QUBES_GUIX_TEST__
chmod 0700 /tmp/qubes-guix-central-vmupdate-postcheck.sh
/tmp/qubes-guix-central-vmupdate-postcheck.sh" \
    2>&1 | tee "$log_dir/postcheck.log"

printf 'central Guix qubes-vm-update check passed: %s\n' "$template_name"
