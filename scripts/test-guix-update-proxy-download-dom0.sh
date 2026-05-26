#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-download-dom0.sh [options]

Run a real Guix client download through a Guix TemplateVM's Qubes updates proxy.
This is intentionally separate from the configuration verifier because it
depends on an update-proxy target with working Internet access.  The script
first probes the raw Qubes proxy path, then runs guix download through the
generated Guix wrapper.

Options:
  -t, --template NAME       TemplateVM name. Default: guix.
  -u, --download-url URL    URL to fetch with guix download.
                            Default: https://guix.gnu.org/
      --timeout SECONDS     Guest-side timeout for the download. Default: 240.
  -h, --help                Show this help.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'test-guix-update-proxy-download failed: %s\n' "$*" >&2
    exit 1
}

quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

template_name=guix
download_url=${GUIX_PROXY_DOWNLOAD_URL:-https://guix.gnu.org/}
download_timeout=${GUIX_PROXY_DOWNLOAD_TIMEOUT:-240}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--template)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            template_name=$2
            shift 2
            ;;
        -u|--download-url)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            download_url=$2
            shift 2
            ;;
        --timeout)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            download_timeout=$2
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

case "$download_timeout" in
    *[!0-9]*|'')
        die "timeout must be a positive integer"
        ;;
esac
[ "$download_timeout" -gt 0 ] || die "timeout must be greater than zero"

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

download_url=$1
download_timeout=$2
payload=/tmp/qubes-guix-proxy-download.payload
stdout=/tmp/qubes-guix-proxy-download.out
stderr=/tmp/qubes-guix-proxy-download.err
probe_stdout=/tmp/qubes-guix-proxy-probe.out
probe_stderr=/tmp/qubes-guix-proxy-probe.err
proxy=http://127.0.0.1:8082/
guix=/run/current-system/profile/bin/guix

diagnose_proxy_download() {
    echo '== qubes service flags =='
    ls -la /run/qubes-service /var/run/qubes-service 2>&1 || true
    echo '== shepherd status =='
    herd status qubes-updates-proxy-forwarder 2>&1 || true
    herd status guix-daemon 2>&1 || true
    echo '== download stdout =='
    cat "$stdout" 2>/dev/null || true
    echo '== download stderr =='
    cat "$stderr" 2>/dev/null || true
    echo '== raw proxy probe stdout =='
    cat "$probe_stdout" 2>/dev/null || true
    echo '== raw proxy probe stderr =='
    cat "$probe_stderr" 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null || true
    if grep -Fq 'Request refused' /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null; then
        echo '== likely dom0 updates-proxy policy refusal =='
        echo 'The guest forwarder reached qrexec-client-vm, but dom0 refused qubes.UpdatesProxy.'
        echo 'Check that the standard Qubes qubes.UpdatesProxy policy is present'
        echo 'and that its default target, normally sys-net, exists and can'
        echo 'provide the updates proxy.'
    fi
}

proxy_probe_request() {
    case "$download_url" in
        http://*)
            host=${download_url#http://}
            host=${host%%/*}
            printf 'GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' \
                "$download_url" "$host"
            ;;
        https://*)
            host=${download_url#https://}
            host=${host%%/*}
            case "$host" in
                *:*) connect_host=$host ;;
                *) connect_host=$host:443 ;;
            esac
            printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' \
                "$connect_host" "$connect_host"
            ;;
        *)
            echo "unsupported proxy probe URL: $download_url" >&2
            return 1
            ;;
    esac
}

check_raw_proxy() {
    command -v socat >/dev/null 2>&1 || {
        echo 'socat not found in guest; cannot run raw proxy probe'
        return 1
    }

    proxy_probe_timeout=60
    if [ "$download_timeout" -lt "$proxy_probe_timeout" ]; then
        proxy_probe_timeout=$download_timeout
    fi

    case "$download_url" in
        http://*|https://*) ;;
        *)
            echo "unsupported proxy probe URL: $download_url" >&2
            return 1
            ;;
    esac

    rm -f "$probe_stdout" "$probe_stderr"
    set +e
    proxy_probe_request |
        timeout "$proxy_probe_timeout" socat -t 2 - TCP:127.0.0.1:8082 \
            >"$probe_stdout" 2>"$probe_stderr"
    proxy_probe_status=$?
    set -e

    first_line=$(sed -n '1s/\r$//p' "$probe_stdout")
    if [ "$proxy_probe_status" -ne 0 ] && [ -z "$first_line" ]; then
        cat "$probe_stderr" 2>/dev/null || true
        return 1
    fi

    case "$first_line" in
        HTTP/*\ 2*|HTTP/*\ 3*) ;;
        *)
            echo "raw proxy probe did not return HTTP success: $first_line" >&2
            return 1
            ;;
    esac
    echo "raw proxy probe passed: $first_line"
}

check_no_direct_default_route() {
    if ip route show default 2>/dev/null | grep -q . ||
        ip -6 route show default 2>/dev/null | grep -q .; then
        echo 'source TemplateVM has a direct default route' >&2
        echo 'refusing to count this run as Qubes updates-proxy proof' >&2
        return 1
    fi
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "guix update proxy download check failed with status $rc"; diagnose_proxy_download; fi; exit "$rc"' EXIT

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

echo 'checking source TemplateVM has no direct default route'
check_no_direct_default_route

echo "checking raw Qubes updates proxy path: $download_url"
check_raw_proxy

rm -f "$payload" "$stdout" "$stderr"
echo "running guix download through Qubes updates proxy: $download_url"
if ! timeout "$download_timeout" /run/current-system/profile/bin/env \
    http_proxy="$proxy" https_proxy="$proxy" \
    HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" \
    all_proxy="$proxy" ALL_PROXY="$proxy" \
    no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
    "$guix" download \
    --output="$payload" "$download_url" >"$stdout" 2>"$stderr"; then
    cat "$stderr" 2>/dev/null || true
    exit 1
fi

test -s "$payload"
bytes=$(wc -c <"$payload" | tr -d ' ')
echo "downloaded $bytes bytes"
cat "$stdout"
printf 'guix update proxy download check passed\n'
__QUBES_GUIX_GUEST__
)

qvm-run --pass-io --no-gui --user root "$template_name" \
    "cat >/tmp/qubes-guix-update-proxy-download-test.sh <<'__QUBES_GUIX_TEST__'
$guest_script
__QUBES_GUIX_TEST__
chmod 0700 /tmp/qubes-guix-update-proxy-download-test.sh
/tmp/qubes-guix-update-proxy-download-test.sh $(quote "$download_url") $(quote "$download_timeout")"
