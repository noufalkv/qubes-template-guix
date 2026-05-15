#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

template_name="${TEMPLATE_NAME:-guix}"
target_vm="${UPDATE_PROXY_TARGET:-sys-net}"
create_target=0
install_stub=0
keep_target=0

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-update-proxy-default-target-dom0.sh [options]

Exercise the Qubes default updates-proxy target path from a TemplateVM.

Options:
  -t, --template NAME       Source TemplateVM to probe. Default: guix.
  -T, --target NAME         Expected default update target. Default: sys-net.
  -c, --create-target       Create TARGET as a temporary VM if missing.
  -s, --install-stub        Install a temporary qubes.UpdatesProxy stub in a
                            newly created standalone TARGET.
                            Intended for disposable/nested dom0 tests.
  -k, --keep-target         Do not remove a target created by this script.
  -h, --help                Show this help.

The script does not add or override dom0 qrexec policy.  A pass therefore
requires the source template's local 127.0.0.1:8082 listener to forward through
the existing Qubes qubes.UpdatesProxy policy and its default target selection.
Use --install-stub only with --create-target.  The script refuses to install a
stub into an existing target, because that would modify a real update qube.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--template)
            template_name="${2:-}"
            shift 2
            ;;
        -T|--target)
            target_vm="${2:-}"
            shift 2
            ;;
        -c|--create-target)
            create_target=1
            shift
            ;;
        -s|--install-stub)
            install_stub=1
            shift
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
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$template_name" ] || die "empty template name"
[ -n "$target_vm" ] || die "empty target VM name"

need qvm-create
need qvm-ls
need qvm-prefs
need qvm-remove
need qvm-run
need qvm-shutdown

vm_exists() {
    qvm-ls --raw-list 2>/dev/null | grep -Fxq "$1"
}

created_target=0
target_preexisting=0
cleanup() {
    if [ "$created_target" -eq 1 ] && [ "$keep_target" -eq 0 ]; then
        qvm-shutdown --wait "$target_vm" >/dev/null 2>&1 || true
        qvm-remove --force "$target_vm" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

vm_exists "$template_name" || die "template VM does not exist: $template_name"
[ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
    die "source is not a TemplateVM: $template_name"

if ! vm_exists "$target_vm"; then
    [ "$create_target" -eq 1 ] ||
        die "target VM does not exist: $target_vm; pass --create-target in a disposable review dom0"
    if [ "$install_stub" -eq 1 ]; then
        qvm-create -C StandaloneVM -t "$template_name" --label red "$target_vm"
    else
        qvm-create -C AppVM -t "$template_name" --label red "$target_vm"
    fi
    created_target=1
else
    target_preexisting=1
fi

if [ "$install_stub" -eq 1 ]; then
    [ "$target_preexisting" -eq 0 ] ||
        die "refusing to install a stub into existing target: $target_vm"
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
fi

request='GET / HTTP/1.1\r\nHost: qubes-guix-test\r\nConnection: close\r\n\r\n'
set +e
response="$(
    printf '%b' "$request" |
        qvm-run --pass-io --no-gui "$template_name" \
            'timeout 30 socat - TCP:127.0.0.1:8082' 2>&1
)"
probe_status="$?"
set -e

printf '%s\n' "$response"
[ "$probe_status" -eq 0 ] ||
    die "updates proxy probe command failed with status $probe_status"
printf '%s\n' "$response" | grep -Fq 'HTTP/1.1 200 OK' ||
    die "updates proxy did not return HTTP 200 through default target"
printf '%s\n' "$response" | grep -Fxq 'OK' ||
    die "updates proxy response did not include expected body"

printf 'default updates-proxy target check passed: %s -> %s\n' \
    "$template_name" "$target_vm"
