#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

probe_url=${1:-https://guix.gnu.org/}
probe_timeout=${2:-60}
proxy_stdout=/tmp/qubes-guix-proxy-preflight.out
proxy_stderr=/tmp/qubes-guix-proxy-preflight.err

die() {
    echo "$*" >&2
    exit 1
}

validate_options() {
    [ "$#" -le 2 ] ||
        die "usage: guest-update-proxy-preflight.sh [URL] [TIMEOUT]"

    case "$probe_timeout" in
        *[!0-9]*|'')
            die "invalid proxy probe timeout: $probe_timeout"
            ;;
    esac
    [ "$probe_timeout" -gt 0 ] ||
        die "proxy probe timeout must be greater than zero: $probe_timeout"
}

diagnose_proxy_preflight() {
    echo '== qubes service flags =='
    ls -la /run/qubes-service /var/run/qubes-service 2>&1 || true
    echo '== shepherd status =='
    herd status qubes-updates-proxy-forwarder 2>&1 || true
    echo '== raw proxy probe stdout =='
    cat "$proxy_stdout" 2>/dev/null || true
    echo '== raw proxy probe stderr =='
    cat "$proxy_stderr" 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null || true
    if grep -Fq 'Request refused' /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null; then
        echo '== likely dom0 updates-proxy policy refusal =='
        echo 'The guest forwarder reached qrexec-client-vm, but dom0 refused qubes.UpdatesProxy.'
        echo 'Check that the standard Qubes qubes.UpdatesProxy policy is present'
        echo 'and that its default target, normally sys-net, exists and provides the updates proxy.'
    fi
}

proxy_probe_request() {
    case "$probe_url" in
        http://*)
            host=${probe_url#http://}
            host=${host%%/*}
            printf 'GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' \
                "$probe_url" "$host"
            ;;
        https://*)
            host=${probe_url#https://}
            host=${host%%/*}
            case "$host" in
                *:*) connect_host=$host ;;
                *) connect_host=$host:443 ;;
            esac
            printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' \
                "$connect_host" "$connect_host"
            ;;
        *)
            echo "unsupported proxy probe URL: $probe_url" >&2
            return 1
            ;;
    esac
}

check_no_direct_default_route() {
    if ip route show default 2>/dev/null | grep -q . ||
        ip -6 route show default 2>/dev/null | grep -q .; then
        echo 'source TemplateVM has a direct default route' >&2
        echo 'refusing to count this run as Qubes updates-proxy evidence' >&2
        return 1
    fi
}

check_raw_proxy() {
    command -v socat >/dev/null 2>&1 || {
        echo 'socat not found in guest; cannot run raw proxy probe' >&2
        return 1
    }

    rm -f "$proxy_stdout" "$proxy_stderr"
    set +e
    proxy_probe_request |
        timeout "$probe_timeout" socat -t 2 - TCP:127.0.0.1:8082 \
            >"$proxy_stdout" 2>"$proxy_stderr"
    proxy_status=$?
    set -e

    first_line=$(sed -n '1s/\r$//p' "$proxy_stdout")
    if [ "$proxy_status" -ne 0 ] && [ -z "$first_line" ]; then
        return 1
    fi

    case "$first_line" in
        HTTP/*\ 2*|HTTP/*\ 3*) ;;
        *)
            echo "raw proxy probe did not return HTTP success: ${first_line:-<empty>}" >&2
            return 1
            ;;
    esac

    echo "raw proxy probe passed: $first_line"
}

check_service_state() {
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
}

check_guix_proxy_policy() {
    echo 'checking Guix is not hidden behind a global wrapper'
    test ! -e /run/qubes/bin/guix
    test ! -e /etc/profile.d/qubes-guix-update-proxy.sh

    echo 'checking source TemplateVM has no direct default route'
    check_no_direct_default_route
}

main() {
    validate_options "$@"
    check_service_state
    check_guix_proxy_policy

    echo "checking raw Qubes updates proxy path: $probe_url"
    check_raw_proxy

    printf 'Guix update-proxy preflight passed\n'
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "Guix update-proxy preflight failed with status $rc"; diagnose_proxy_preflight; fi; exit "$rc"' EXIT
main "$@"
