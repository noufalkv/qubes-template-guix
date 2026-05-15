#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

: "${INSTALL_DIR:?INSTALL_DIR must be set by Qubes Builder v2}"

printf '%s\n' '--> Guix 04_install_qubes.sh'

# qubeize-image links these paths to the private volume after this hook.
# Guix activation also manages them, but the directories must exist in the
# mounted image before Builder v2 performs the generic Qubes layout step.
mkdir -p "$INSTALL_DIR/home" "$INSTALL_DIR/usr/local"
