#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared helpers for the template RPM test scripts.  Sourced, not executed.
# Keeps the dummy-root-image scaffolding in one place so the layout check and
# the Builder v2 adapter contract check do not duplicate it.

# Ensure the filesystem tools used by the helpers are reachable.
PATH="/usr/sbin:/sbin:$PATH"
export PATH

# tlib_make_root_image IMAGE TREE MARKER_RELPATH MARKER_TEXT
#
# Populate TREE with a single marker file, then build a 64 MiB ext4 image at
# IMAGE from that tree.  Used to stand in for a real Guix root image when
# exercising the RPM packaging path.
tlib_make_root_image() {
    local image="$1"
    local tree="$2"
    local marker_relpath="$3"
    local marker_text="$4"

    mkdir -p "$tree/$(dirname -- "$marker_relpath")"
    printf '%s\n' "$marker_text" > "$tree/$marker_relpath"
    truncate -s 64M "$image"
    mke2fs -q -t ext4 -d "$tree" "$image"
}
