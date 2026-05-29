#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# Builder v2 calls this hook unconditionally.  Guix selects package groups in
# config.scm through the chosen operating-system variant.
:
