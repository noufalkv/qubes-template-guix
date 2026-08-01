#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared helpers for the Qubes template build/test scripts.  Sourced, not executed.
# Single source of truth for the small CLI helpers that were previously
# duplicated verbatim across scripts/ and tests/.

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

# Print the root.img size that Qubes Template Manager will read from the first
# 512 bytes of a split image archive.  qvm-template deliberately retains only
# this tar block before qvm-template-postprocess inspects field three.
qvm_template_root_header_size() {
    [ "$#" -eq 2 ] ||
        die "qvm_template_root_header_size requires FIRST_PART and HEADER"

    local first_part="$1"
    local header="$2"
    local listing
    local archived_name
    local archived_size

    [ -s "$first_part" ] || die "missing first root image part: $first_part"
    dd if="$first_part" of="$header" bs=512 count=1 status=none
    listing="$(LC_ALL=C tar -tvf "$header" 2>/dev/null || :)"
    archived_size="$(awk 'NR == 1 { print $3 }' <<< "$listing")"
    archived_name="$(awk 'NR == 1 { print $NF }' <<< "$listing")"

    [[ "$archived_size" =~ ^[0-9]+$ ]] ||
        die "qvm-template cannot read the root image size from part 00"
    case "$archived_name" in
        root.img|./root.img) ;;
        *) die "unexpected root image header entry: $archived_name" ;;
    esac
    printf '%s\n' "$archived_size"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}
