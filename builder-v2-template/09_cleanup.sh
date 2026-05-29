#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# Builder v2 calls this hook unconditionally.  The Guix build path does not
# leave a mutable package-manager cache in the mounted image.
:
