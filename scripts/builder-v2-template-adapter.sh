#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

template_name="${TEMPLATE_NAME:-guix}"
template_version="${TEMPLATE_VERSION:-4.3.0}"
template_timestamp="${TEMPLATE_TIMESTAMP:-$(date -u +%Y%m%d%H%M)}"
template_flavor="${TEMPLATE_FLAVOR:-}"
template_variant=""
artifacts_dir="${ARTIFACTS_DIR:-$repo_root/work.builder-v2}"
template_root_size="${TEMPLATE_ROOT_SIZE:-20G}"

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: builder-v2-template-adapter.sh build-rootimg|build-rpm

Adapter for Qubes Builder v2's template plugin.  The plugin calls
`make prepare build-rootimg` during prep and `make prepare build-rpm` during
build, with TEMPLATE_* and ARTIFACTS_DIR in the environment.  This script maps
those calls to the native Guix rootfs and template RPM scripts.
EOF
}

set_template_defaults() {
    template_variant="$("$repo_root/scripts/template-variant.sh" \
        "$template_name" builder-variant "$template_flavor"
    )"
    template_name="$("$repo_root/scripts/template-variant.sh" \
        "$template_variant" template-name
    )"
}

release_from_timestamp() {
    local release

    release="$(printf '%s\n' "$template_timestamp" | tr -cd '0-9')"
    [ -n "$release" ] || die "TEMPLATE_TIMESTAMP must contain digits: $template_timestamp"
    printf '%s\n' "$release"
}

build_rootimg() {
    local root_dir root_img appmenus_dir template_conf

    set_template_defaults
    root_dir="$artifacts_dir/qubeized_images/$template_name"
    root_img="$root_dir/root.img"
    appmenus_dir="$artifacts_dir/appmenus"
    template_conf="$artifacts_dir/template.conf"

    mkdir -p "$root_dir" "$(dirname -- "$template_conf")"
    "$repo_root/scripts/build-native-rootfs.sh" \
        --variant "$template_variant" \
        --output "$root_img" \
        --size "$template_root_size"

    rm -rf "$appmenus_dir"
    "$repo_root/scripts/template-appmenus.sh" --install "$appmenus_dir" "$template_variant"
    cp "$repo_root/builder-v2-template/template.conf" "$template_conf"
}

build_rpm() {
    local root_img rpm_dir release

    set_template_defaults
    root_img="$artifacts_dir/qubeized_images/$template_name/root.img"
    rpm_dir="$artifacts_dir/rpmbuild/RPMS/noarch"
    release="$(release_from_timestamp)"

    [ -r "$root_img" ] || die "missing Builder v2 root image: $root_img"
    mkdir -p "$rpm_dir"

    "$repo_root/scripts/package-native-template-rpm.sh" \
        --root-image "$root_img" \
        --name "$template_name" \
        --version "$template_version" \
        --release "$release" \
        --output-dir "$rpm_dir"
}

main() {
    [ "$#" -eq 1 ] || {
        usage >&2
        exit 1
    }

    case "${1:-}" in
        build-rootimg) build_rootimg ;;
        build-rpm) build_rpm ;;
        -h|--help) usage ;;
        *) usage >&2; exit 1 ;;
    esac
}

main "$@"
