#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

build_hello="${BUILD_HELLO:-0}"
template_name=""

usage() {
    cat <<'EOF'
Usage: test-foreign-guix-template-dom0.sh [--build-hello] TEMPLATE

Runs dom0-side smoke tests against a Guix-enabled Qubes template.
EOF
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
        --build-hello)
            build_hello=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            [ -z "$template_name" ] || die "unexpected extra argument: $1"
            template_name="$1"
            shift
            ;;
    esac
done

[ -n "$template_name" ] || die "missing TEMPLATE argument"

need qvm-ls
need qvm-run
need qvm-start

qvm-ls --raw-list | grep -Fxq "$template_name" || die "template does not exist: $template_name"

qvm-start "$template_name" >/dev/null 2>&1 || true

qvm-run --no-gui --pass-io --user root "$template_name" 'test -f /etc/qubes-guix-template.env'
qvm-run --no-gui --pass-io --user root "$template_name" 'guix --version'
qvm-run --no-gui --pass-io --user root "$template_name" 'systemctl is-active guix-daemon || service guix-daemon status'
qvm-run --no-gui --pass-io --user root "$template_name" 'guix package -A hello >/dev/null'
qvm-run --no-gui --pass-io "$template_name" 'guix --version'

if [ "$build_hello" -eq 1 ]; then
    qvm-run --no-gui --pass-io --user root "$template_name" 'guix build hello --no-grafts'
fi

printf 'Guix template smoke tests passed for %s\n' "$template_name"
