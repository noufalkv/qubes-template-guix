#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "$repo_root/work.builder-adapter.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

fixture_repo="$work_dir/repo"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/builder-v2-template"
cp "$repo_root/scripts/builder-v2-template-adapter.sh" \
    "$fixture_repo/scripts/builder-v2-template-adapter.sh"
cp -a "$repo_root/builder-v2-template/appmenus" \
    "$fixture_repo/builder-v2-template/appmenus"
cp -a "$repo_root/builder-v2-template/appmenus_guix_minimal" \
    "$fixture_repo/builder-v2-template/appmenus_guix_minimal"
cp "$repo_root/builder-v2-template/template.conf" \
    "$fixture_repo/builder-v2-template/template.conf"

cat >"$fixture_repo/scripts/build-native-rootfs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

variant=""
output=""
size=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant)
            variant="$2"
            shift 2
            ;;
        --output)
            output="$2"
            shift 2
            ;;
        --size)
            size="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[ -n "$output" ] || {
    printf 'missing --output\n' >&2
    exit 1
}

mkdir -p "$(dirname -- "$output")"
{
    printf 'variant=%s\n' "$variant"
    printf 'size=%s\n' "$size"
} >"$output"
EOF
chmod +x "$fixture_repo/scripts/build-native-rootfs.sh" \
    "$fixture_repo/scripts/builder-v2-template-adapter.sh"

check_rootimg_artifacts() {
    local template_name="$1"
    local template_flavor="$2"
    local expected_variant="$3"
    local expected_appmenus="$4"
    local artifacts="$work_dir/artifacts-$template_name"
    local root_img="$artifacts/qubeized_images/$template_name/root.img"

    env \
        ARTIFACTS_DIR="$artifacts" \
        TEMPLATE_NAME="$template_name" \
        TEMPLATE_FLAVOR="$template_flavor" \
        TEMPLATE_ROOT_SIZE=21G \
        "$fixture_repo/scripts/builder-v2-template-adapter.sh" build-rootimg

    grep -qx "variant=$expected_variant" "$root_img"
    grep -qx 'size=21G' "$root_img"
    cmp -s "$repo_root/builder-v2-template/$expected_appmenus/whitelisted-appmenus.list" \
        "$artifacts/appmenus/whitelisted-appmenus.list"
    cmp -s "$repo_root/builder-v2-template/$expected_appmenus/vm-whitelisted-appmenus.list" \
        "$artifacts/appmenus/vm-whitelisted-appmenus.list"
    cmp -s "$repo_root/builder-v2-template/$expected_appmenus/netvm-whitelisted-appmenus.list" \
        "$artifacts/appmenus/netvm-whitelisted-appmenus.list"
    cmp -s "$repo_root/builder-v2-template/template.conf" \
        "$artifacts/template.conf"

    [ ! -e "$artifacts/appmenus/guix.desktop" ] || {
        printf 'unexpected ad hoc appmenu artifact: %s\n' \
            "$artifacts/appmenus/guix.desktop" >&2
        exit 1
    }
}

check_rootimg_artifacts guix "" normal appmenus
check_rootimg_artifacts guix-minimal minimal minimal appmenus_guix_minimal

printf 'Builder adapter contract check passed\n'
