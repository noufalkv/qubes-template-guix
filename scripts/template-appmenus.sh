#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: template-appmenus.sh [--install DIR | --check DIR] normal|minimal|TEMPLATE_NAME

Print, install, or check Qubes appmenu allowlists for a template variant.
EOF
}

appmenu_files=(
    whitelisted-appmenus.list
    vm-whitelisted-appmenus.list
    netvm-whitelisted-appmenus.list
)

mode="print"
target_dir=""
template=""
appmenus_file=""
entries=()

validate_entry() {
    local entry="$1"

    case "$entry" in
        */*|*' '*|*$'\t'*|*$'\n'*)
            die "invalid desktop-file ID in appmenu list: $entry"
            ;;
    esac
}

resolve_appmenus_file() {
    local variant

    variant="$("$repo_root/scripts/template-variant.sh" "$1" variant)"
    case "$variant" in
        normal)
            appmenus_file="$repo_root/builder-v2-template/appmenus_guix/whitelisted-appmenus.list"
            ;;
        minimal)
            appmenus_file="$repo_root/builder-v2-template/appmenus_guix_minimal/whitelisted-appmenus.list"
            ;;
    esac

    [ -r "$appmenus_file" ] || die "missing appmenu list: $appmenus_file"
}

load_entries() {
    local entry

    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in
            ""|\#*) continue ;;
        esac
        validate_entry "$entry"
        entries+=("$entry")
    done < "$appmenus_file"

    [ "${#entries[@]}" -gt 0 ] || die "empty appmenu list: $appmenus_file"
}

print_entries() {
    printf '%s\n' "${entries[@]}"
}

install_appmenus() {
    local appmenus_name

    mkdir -p "$target_dir"
    for appmenus_name in "${appmenu_files[@]}"; do
        print_entries > "$target_dir/$appmenus_name"
    done
}

check_appmenus() {
    local appmenus_name installed_file

    for appmenus_name in "${appmenu_files[@]}"; do
        installed_file="$target_dir/$appmenus_name"
        [ -f "$installed_file" ] || die "missing appmenu allowlist: $installed_file"
        cmp -s "$installed_file" <(print_entries) ||
            die "unexpected appmenu allowlist: $installed_file"
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --install)
                require_arg "$@"
                mode="install"
                target_dir="$2"
                shift 2
                ;;
            --check)
                require_arg "$@"
                mode="check"
                target_dir="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "unknown argument: $1"
                ;;
            *)
                [ -z "$template" ] || die "unexpected extra template argument: $1"
                template="$1"
                shift
                ;;
        esac
    done
}

validate_args() {
    case "$mode" in
        print) ;;
        install|check)
            [ -n "$target_dir" ] || die "missing target directory"
            ;;
        *) die "internal error: unsupported mode: $mode" ;;
    esac

    [ -n "$template" ] || die "missing template variant"
}

main() {
    parse_args "$@"
    validate_args
    resolve_appmenus_file "$template"
    load_entries

    case "$mode" in
        print) print_entries ;;
        install) install_appmenus ;;
        check) check_appmenus ;;
    esac
}

main "$@"
