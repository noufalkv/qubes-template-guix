#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test-lib.sh
. "$repo_root/tests/test-lib.sh"

work_dir=""
image=""
image_tree=""
rpm_out=""
version="20000101"
release="1"

cleanup() {
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

prepare_root_image() {
    work_dir="$(mktemp -d "$repo_root/work.rpm-layout.XXXXXX")"
    image="$work_dir/root.img"
    image_tree="$work_dir/image-tree"
    rpm_out="$work_dir/dist"

    mkdir -p "$rpm_out"
    tlib_make_root_image "$image" "$image_tree" \
        "etc/guix-template-test" "Guix RPM layout root image"
}

check_template_rpm() {
    local template_name="$1"
    local rpm_file="$rpm_out/qubes-template-$template_name-$version-$release.noarch.rpm"
    local rpm_path

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

    "$repo_root/tests/template-rpm-payload-check.sh" \
        --rpm "$rpm_file" \
        --template "$template_name" \
        --source-image "$image" \
        --work-dir "$work_dir/payload-$template_name" >/dev/null

    printf 'native template RPM layout check passed: %s\n' "$rpm_file"
}

main() {
    prepare_root_image
    check_template_rpm guix
    check_template_rpm guix-minimal
}

main "$@"
