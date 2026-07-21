#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
content_dir="$repo_root/builder-v2-template"
work_dir="$(mktemp -d "$repo_root/work.builder-content.XXXXXX")"

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

# This is the resource-name lookup order from QubesOS/qubes-builderv2
# d0ca789, plugins/template/scripts/functions.sh:
# get_file_or_directory_for_current_flavor.  Repeated candidates are
# intentional because Guix has the same DIST_CODENAME and DIST_NAME.
# It is kept here as a small offline contract fixture so this test neither
# downloads Builder v2 nor silently substitutes this repository's local RPM
# adapter for the real content-script interface.
resolve_in_directory() {
    local directory="$1"
    local resource="$2"
    local flavor="$3"
    local extension=""
    local stem="$resource"
    local candidate
    local candidates=()

    if [ "${resource##*.}" != "$resource" ]; then
        extension=".${resource##*.}"
        stem="${resource%.*}"
    fi

    candidates=(
        "${stem}_guix_${flavor}${extension}"
        "${stem}_guix${extension}"
        "${stem}_guix_rolling_${flavor}${extension}"
        "${stem}_guix_${flavor}${extension}"
        "${stem}_guix_rolling${extension}"
        "${stem}_guix${extension}"
        "${stem}${extension}"
    )

    for candidate in "${candidates[@]}"; do
        if [ -e "$directory/$candidate" ]; then
            printf '%s\n' "$directory/$candidate"
            return 0
        fi
    done

    return 0
}

# Builder passes APPMENUS_DIR/TEMPLATE_CONTENT_DIR as a full path, which makes
# appmenu lookup search the content root.  Relative template.conf lookup uses
# the matched TEMPLATE_FLAVOR_DIR: the root for normal and minimal/ for the
# minimal flavor.
resolve_appmenus() {
    local flavor="$1"

    resolve_in_directory "$content_dir" appmenus "$flavor"
}

resolve_template_conf() {
    local flavor="$1"
    local resource_dir="$content_dir"

    if [ "$flavor" = minimal ]; then
        resource_dir="$content_dir/minimal"
    fi
    resolve_in_directory "$resource_dir" template.conf "$flavor"
}

assert_resolution() {
    local label="$1"
    local actual="$2"
    local expected="$3"

    [ "$actual" = "$expected" ] ||
        die "$label resolved to '${actual:-<fallback>}' instead of '$expected'"
}

assert_appmenu_directory() {
    local variant="$1"
    local directory="$2"
    local builder_artifact="$work_dir/builder-appmenus-$variant"
    local builder_package="$work_dir/builder-package-$variant"
    local installed="$work_dir/appmenus-$variant"
    local name
    local link_target

    [ -f "$directory/whitelisted-appmenus.list" ] ||
        die "missing canonical $variant appmenu list"
    [ ! -L "$directory/whitelisted-appmenus.list" ] ||
        die "canonical $variant appmenu list must be a regular file"

    for name in vm-whitelisted-appmenus.list netvm-whitelisted-appmenus.list; do
        [ -L "$directory/$name" ] ||
            die "$variant $name must be a relative symlink"
        link_target="$(readlink -- "$directory/$name")"
        [ "$link_target" = whitelisted-appmenus.list ] ||
            die "$variant $name has unsafe or unexpected target '$link_target'"
        [ -f "$directory/$name" ] ||
            die "$variant $name is dangling"
    done

    # qubeize-image copies the selected directory recursively.  The links must
    # remain valid after that directory is detached from the source checkout.
    cp -r "$directory" "$builder_artifact"
    mkdir -p "$builder_package"
    for name in \
        whitelisted-appmenus.list \
        vm-whitelisted-appmenus.list \
        netvm-whitelisted-appmenus.list; do
        [ -f "$builder_artifact/$name" ] ||
            die "Builder appmenu copy left a dangling $variant $name"
        cmp -s "$directory/whitelisted-appmenus.list" \
            "$builder_artifact/$name" ||
            die "Builder appmenu copy changed $variant $name"

        # Builder's template.spec copies these command-line sources into the
        # RPM payload.  GNU cp dereferences the internal aliases, so packaged
        # allowlists remain regular files and do not depend on source layout.
        cp "$builder_artifact/$name" "$builder_package/$name"
        [ ! -L "$builder_package/$name" ] ||
            die "Builder RPM copy preserved an unsafe $variant $name link"
        cmp -s "$directory/whitelisted-appmenus.list" \
            "$builder_package/$name" ||
            die "Builder RPM copy changed $variant $name"
    done

    "$repo_root/scripts/template-appmenus.sh" --install "$installed" "$variant"
    for name in \
        whitelisted-appmenus.list \
        vm-whitelisted-appmenus.list \
        netvm-whitelisted-appmenus.list; do
        [ -f "$installed/$name" ] ||
            die "native RPM appmenu install omitted $variant $name"
        [ ! -L "$installed/$name" ] ||
            die "native RPM appmenu install emitted a symlink for $variant $name"
        cmp -s "$directory/whitelisted-appmenus.list" "$installed/$name" ||
            die "native RPM appmenu install changed $variant $name"
    done
}

normal_appmenus="$content_dir/appmenus_guix"
minimal_appmenus="$content_dir/appmenus_guix_minimal"
minimal_conf="$content_dir/minimal/template.conf"

assert_resolution \
    "normal appmenus" "$(resolve_appmenus "")" "$normal_appmenus"
assert_resolution \
    "minimal appmenus" "$(resolve_appmenus minimal)" "$minimal_appmenus"
assert_resolution \
    "normal template.conf" "$(resolve_template_conf "")" \
    "$content_dir/template.conf"
assert_resolution \
    "minimal template.conf" "$(resolve_template_conf minimal)" "$minimal_conf"

assert_appmenu_directory normal "$normal_appmenus"
assert_appmenu_directory minimal "$minimal_appmenus"

[ -L "$minimal_conf" ] || die "minimal template.conf must reuse the canonical config"
[ "$(readlink -- "$minimal_conf")" = ../template.conf ] ||
    die "minimal template.conf has an unexpected symlink target"
[ "$(readlink -f -- "$minimal_conf")" = "$content_dir/template.conf" ] ||
    die "minimal template.conf resolves outside the content tree"

printf '%s\n' 'Builder v2 content contract check passed'
