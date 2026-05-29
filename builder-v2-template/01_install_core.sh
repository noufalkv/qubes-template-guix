#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

: "${INSTALL_DIR:?INSTALL_DIR must be set by Qubes Builder v2}"

template_name="${TEMPLATE_NAME:-guix}"
template_flavor="${TEMPLATE_FLAVOR:-}"
variant="$("$repo_root/scripts/template-variant.sh" \
    "$template_name" builder-variant "$template_flavor")"

root_device="$(findmnt -n -o SOURCE --target "$INSTALL_DIR" 2>/dev/null || true)"
if [ -n "$root_device" ] && command -v e2label >/dev/null 2>&1; then
    e2label "$root_device" guix-root
fi

printf '%s\n' "--> Guix 01_install_core.sh ($variant)"
"$repo_root/scripts/build-native-rootfs.sh" \
    --variant "$variant" \
    --install-dir "$INSTALL_DIR"
