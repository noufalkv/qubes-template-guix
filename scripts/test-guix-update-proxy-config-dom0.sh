#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-config-dom0.sh [options]

Verify that a running Guix TemplateVM configures Guix tooling for the Qubes
updates proxy.  This checks the Qubes service flag, the generated guix wrapper,
the updates-proxy forwarder, and a daemon-backed Guix command.

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

qvm-check "$template_name" >/dev/null 2>&1 ||
    die "template does not exist: $template_name"

if ! qvm-check --running "$template_name" >/dev/null 2>&1; then
    qvm-start "$template_name" >/dev/null
fi

guest_script=$(cat <<'__QUBES_GUIX_GUEST__'
set -eu

proxy=http://127.0.0.1:8082/
profile=/etc/profile.d/qubes-guix-update-proxy.sh
wrapper=/run/qubes/bin/guix

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
    echo '== proxy wrapper/profile =='
    ls -l "$wrapper" "$profile" 2>&1 || true
    sed -n '1,120p' "$wrapper" 2>/dev/null || true
    sed -n '1,120p' "$profile" 2>/dev/null || true
    echo '== shepherd status =='
    herd status qubes-guix-update-proxy 2>&1 || true
    herd status qubes-updates-proxy-forwarder 2>&1 || true
    herd status guix-daemon 2>&1 || true
    echo '== guix-daemon processes =='
    ps -ef | grep '[g]uix-daemon' 2>&1 || true
    pid=$(find_guix_daemon_pid)
    if [ -n "$pid" ]; then
        echo "== guix-daemon environment pid=$pid =="
        tr '\0' '\n' <"/proc/$pid/environ" |
            grep -E '^(http|https)_proxy=' || true
    fi
    echo '== guix gc stderr =='
    cat /tmp/qubes-guix-gc-roots.err 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-guix-update-proxy.log 2>/dev/null || true
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
echo 'checking generated Guix proxy wrapper and profile hook'
test -x "$wrapper"
test -r "$profile"
grep -Fq 'http_proxy="${http_proxy:-$proxy}"' "$wrapper"
grep -Fq 'https_proxy="${https_proxy:-$proxy}"' "$wrapper"
grep -Fq 'export PATH=/run/qubes/bin:$PATH' "$profile"
"$wrapper" --version >/dev/null

# Force a daemon interaction so socket activation starts the declaratively
# configured guix-daemon service.
echo 'starting guix-daemon through wrapped guix command'
if ! "$wrapper" gc --list-roots >/tmp/qubes-guix-gc-roots.out \
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
    tr '\0' '\n' <"/proc/$pid/environ" |
        grep -E '^(http|https)_proxy=' || true
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
