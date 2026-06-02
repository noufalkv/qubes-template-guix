#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: template-variant.sh VARIANT|TEMPLATE FIELD [ARGS...]

Fields:
  variant             Print normal or minimal.
  template-name       Print the qvm-template name.
  builder-variant     Print the Builder variant for an optional TEMPLATE_FLAVOR.
  default-image REL   Print the default root image path for release REL.
  commands            Print expected guest commands, one per line.
EOF
}

variant_for() {
    case "$1" in
        normal|guix) printf '%s\n' normal ;;
        minimal|guix-minimal) printf '%s\n' minimal ;;
        *) die "unsupported template variant: $1" ;;
    esac
}

template_name_for() {
    case "$1" in
        normal) printf '%s\n' guix ;;
        minimal) printf '%s\n' guix-minimal ;;
        *) die "unsupported template variant: $1" ;;
    esac
}

print_commands() {
    local variant="$1"

    case "$variant" in
        normal)
            printf '%s\n' \
                evince \
                mousepad \
                su \
                thunar \
                xfce4-terminal \
                xterm \
                Xorg
            ;;
        minimal)
            printf '%s\n' su xterm Xorg
            ;;
    esac
}

builder_variant_for() {
    local selector="$1"
    local flavor="${2:-}"
    local variant

    variant="$(variant_for "$selector")"
    case "$flavor" in
        "") ;;
        minimal) variant=minimal ;;
        *) die "unsupported template flavor: $flavor" ;;
    esac

    printf '%s\n' "$variant"
}

main() {
    local selector field variant

    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
    esac

    [ "$#" -ge 2 ] || {
        usage >&2
        exit 1
    }

    selector="$1"
    field="$2"
    shift 2
    variant="$(variant_for "$selector")"

    case "$field" in
        variant)
            printf '%s\n' "$variant"
            ;;
        template-name)
            template_name_for "$variant"
            ;;
        builder-variant)
            [ "$#" -le 1 ] || die "builder-variant takes at most one template flavor"
            builder_variant_for "$selector" "${1:-}"
            ;;
        default-image)
            [ "$#" -eq 1 ] || die "default-image requires a release"
            case "$variant" in
                normal) printf 'root-gui-r%s.img\n' "$1" ;;
                minimal) printf 'root-minimal-r%s.img\n' "$1" ;;
            esac
            ;;
        commands)
            print_commands "$variant"
            ;;
        *)
            die "unknown field: $field"
            ;;
    esac
}

main "$@"
