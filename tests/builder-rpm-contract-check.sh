#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="/usr/sbin:/sbin:$PATH"
export PATH

required_commands=(
    cpio
    debugfs
    find
    mke2fs
    rpm
    rpm2cpio
    rpmbuild
    split
    stat
    tar
    truncate
)

missing=()
for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing+=("$command_name")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    printf 'Builder RPM contract check missing required commands: %s\n' \
        "${missing[*]}" >&2
    exit 1
fi

work_dir="$(mktemp -d "$repo_root/work.builder-rpm.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

version="4.3.0"
timestamp="2000-01-02T03:04Z"
release="200001020304"

check_adapter_rpm() {
    local template_name="$1"
    local template_flavor="$2"
    local marker="$3"
    shift 3
    local appmenu_entries=("$@")
    local artifacts="$work_dir/artifacts-$template_name"
    local image_tree="$work_dir/image-tree-$template_name"
    local root_image="$artifacts/qubeized_images/$template_name/root.img"
    local rpm_file="$artifacts/rpmbuild/RPMS/noarch/qubes-template-$template_name-$version-$release.noarch.rpm"
    local rpm_path
    local extract_dir="$work_dir/extract-$template_name"
    local template_dir="$extract_dir/var/lib/qubes/vm-templates/$template_name"
    local cpio_file="$work_dir/$template_name.cpio"
    local combined_tar="$work_dir/$template_name-root.tar"
    local extracted_image_dir="$work_dir/extracted-image-$template_name"
    local extracted_image="$extracted_image_dir/root.img"
    local test_marker

    mkdir -p "$(dirname -- "$root_image")" "$image_tree/etc"
    printf '%s\n' "$marker" > "$image_tree/etc/guix-builder-adapter-test"
    truncate -s 64M "$root_image"
    mke2fs -q -t ext4 -d "$image_tree" "$root_image"

    rpm_path="$(env \
        ARTIFACTS_DIR="$artifacts" \
        TEMPLATE_NAME="$template_name" \
        TEMPLATE_FLAVOR="$template_flavor" \
        TEMPLATE_VERSION="$version" \
        TEMPLATE_TIMESTAMP="$timestamp" \
        "$repo_root/scripts/builder-v2-template-adapter.sh" build-rpm)"

    [ "$rpm_path" = "$rpm_file" ]
    [ -s "$rpm_file" ]
    "$repo_root/scripts/test-template-rpm-lifecycle-dom0.sh" \
        --metadata-only \
        --rpm "$rpm_file" \
        --expect-template "$template_name" >/dev/null

    mkdir -p "$extract_dir"
    rpm2cpio "$rpm_file" > "$cpio_file"
    (
        cd "$extract_dir"
        cpio -idm --quiet < "$cpio_file"
    )

    [ -d "$template_dir" ]
    grep -qx 'virt-mode=pvh' "$template_dir/template.conf"
    grep -qx 'qrexec=1' "$template_dir/template.conf"
    grep -qx 'gui=1' "$template_dir/template.conf"
    for appmenu_entry in "${appmenu_entries[@]}"; do
        grep -qx "$appmenu_entry" "$template_dir/whitelisted-appmenus.list"
    done
    [ ! -e "$template_dir/root.img" ]
    [ ! -e "$template_dir/private.img" ]
    [ ! -e "$template_dir/volatile.img" ]

    cat "$template_dir"/root.img.part.* > "$combined_tar"
    mkdir -p "$extracted_image_dir"
    tar -C "$extracted_image_dir" -xf "$combined_tar"
    [ "$(stat -c '%s' "$extracted_image")" = "$(stat -c '%s' "$root_image")" ]
    test_marker="$(debugfs -R 'cat /etc/guix-builder-adapter-test' \
        "$extracted_image" 2>/dev/null)"
    [ "$test_marker" = "$marker" ]

    printf 'Builder RPM contract check passed: %s\n' "$rpm_file"
}

check_adapter_rpm guix "" "normal Builder adapter root" \
    org.gnome.Evince.desktop \
    org.xfce.mousepad.desktop \
    thunar.desktop \
    xfce4-terminal.desktop
check_adapter_rpm guix-minimal minimal "minimal Builder adapter root" xterm.desktop
