#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "$repo_root/work.channel-source-copy.XXXXXX")"
fixture="$work_dir/repository"
archive="$work_dir/channel-sources.tar"
destination="$work_dir/extracted"

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"
# shellcheck source=scripts/git-tracked-tree.sh
. "$repo_root/scripts/git-tracked-tree.sh"

cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p "$fixture/modules/qubes/files"
git init -q "$fixture"
printf '%s\n' '__pycache__/' '*.ignored' > "$fixture/.gitignore"

regular_rel='modules/qubes/regular file.scm'
executable_rel='modules/qubes/files/executable-tool'
symlink_rel='modules/qubes/files/current-config'
newline_rel=$'modules/qubes/files/name with a\nnewline.scm'

printf '%s\n' 'indexed regular bytes' > "$fixture/$regular_rel"
printf '%s\n' '#!/bin/sh' 'printf indexed' > "$fixture/$executable_rel"
chmod 0755 "$fixture/$executable_rel"
ln -s 'indexed-target' "$fixture/$symlink_rel"
printf '%s\n' 'tracked unusual filename' > "$fixture/$newline_rel"
git -c "safe.directory=$fixture" -C "$fixture" add .gitignore modules

# The snapshot must use current working-tree state rather than HEAD/index.
printf '%s\n' 'unstaged regular working-tree bytes' > "$fixture/$regular_rel"
chmod 0640 "$fixture/$regular_rel"
printf '%s\n' '#!/bin/sh' 'printf unstaged-executable' \
    > "$fixture/$executable_rel"
chmod 0751 "$fixture/$executable_rel"
ln -sfn '../regular file.scm' "$fixture/$symlink_rel"

# These paths model both the observed Python-bytecode contamination and a
# general untracked directory.  Neither a directory nor its children may be
# admitted merely because it lives below a tracked parent.
mkdir -p \
    "$fixture/modules/qubes/files/__pycache__" \
    "$fixture/modules/qubes/files/untracked-directory"
printf '%s\n' 'ignored bytecode' \
    > "$fixture/modules/qubes/files/__pycache__/module.pyc"
printf '%s\n' 'untracked nested bytes' \
    > "$fixture/modules/qubes/files/untracked-directory/payload"
printf '%s\n' 'untracked direct bytes' \
    > "$fixture/modules/qubes/untracked.scm"
printf '%s\n' 'ignored by pattern' \
    > "$fixture/modules/qubes/files/cache.ignored"

# Exercise the same ownership mismatch Git sees when a checkout owned by the
# invoking user is inspected from an as_root/sudo context.  The helper's local
# safe.directory exception must work without changing global Git config.
GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
    archive_git_tracked_tree "$fixture" modules "$archive"
mkdir -p "$destination"
tar --extract --file "$archive" --directory "$destination" --no-same-owner

for relative_path in "$regular_rel" "$executable_rel" "$newline_rel"; do
    cmp -s "$fixture/$relative_path" "$destination/$relative_path" ||
        die "copied bytes differ for tracked path: $relative_path"
done
[ "$(stat -c '%a' "$destination/$regular_rel")" = 644 ] ||
    die "tracked regular file did not receive canonical mode 0644"
[ "$(stat -c '%a' "$destination/$newline_rel")" = 644 ] ||
    die "tracked unusual filename did not receive canonical mode 0644"
[ "$(stat -c '%a' "$destination/$executable_rel")" = 755 ] ||
    die "tracked executable did not receive canonical mode 0755"
[ -L "$destination/$symlink_rel" ] ||
    die "tracked symlink was not preserved"
[ "$(readlink -- "$destination/$symlink_rel")" = \
    "$(readlink -- "$fixture/$symlink_rel")" ] ||
    die "tracked symlink target changed"

[ ! -e "$destination/modules/qubes/files/__pycache__" ] ||
    die "ignored __pycache__ entered the tracked snapshot"
[ ! -e "$destination/modules/qubes/files/untracked-directory" ] ||
    die "an untracked directory entered the tracked snapshot"
[ ! -e "$destination/modules/qubes/untracked.scm" ] ||
    die "an untracked file entered the tracked snapshot"
[ ! -e "$destination/modules/qubes/files/cache.ignored" ] ||
    die "an ignored file entered the tracked snapshot"

copied_count=0
while IFS= read -r -d '' copied_path; do
    copied_relative="${copied_path#"$destination/"}"
    if [ "$copied_relative" != "$regular_rel" ] &&
        [ "$copied_relative" != "$executable_rel" ] &&
        [ "$copied_relative" != "$symlink_rel" ] &&
        [ "$copied_relative" != "$newline_rel" ]; then
        die "unexpected path entered tracked snapshot: $copied_relative"
    fi
    copied_count=$((copied_count + 1))
done < <(find "$destination" \( -type f -o -type l \) -print0)
[ "$copied_count" -eq 4 ] ||
    die "tracked snapshot contains $copied_count paths instead of 4"

if archive_git_tracked_tree \
    "$fixture" 'modules/../modules' "$work_dir/unconfined.tar" \
    2> "$work_dir/unconfined.error"; then
    die "an unconfined subtree argument was accepted"
fi
grep -Fq 'subtree must be a confined relative path' \
    "$work_dir/unconfined.error" ||
    die "unconfined subtree rejection did not report its reason"
[ ! -e "$work_dir/unconfined.tar" ] ||
    die "failed confinement validation left an archive"

# Index modes are authoritative for leaf types.  A regular file replaced by a
# working-tree symlink must fail rather than silently changing channel shape.
mv "$fixture/$regular_rel" "$fixture/regular-file.saved"
ln -s 'files/current-config' "$fixture/$regular_rel"
if archive_git_tracked_tree \
    "$fixture" modules "$work_dir/type-mismatch.tar" \
    2> "$work_dir/type-mismatch.error"; then
    die "a tracked regular file changed to a symlink was accepted"
fi
grep -Fq 'tracked regular file is missing or changed type' \
    "$work_dir/type-mismatch.error" ||
    die "leaf-type rejection did not report its reason"
[ ! -e "$work_dir/type-mismatch.tar" ] ||
    die "failed leaf-type validation left an archive"
mv -f "$fixture/regular-file.saved" "$fixture/$regular_rel"

# A tracked filename must never be reached through a working-tree parent
# symlink: otherwise a post-checkout type change could copy outside the repo.
mv "$fixture/modules/qubes" "$fixture/qubes-tracked"
mkdir -p "$fixture/outside"
printf '%s\n' 'outside bytes' > "$fixture/outside/regular file.scm"
ln -s ../outside "$fixture/modules/qubes"
if archive_git_tracked_tree \
    "$fixture" modules "$work_dir/symlink-parent.tar" \
    2> "$work_dir/symlink-parent.error"; then
    die "a tracked path below a symlinked parent was accepted"
fi
grep -Fq 'tracked path has a missing or symlinked parent' \
    "$work_dir/symlink-parent.error" ||
    die "symlinked-parent rejection did not report its reason"
[ ! -e "$work_dir/symlink-parent.tar" ] ||
    die "failed parent validation left an archive"

printf '%s\n' 'Channel source copy check passed'
