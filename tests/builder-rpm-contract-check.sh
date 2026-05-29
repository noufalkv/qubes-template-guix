#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="/usr/sbin:/sbin:$PATH"
export PATH

work_dir=""
version="4.3.0"
timestamp="2000-01-02T03:04Z"
release="200001020304"

cleanup() {
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

prepare_workdir() {
    work_dir="$(mktemp -d "$repo_root/work.builder-rpm.XXXXXX")"
}

check_adapter_rpm() {
    local requested_name="$1"
    local template_flavor="$2"
    local template_name="$3"
    local case_name="$requested_name-${template_flavor:-default}"
    local artifacts="$work_dir/artifacts-$case_name"
    local image_tree="$work_dir/image-tree-$case_name"
    local root_image="$artifacts/qubeized_images/$template_name/root.img"
    local rpm_file="$artifacts/rpmbuild/RPMS/noarch/qubes-template-$template_name-$version-$release.noarch.rpm"
    local rpm_path

    mkdir -p "$(dirname -- "$root_image")" "$image_tree/etc"
    printf 'Builder adapter root for %s\n' "$template_name" \
        > "$image_tree/etc/guix-builder-adapter-test"
    truncate -s 64M "$root_image"
    mke2fs -q -t ext4 -d "$image_tree" "$root_image"

    rpm_path="$(env \
        ARTIFACTS_DIR="$artifacts" \
        TEMPLATE_NAME="$requested_name" \
        TEMPLATE_FLAVOR="$template_flavor" \
        TEMPLATE_VERSION="$version" \
        TEMPLATE_TIMESTAMP="$timestamp" \
        "$repo_root/scripts/builder-v2-template-adapter.sh" build-rpm)"

    [ "$rpm_path" = "$rpm_file" ]
    [ -s "$rpm_file" ]

    "$repo_root/tests/template-rpm-payload-check.sh" \
        --rpm "$rpm_file" \
        --template "$template_name" \
        --source-image "$root_image" \
        --work-dir "$work_dir/payload-$case_name" >/dev/null

    printf 'Builder RPM contract check passed: %s\n' "$rpm_file"
}

main() {
    prepare_workdir
    check_adapter_rpm guix "" guix
    check_adapter_rpm guix minimal guix-minimal
    check_adapter_rpm guix-minimal minimal guix-minimal
    check_adapter_rpm minimal "" guix-minimal
}

main "$@"
