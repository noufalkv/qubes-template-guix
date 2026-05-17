#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v guix >/dev/null 2>&1; then
    printf 'guix-system-contract-check requires guix in PATH\n' >&2
    exit 1
fi

exec guix repl -L native/modules -- tests/guix-system-contract-check.scm
