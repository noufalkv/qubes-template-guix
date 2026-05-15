#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="/usr/sbin:/sbin:$PATH"
export PATH

required_commands=(
    awk
    cpio
    debugfs
    find
    mke2fs
    rpm2cpio
    rpmbuild
    sha256sum
    split
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
    printf 'warning: skipping RPM layout check; missing commands: %s\n' \
        "${missing[*]}" >&2
    exit 0
fi

work_dir="$(mktemp -d "$repo_root/work.rpm-layout.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

image="$work_dir/root.img"
image_tree="$work_dir/image-tree"
rpm_out="$work_dir/dist"
lifecycle_runner="$work_dir/lifecycle"
version="20000101"
release="1"

mkdir -p "$image_tree/etc" "$rpm_out"
ln -s "$repo_root/scripts/test-template-rpm-lifecycle-dom0.sh" "$lifecycle_runner"
printf 'guix rpm layout test\n' > "$image_tree/etc/guix-template-test"
truncate -s 64M "$image"
mke2fs -q -t ext4 -d "$image_tree" "$image"

check_template_rpm() {
    local template_name="$1"
    local appmenu_entry="$2"
    local extract_dir="$work_dir/extract-$template_name"
    local extracted_image_dir="$work_dir/extracted-image-$template_name"
    local combined_tar="$work_dir/$template_name-root.tar"
    local extracted_image="$extracted_image_dir/root.img"
    local rpm_file="$rpm_out/qubes-template-$template_name-$version-$release.noarch.rpm"
    local cpio_file="$work_dir/$template_name.cpio"
    local rpm_path
    local template_dir
    local part_count

    rpm_path="$(
        "$repo_root/scripts/package-native-template-rpm.sh" \
            --root-image "$image" \
            --name "$template_name" \
            --version "$version" \
            --release "$release" \
            --output-dir "$rpm_out" \
            --split-size 1M
    )"
    [ "$rpm_path" = "$rpm_file" ]
    [ -s "$rpm_file" ]

    "$lifecycle_runner" -m -r "$rpm_file" -e "$template_name" >/dev/null

    mkdir -p "$extract_dir"
    rpm2cpio "$rpm_file" > "$cpio_file"
    (
        cd "$extract_dir"
        cpio -idm --quiet < "$cpio_file"
    )

    template_dir="$extract_dir/var/lib/qubes/vm-templates/$template_name"
    [ -d "$template_dir" ]
    grep -qx 'virt-mode=pvh' "$template_dir/template.conf"
    grep -qx 'qrexec=1' "$template_dir/template.conf"
    grep -qx 'gui=1' "$template_dir/template.conf"
    grep -qx "$appmenu_entry" "$template_dir/whitelisted-appmenus.list"
    cmp -s "$template_dir/whitelisted-appmenus.list" \
        "$template_dir/vm-whitelisted-appmenus.list"
    cmp -s "$template_dir/whitelisted-appmenus.list" \
        "$template_dir/netvm-whitelisted-appmenus.list"
    [ -d "$template_dir/apps" ]
    [ -d "$template_dir/apps.templates" ]
    [ -d "$template_dir/apps.tempicons" ]
    [ -f "$template_dir/clean-volatile.img.tar" ]
    [ ! -e "$template_dir/root.img" ]
    [ ! -e "$template_dir/private.img" ]
    [ ! -e "$template_dir/volatile.img" ]

    part_count="$(find "$template_dir" -maxdepth 1 -name 'root.img.part.*' | wc -l)"
    [ "$part_count" -ge 1 ]
    cat "$template_dir"/root.img.part.* > "$combined_tar"
    mkdir -p "$extracted_image_dir"
    tar -C "$extracted_image_dir" -xf "$combined_tar"
    test_marker="$(debugfs -R 'cat /etc/guix-template-test' "$extracted_image" 2>/dev/null)"
    [ "$test_marker" = 'guix rpm layout test' ]

    printf 'native template RPM layout check passed: %s\n' "$rpm_file"
}

check_template_rpm guix xfce4-terminal.desktop
check_template_rpm guix-minimal xterm.desktop
