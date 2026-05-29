#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Render the Qubes Guix System config template to a concrete operating-system
# file by substituting the @VARIANT@ token.  The result is what gets installed
# as /etc/config.scm and reconfigured later, so it must be self-contained and
# resolve the (qubes ...) modules through the channel load path.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/config/qubes-system.tmpl"
variant=""
output=""

usage() {
    cat <<'EOF'
Usage: render-config.sh --variant normal|minimal [--template FILE] --output FILE

Render config/qubes-system.tmpl into a concrete Guix System config by
substituting @VARIANT@.

Options:
  --variant NAME   Template variant: normal or minimal. Required.
  --template FILE  Template to render. Default: config/qubes-system.tmpl
  --output FILE    Output config file. Required.
  -h, --help       Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant) require_arg "$@"; variant="$2"; shift 2 ;;
        --template) require_arg "$@"; template="$2"; shift 2 ;;
        --output) require_arg "$@"; output="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "$variant" in
    normal|minimal) ;;
    "") die "missing --variant" ;;
    *) die "unsupported variant: $variant (expected normal or minimal)" ;;
esac
[ -n "$output" ] || die "missing --output"
[ -r "$template" ] || die "missing template: $template"

mkdir -p -- "$(dirname -- "$output")"
sed "s/@VARIANT@/$variant/g" "$template" > "$output"

# Guard against an unreplaced or mistyped token leaking into the config.
if grep -qE '@[A-Za-z_]+@' "$output"; then
    rm -f -- "$output"
    die "unsubstituted token remains in rendered config"
fi

printf 'rendered %s config: %s\n' "$variant" "$output"
