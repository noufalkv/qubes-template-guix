#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-config-dom0.sh [options]

Verify that a running Guix TemplateVM configures Guix tooling for the Qubes
updates proxy.  This checks the Qubes service flag, the generated guix wrapper,
and guix-daemon's proxy environment after a daemon command starts it.

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

qsvc updates-proxy-setup >/dev/null
test -x "$wrapper"
test -r "$profile"
grep -Fq 'export PATH=/run/qubes/bin:$PATH' "$profile"
"$wrapper" --version >/dev/null

# Force a daemon interaction so socket activation starts guix-daemon with the
# proxy environment produced by the Shepherd set-http-proxy action.
"$wrapper" gc --list-roots >/dev/null

pid=$(pgrep -x guix-daemon | head -n 1)
test -n "$pid"
tr '\0' '\n' <"/proc/$pid/environ" | grep -Fx "http_proxy=$proxy" >/dev/null
tr '\0' '\n' <"/proc/$pid/environ" | grep -Fx "https_proxy=$proxy" >/dev/null

printf 'guix update proxy config check passed\n'
__QUBES_GUIX_GUEST__
)

qvm-run --pass-io --no-gui --user root "$template_name" \
    "cat >/tmp/qubes-guix-update-proxy-config-test.sh <<'__QUBES_GUIX_TEST__'
$guest_script
__QUBES_GUIX_TEST__
chmod 0700 /tmp/qubes-guix-update-proxy-config-test.sh
/tmp/qubes-guix-update-proxy-config-test.sh"
