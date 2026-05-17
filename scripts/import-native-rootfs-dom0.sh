#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

image="root.img"
template_name="guix-native-test"
root_size="20G"
label="gray"

usage() {
    cat <<'EOF'
Usage: import-native-rootfs-dom0.sh [options]

Imports a native Guix root.img into a Qubes TemplateVM. Run from dom0.

Options:
  --image FILE      Root image to import. Default: root.img
  --name NAME       TemplateVM name. Default: guix-native-test
  --root-size SIZE  Root volume size before import. Default: 20G
  --label LABEL     Qubes label. Default: gray
  -h, --help        Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --image)
            require_arg "$@"
            image="$2"
            shift 2
            ;;
        --name)
            require_arg "$@"
            template_name="$2"
            shift 2
            ;;
        --root-size)
            require_arg "$@"
            root_size="$2"
            shift 2
            ;;
        --label)
            require_arg "$@"
            label="$2"
            shift 2
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

need qvm-ls
need qvm-create
need qvm-pool
need qvm-volume
need qvm-prefs
need truncate

[ -r "$image" ] || die "root image not readable: $image"

import_size_args=()
if [ -b "$image" ]; then
    need blockdev
    image_size="$(blockdev --getsize64 "$image")"
    [ -n "$image_size" ] && [ "$image_size" -gt 0 ] ||
        die "could not determine block device size: $image"
    import_size_args=(--size "$image_size")
fi

if qvm-ls --raw-list | grep -Fxq "$template_name"; then
    die "VM already exists: $template_name"
fi

if command -v qubes-prefs >/dev/null 2>&1 && [ -z "$(qubes-prefs default_kernel 2>/dev/null || true)" ]; then
    default_kernel="$(find /var/lib/qubes/vm-kernels -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
    [ -n "$default_kernel" ] || die "could not determine a Qubes VM kernel"
    qubes-prefs default_kernel "$default_kernel"
fi

template_kernel="${QUBES_TEMPLATE_KERNEL:-}"
if [ -z "$template_kernel" ] && command -v qubes-prefs >/dev/null 2>&1; then
    template_kernel="$(qubes-prefs default_kernel 2>/dev/null || true)"
fi
[ -n "$template_kernel" ] || template_kernel="default"

qvm-create --class TemplateVM --label "$label" "$template_name"
qvm-prefs "$template_name" virt_mode pvh
qvm-prefs "$template_name" kernel "$template_kernel"

root_volume="$template_name:root"

volume_info_field() {
    local key="$1"
    awk -v key="$key" '
        $1 == key {
            sub("^[^:[:space:]]+[[:space:]:]*", "", $0)
            print
            exit
        }'
}

resolve_file_pool_volume_path() {
    local info
    local path
    local pool
    local vid
    local pool_info
    local driver
    local dir_path
    local candidate

    info="$(qvm-volume info "$root_volume" 2>/dev/null || true)"
    path="$(printf '%s\n' "$info" | volume_info_field path)"
    if [ -n "$path" ] && [ -e "$path" ]; then
        printf '%s\n' "$path"
        return 0
    fi

    pool="$(printf '%s\n' "$info" | volume_info_field pool)"
    vid="$(printf '%s\n' "$info" | volume_info_field vid)"
    [ -n "$pool" ] && [ -n "$vid" ] || return 1

    pool_info="$(qvm-pool info "$pool" 2>/dev/null || true)"
    driver="$(printf '%s\n' "$pool_info" | volume_info_field driver)"
    dir_path="$(printf '%s\n' "$pool_info" | volume_info_field dir_path)"

    case "$driver" in
        file|file-reflink) ;;
        *) return 1 ;;
    esac
    [ -n "$dir_path" ] || return 1

    for candidate in "$dir_path/$vid.img" "$dir_path/$vid"; do
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

resize_fresh_root_volume() {
    local resize_log
    local backing_path

    resize_log="$(mktemp)"
    if qvm-volume resize -f "$root_volume" "$root_size" >"$resize_log" 2>&1; then
        rm -f "$resize_log"
        return 0
    fi

    cat "$resize_log" >&2
    rm -f "$resize_log"

    backing_path="$(resolve_file_pool_volume_path)" ||
        die "could not shrink $root_volume with qvm-volume and could not resolve a file-pool backing path"

    # Qubes file-pool backends can reject root-volume shrinking even with -f and
    # direct the operator to truncate the root volume manually.  This TemplateVM
    # has just been created and has not been started or imported into yet, so the
    # backing file is still empty VM storage owned by this script.
    printf 'truncating fresh root backing file before import: %s\n' "$backing_path" >&2
    truncate -s "$root_size" "$backing_path"
}

resize_fresh_root_volume
qvm-volume import "${import_size_args[@]}" "$template_name:root" "$image"

printf 'imported native Guix root image into TemplateVM: %s\n' "$template_name"
printf 'next smoke test: qvm-run --pass-io %q %q\n' "$template_name" 'qubesdb-read /name'
