#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-download-dom0.sh [options]

Run a real Guix client download through a Guix TemplateVM's Qubes updates proxy.
This is intentionally separate from the configuration verifier because it
depends on an update-proxy target with working Internet access.

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

qvm-check "$template_name" >/dev/null 2>&1 ||
    die "template does not exist: $template_name"

if ! qvm-check --running "$template_name" >/dev/null 2>&1; then
    qvm-start "$template_name" >/dev/null
fi

guest_script=$(cat <<'__QUBES_GUIX_GUEST__'
set -eu

download_url=$1
download_timeout=$2
wrapper=/run/qubes/bin/guix
profile=/etc/profile.d/qubes-guix-update-proxy.sh
payload=/tmp/qubes-guix-proxy-download.payload
stdout=/tmp/qubes-guix-proxy-download.out
stderr=/tmp/qubes-guix-proxy-download.err

diagnose_proxy_download() {
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
    echo '== download stdout =='
    cat "$stdout" 2>/dev/null || true
    echo '== download stderr =='
    cat "$stderr" 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-guix-update-proxy.log 2>/dev/null || true
    cat /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null || true
    if grep -Fq 'Request refused' /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null; then
        echo '== likely dom0 updates-proxy policy refusal =='
        echo 'The guest forwarder reached qrexec-client-vm, but dom0 refused qubes.UpdatesProxy.'
        echo 'Check that the standard Qubes qubes.UpdatesProxy policy is present'
        echo 'and that its default target, normally sys-net, exists and can'
        echo 'provide the updates proxy.'
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

echo 'checking generated Guix proxy wrapper'
test -x "$wrapper"
test -r "$profile"

rm -f "$payload" "$stdout" "$stderr"
echo "running guix download through Qubes updates proxy: $download_url"
if ! timeout "$download_timeout" "$wrapper" download \
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
