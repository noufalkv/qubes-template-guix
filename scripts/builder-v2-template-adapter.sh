#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

template_name="${TEMPLATE_NAME:-guix}"
template_version="${TEMPLATE_VERSION:-4.3.0}"
template_timestamp="${TEMPLATE_TIMESTAMP:-$(date -u +%Y%m%d%H%M)}"
template_flavor="${TEMPLATE_FLAVOR:-}"
artifacts_dir="${ARTIFACTS_DIR:-$repo_root/work.builder-v2}"
template_root_size="${TEMPLATE_ROOT_SIZE:-20G}"

usage() {
    cat <<'EOF'
Usage: builder-v2-template-adapter.sh build-rootimg|build-rpm

Adapter for Qubes Builder v2's template plugin.  The plugin calls
`make prepare build-rootimg` during prep and `make prepare build-rpm` during
build, with TEMPLATE_* and ARTIFACTS_DIR in the environment.  This script maps
those calls to the native Guix rootfs and template RPM scripts.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

validate_template_name() {
    local value="$1"

    [ -n "$value" ] || die "template name must not be empty"
    case "$value" in
        [0123456789_.-]*) die "template name cannot start with hyphen, underscore, dot or numbers" ;;
        *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-]*) die "template name contains illegal characters: $value" ;;
        Domain-0) die "template name cannot be Domain-0" ;;
        none|default) die "template name cannot be none or default" ;;
        *-dm) die "template name cannot end with -dm" ;;
    esac
}

variant_from_builder() {
    case "$template_flavor:$template_name" in
        minimal:*|*:*-minimal) printf '%s\n' minimal ;;
        *) printf '%s\n' normal ;;
    esac
}

release_from_timestamp() {
    printf '%s\n' "$template_timestamp" | tr -cd '0-9'
}

build_rootimg() {
    local variant root_dir root_img appmenus_dir template_conf

    validate_template_name "$template_name"
    variant="$(variant_from_builder)"
    root_dir="$artifacts_dir/qubeized_images/$template_name"
    root_img="$root_dir/root.img"
    appmenus_dir="$artifacts_dir/appmenus"
    template_conf="$artifacts_dir/template.conf"

    mkdir -p "$root_dir" "$appmenus_dir" "$(dirname -- "$template_conf")"
    "$repo_root/scripts/build-native-rootfs.sh" \
        --variant "$variant" \
        --output "$root_img" \
        --size "$template_root_size"

    case "$variant" in
        minimal) printf '%s\n' xterm.desktop >"$appmenus_dir/guix.desktop" ;;
        *) printf '%s\n' xfce4-terminal.desktop >"$appmenus_dir/guix.desktop" ;;
    esac

    cat >"$template_conf" <<EOF
virt-mode=pvh
qrexec=1
gui=1
EOF
}

build_rpm() {
    local root_img rpm_dir release

    validate_template_name "$template_name"
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

case "${1:-}" in
    build-rootimg) build_rootimg ;;
    build-rpm) build_rpm ;;
    -h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
