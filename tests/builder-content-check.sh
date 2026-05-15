#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmpdirs=()
cleanup() {
    if [ "${#tmpdirs[@]}" -gt 0 ]; then
        rm -rf "${tmpdirs[@]}"
    fi
}
trap cleanup EXIT

make_tmpdir() {
    mktemp -d "$repo_root/builder-content-check.XXXXXX"
}

work="$(make_tmpdir)"
tmpdirs+=("$work")
install_dir="$work/install"
mkdir -p "$install_dir/usr"

env \
    INSTALL_DIR="$install_dir" \
    ARTIFACTS_DIR="$work/artifacts" \
    CACHE_DIR="$work/cache" \
    PACKAGES_DIR="$work/packages" \
    TEMPLATE_NAME=guix-minimal \
    TEMPLATE_FLAVOR=minimal \
    builder-v2-template/00_prepare.sh

env \
    INSTALL_DIR="$install_dir" \
    ARTIFACTS_DIR="$work/artifacts" \
    CACHE_DIR="$work/cache" \
    PACKAGES_DIR="$work/packages" \
    TEMPLATE_NAME=guix-minimal \
    TEMPLATE_FLAVOR=minimal \
    builder-v2-template/02_install_groups.sh

env \
    INSTALL_DIR="$install_dir" \
    ARTIFACTS_DIR="$work/artifacts" \
    CACHE_DIR="$work/cache" \
    PACKAGES_DIR="$work/packages" \
    TEMPLATE_NAME=guix-minimal \
    TEMPLATE_FLAVOR=minimal \
    builder-v2-template/04_install_qubes.sh

test -d "$install_dir/home"
test -d "$install_dir/usr/local"

env \
    INSTALL_DIR="$install_dir" \
    ARTIFACTS_DIR="$work/artifacts" \
    CACHE_DIR="$work/cache" \
    PACKAGES_DIR="$work/packages" \
    TEMPLATE_NAME=guix-minimal \
    TEMPLATE_FLAVOR=minimal \
    builder-v2-template/09_cleanup.sh

printf 'builder content hook check passed\n'
