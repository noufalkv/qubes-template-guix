#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

: "${INSTALL_DIR:?INSTALL_DIR must be set by Qubes Builder v2}"
: "${ARTIFACTS_DIR:?ARTIFACTS_DIR must be set by Qubes Builder v2}"
: "${CACHE_DIR:?CACHE_DIR must be set by Qubes Builder v2}"
: "${PACKAGES_DIR:?PACKAGES_DIR must be set by Qubes Builder v2}"

mkdir -p "$INSTALL_DIR" "$ARTIFACTS_DIR" "$CACHE_DIR" "$PACKAGES_DIR"
printf '%s\n' '--> Guix 00_prepare.sh'
