#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-config-dom0.sh [options]

Verify that a running Guix TemplateVM wires the Qubes updates-proxy forwarder
without forcing ordinary Guix tooling through an inactive local proxy.  This
checks the Qubes service flag, the forwarder, and the daemon-backed Guix path.

Options:
  -t, --template NAME       TemplateVM name. Default: guix.
  -h, --help                Show this help.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'test-guix-update-proxy-config failed: %s\n' "$*" >&2
    exit 1
}

template_name=guix

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--template)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            template_name=$2
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

command -v qvm-run >/dev/null 2>&1 || die "qvm-run not found"
command -v qvm-check >/dev/null 2>&1 || die "qvm-check not found"
command -v qvm-start >/dev/null 2>&1 || die "qvm-start not found"
command -v timeout >/dev/null 2>&1 || die "timeout not found"

wait_for_qrexec() {
    vm=$1
    attempt=1
    while [ "$attempt" -le 90 ]; do
        if timeout 10 qvm-run --pass-io --no-gui --user root "$vm" ':' \
            >/dev/null 2>&1; then
            return 0
        fi
        printf 'waiting for qrexec in %s (%s/90)\n' "$vm" "$attempt" >&2
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

qvm-check "$template_name" >/dev/null 2>&1 ||
    die "template does not exist: $template_name"

if ! qvm-check --running "$template_name" >/dev/null 2>&1; then
    qvm-start "$template_name" >/dev/null
fi
wait_for_qrexec "$template_name" ||
    die "qrexec did not become ready in template: $template_name"

guest_script=$(cat <<'__QUBES_GUIX_GUEST__'
set -eu

guix=/run/current-system/profile/bin/guix

find_guix_daemon_pid() {
    if command -v pidof >/dev/null 2>&1; then
        set -- $(pidof guix-daemon 2>/dev/null || true)
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$1"
            return 0
        fi
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f '[g]uix-daemon' 2>/dev/null | head -n 1 || true
    fi
}

diagnose_proxy_config() {
    echo '== qubes service flags =='
    ls -la /run/qubes-service /var/run/qubes-service 2>&1 || true
    echo '== shepherd status =='
    herd status qubes-updates-proxy-forwarder 2>&1 || true
    herd status guix-daemon 2>&1 || true
    echo '== guix-daemon processes =='
    ps -ef | grep '[g]uix-daemon' 2>&1 || true
    pid=$(find_guix_daemon_pid)
    if [ -n "$pid" ]; then
        echo "== guix-daemon environment pid=$pid =="
        tr '\0' '\n' <"/proc/$pid/environ" |
            grep -E '^(http|https|all|no)_proxy=|^(HTTP|HTTPS|ALL|NO)_PROXY=' || true
    fi
    echo '== guix version stderr =='
    cat /tmp/qubes-guix-version.err 2>/dev/null || true
    echo '== guix gc stderr =='
    cat /tmp/qubes-guix-gc-roots.err 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null || true
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "guix update proxy config check failed with status $rc"; diagnose_proxy_config; fi; exit "$rc"' EXIT

echo 'checking Qubes updates-proxy service flag'
. /usr/lib/qubes/init/functions
qsvc updates-proxy-setup >/dev/null
if qsvc qubes-updates-proxy >/dev/null 2>&1; then
    echo 'local qubes-updates-proxy service is enabled; TemplateVM should forward instead'
    exit 1
fi
echo 'checking Qubes updates-proxy forwarder'
herd status qubes-updates-proxy-forwarder >/tmp/qubes-updates-proxy-forwarder.status
cat /tmp/qubes-updates-proxy-forwarder.status
grep -F 'It is running' /tmp/qubes-updates-proxy-forwarder.status >/dev/null
echo 'checking Guix is not hidden behind a global wrapper'
test ! -e /run/qubes/bin/guix
test ! -e /etc/profile.d/qubes-guix-update-proxy.sh

echo 'checking Guix client command'
/run/current-system/profile/bin/env \
    -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
    "$guix" --version \
    >/tmp/qubes-guix-version.out \
    2>/tmp/qubes-guix-version.err

# Force a daemon interaction so socket activation starts guix-daemon.
echo 'starting guix-daemon through direct guix command'
if ! "$guix" gc --list-roots >/tmp/qubes-guix-gc-roots.out \
    2>/tmp/qubes-guix-gc-roots.err; then
    echo 'guix gc --list-roots failed'
    cat /tmp/qubes-guix-gc-roots.err 2>/dev/null || true
    exit 1
fi

echo 'checking guix-daemon service state'
herd status guix-daemon >/tmp/qubes-guix-daemon.status
cat /tmp/qubes-guix-daemon.status
grep -F 'It is running' /tmp/qubes-guix-daemon.status >/dev/null

pid=$(find_guix_daemon_pid || true)
if [ -n "$pid" ]; then
    echo "observed guix-daemon environment pid=$pid"
    tr '\0' '\n' <"/proc/$pid/environ" \
        >/tmp/qubes-guix-daemon.environ
    grep -E '^(http|https|all|no)_proxy=|^(HTTP|HTTPS|ALL|NO)_PROXY=' \
        /tmp/qubes-guix-daemon.environ || true
    if grep -E '^(http|https|all)_proxy=|^(HTTP|HTTPS|ALL)_PROXY=' \
        /tmp/qubes-guix-daemon.environ >/dev/null; then
        echo 'guix-daemon must not inherit Qubes updates-proxy environment' >&2
        exit 1
    fi
    if ps -ef | grep '[g]uix-daemon' | grep -F '127.0.0.1:8082' >/dev/null; then
        echo 'guix-daemon command line must not force the local updates proxy' >&2
        exit 1
    fi
else
    echo 'guix-daemon has no persistent process after command; socket-activated service is idle'
    grep -F 'Systemd-style service listening on' /tmp/qubes-guix-daemon.status >/dev/null
    grep -F '/var/guix/daemon-socket/socket' /tmp/qubes-guix-daemon.status >/dev/null
fi

printf 'guix update proxy config check passed\n'
__QUBES_GUIX_GUEST__
)

qvm-run --pass-io --no-gui --user root "$template_name" \
    "cat >/tmp/qubes-guix-update-proxy-config-test.sh <<'__QUBES_GUIX_TEST__'
$guest_script
__QUBES_GUIX_TEST__
chmod 0700 /tmp/qubes-guix-update-proxy-config-test.sh
/tmp/qubes-guix-update-proxy-config-test.sh"
