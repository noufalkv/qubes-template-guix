#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

template_name="${TEMPLATE_NAME:-guix}"
target_vm="${UPDATE_PROXY_TARGET:-sys-net}"
download_url="${GUIX_PROXY_STUB_DOWNLOAD_URL:-http://qubes-guix-test/}"
download_timeout="${GUIX_PROXY_DOWNLOAD_TIMEOUT:-240}"
keep_target=0

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-stub-download-dom0.sh [options]

Run a real guix download through Qubes updates-proxy plumbing using a temporary
updates-proxy stub target.  This is intended for disposable nested-dom0/openQA
environments where a real sys-net update target may not exist.

Options:
  -t, --template NAME       Source TemplateVM. Default: guix.
  -T, --target NAME         Temporary update target. Default: sys-net.
  -u, --download-url URL    URL to request with guix download.
                            Default: http://qubes-guix-test/
      --timeout SECONDS     Guest-side download timeout. Default: 240.
  -k, --keep-target         Do not remove the temporary target.
  -h, --help                Show this help.

The script refuses to modify an existing TARGET.  It does not add or override
dom0 qrexec policy; the pass condition is that the source TemplateVM reaches
TARGET through the existing Qubes qubes.UpdatesProxy default-target policy.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'test-guix-update-proxy-stub-download failed: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--template)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            template_name=$2
            shift 2
            ;;
        -T|--target)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            target_vm=$2
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
        -k|--keep-target)
            keep_target=1
            shift
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
[ -n "$target_vm" ] || die "empty target VM name"
case "$download_timeout" in
    *[!0-9]*|'') die "timeout must be a positive integer" ;;
esac
[ "$download_timeout" -gt 0 ] || die "timeout must be greater than zero"

need qvm-create
need qvm-check
need qvm-ls
need qvm-kill
need qvm-prefs
need qvm-remove
need qvm-run
need qvm-shutdown

[ -x "$script_dir/test-guix-update-proxy-download-dom0.sh" ] ||
    die "missing executable sibling: test-guix-update-proxy-download-dom0.sh"

vm_exists() {
    qvm-ls --raw-list 2>/dev/null | grep -Fxq "$1"
}

cleanup() {
    if [ "${created_target:-0}" -eq 1 ] && [ "$keep_target" -eq 0 ]; then
        qvm-shutdown --wait "$target_vm" >/dev/null 2>&1 || true
        qvm-remove --force "$target_vm" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

vm_exists "$template_name" || die "template VM does not exist: $template_name"
[ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
    die "source is not a TemplateVM: $template_name"

if vm_exists "$target_vm"; then
    die "refusing to install an updates-proxy stub into existing target: $target_vm"
fi

if qvm-check --running "$template_name" >/dev/null 2>&1; then
    qvm-shutdown --wait "$template_name" >/dev/null 2>&1 ||
        qvm-kill "$template_name" >/dev/null 2>&1 ||
        die "could not stop running template before cloning: $template_name"
fi

qvm-create -C StandaloneVM -t "$template_name" --label red "$target_vm"
created_target=1

target_stub_command="$(cat <<'__QUBES_GUIX_TARGET_STUB__'
if [ -L /etc/qubes-rpc ]; then
    rm -f /etc/qubes-rpc
fi
mkdir -p /etc/qubes-rpc
cat >/etc/qubes-rpc/qubes.UpdatesProxy <<'__QUBES_GUIX_UPDATES_PROXY_STUB__'
#!/bin/sh
while IFS= read -r line; do
    [ "$line" = "$(printf '\r')" ] && break
    [ -z "$line" ] && break
done
printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK'
__QUBES_GUIX_UPDATES_PROXY_STUB__
chmod 0755 /etc/qubes-rpc/qubes.UpdatesProxy
__QUBES_GUIX_TARGET_STUB__
)"

qvm-run --pass-io --no-gui --user root "$target_vm" \
    "$target_stub_command" >/dev/null
qvm-run --pass-io --no-gui --user root "$target_vm" \
    'test -x /etc/qubes-rpc/qubes.UpdatesProxy' >/dev/null

"$script_dir/test-guix-update-proxy-download-dom0.sh" \
    --template "$template_name" \
    --download-url "$download_url" \
    --timeout "$download_timeout"

printf 'guix update proxy stub download check passed: %s -> %s\n' \
    "$template_name" "$target_vm"
