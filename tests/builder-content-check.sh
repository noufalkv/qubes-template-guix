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

expect_missing_builder_env_fails() {
    local hook="$1"

    if env -u INSTALL_DIR -u ARTIFACTS_DIR -u CACHE_DIR -u PACKAGES_DIR \
        "$hook" >/dev/null 2>&1; then
        printf 'expected missing Builder environment to fail: %s\n' "$hook" >&2
        exit 1
    fi
}

run_builder_hook() {
    local hook="$1"

    env \
        INSTALL_DIR="$install_dir" \
        ARTIFACTS_DIR="$artifacts_dir" \
        CACHE_DIR="$cache_dir" \
        PACKAGES_DIR="$packages_dir" \
        TEMPLATE_NAME=guix-minimal \
        TEMPLATE_FLAVOR=minimal \
        "$hook"
}

expect_directory() {
    local path="$1"

    [ -d "$path" ] || {
        printf 'expected directory: %s\n' "$path" >&2
        exit 1
    }
}

work="$(make_tmpdir)"
tmpdirs+=("$work")
install_dir="$work/install"
artifacts_dir="$work/artifacts"
cache_dir="$work/cache"
packages_dir="$work/packages"
mkdir -p "$install_dir/usr"

expect_missing_builder_env_fails builder-v2-template/00_prepare.sh
expect_missing_builder_env_fails builder-v2-template/04_install_qubes.sh

run_builder_hook builder-v2-template/00_prepare.sh
expect_directory "$install_dir"
expect_directory "$artifacts_dir"
expect_directory "$cache_dir"
expect_directory "$packages_dir"

run_builder_hook builder-v2-template/02_install_groups.sh
run_builder_hook builder-v2-template/04_install_qubes.sh
run_builder_hook builder-v2-template/04_install_qubes.sh

expect_directory "$install_dir/home"
expect_directory "$install_dir/usr/local"
[ "$(stat -c '%a' "$install_dir/home")" = 755 ]
[ "$(stat -c '%a' "$install_dir/usr/local")" = 755 ]

run_builder_hook builder-v2-template/09_cleanup.sh

printf 'builder hook contract check passed\n'
