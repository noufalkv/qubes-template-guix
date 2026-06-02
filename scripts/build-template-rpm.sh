#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
variant="normal"
version="4.3.0"
release="$(date -u +%Y%m%d%H%M)"
output_dir="$repo_root/dist"
image=""

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: build-template-rpm.sh [options]

Build a native Guix System root image and package it as a qvm-template RPM.
This does not require or schedule openQA.

Options:
  --variant normal|minimal  Template variant to build. Default: normal.
  --version VERSION         RPM version. Default: 4.3.0.
  --release RELEASE         RPM release. Default: current UTC YYYYMMDDHHMM.
  --output-dir DIR          Directory for the RPM. Default: ./dist.
  --image FILE              Root image path. Default is variant-specific.
  -h, --help                Show this help.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --variant)
                require_arg "$@"
                variant="$2"
                shift 2
                ;;
            --version)
                require_arg "$@"
                version="$2"
                shift 2
                ;;
            --release)
                require_arg "$@"
                release="$2"
                shift 2
                ;;
            --output-dir)
                require_arg "$@"
                output_dir="$2"
                shift 2
                ;;
            --image)
                require_arg "$@"
                image="$2"
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
}

resolve_variant() {
    variant="$("$repo_root/scripts/template-variant.sh" "$variant" variant)"
    template_name="$("$repo_root/scripts/template-variant.sh" "$variant" template-name)"
    : "${image:=$("$repo_root/scripts/template-variant.sh" "$variant" default-image "$release")}"
}

build_root_image() {
    ./scripts/build-native-rootfs.sh --variant "$variant" --output "$image"
    ./scripts/inspect-native-rootfs.sh --image "$image" --variant "$variant"
    ./scripts/test-native-rootfs-activation.sh --image "$image"
}

package_template() {
    ./scripts/package-native-template-rpm.sh \
        --root-image "$image" \
        --name "$template_name" \
        --version "$version" \
        --release "$release" \
        --output-dir "$output_dir"
}

main() {
    local rpm

    parse_args "$@"
    resolve_variant

    cd "$repo_root" || die "cannot change to repository root: $repo_root"
    mkdir -p "$output_dir"

    build_root_image
    rpm="$(package_template)"
    sha256sum "$rpm"
}

main "$@"
