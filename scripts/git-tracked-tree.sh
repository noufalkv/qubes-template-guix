#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Helpers for snapshotting a working-tree subtree without admitting ignored or
# untracked files.  The caller must source scripts/lib.sh first for die/need.

_git_tracked_tree_safe_relative_path() {
    local component
    local remainder="$1"

    [ -n "$remainder" ] || return 1
    case "$remainder" in
        /*) return 1 ;;
    esac

    while :; do
        case "$remainder" in
            */*)
                component="${remainder%%/*}"
                remainder="${remainder#*/}"
                ;;
            *)
                component="$remainder"
                remainder=""
                ;;
        esac
        case "$component" in
            ""|.|..) return 1 ;;
        esac
        [ -n "$remainder" ] || break
    done
}

_git_tracked_tree_validate_parents() {
    local repository="$1"
    local relative_path="$2"
    local component
    local current="$repository"
    local remainder="${relative_path%/*}"

    while :; do
        case "$remainder" in
            */*)
                component="${remainder%%/*}"
                remainder="${remainder#*/}"
                ;;
            *)
                component="$remainder"
                remainder=""
                ;;
        esac
        current="$current/$component"
        [ -d "$current" ] && [ ! -L "$current" ] ||
            die "tracked path has a missing or symlinked parent: $relative_path"
        [ -n "$remainder" ] || break
    done
}

# archive_git_tracked_tree REPOSITORY SUBTREE OUTPUT
#
# Write a tar archive containing only indexed paths below SUBTREE.  File bytes
# and symlink targets come from the working tree, so intentional local tracked
# changes remain part of a build.  Leaf types and permissions come from Git's
# canonical 100644/100755/120000 modes.  Git supplies a NUL-delimited allowlist;
# tar receives that same allowlist with recursion disabled, preventing
# untracked children from entering implicitly.
archive_git_tracked_tree() (
    set -euo pipefail

    local repository="$1"
    local subtree="$2"
    local output="$3"
    local archive_tmp
    local entry
    local git_root
    local header
    local mode
    local output_dir
    local output_name
    local output_path
    local path
    local source_path
    local staged_path
    local tracked_count=0
    local snapshot_work_dir=""

    need git
    need install
    need tar

    repository="$(cd -- "$repository" && pwd -P)" ||
        die "cannot resolve repository: $repository"
    _git_tracked_tree_safe_relative_path "$subtree" ||
        die "subtree must be a confined relative path: $subtree"

    output_dir="$(dirname -- "$output")"
    output_name="$(basename -- "$output")"
    output_dir="$(cd -- "$output_dir" && pwd -P)" ||
        die "cannot resolve output directory: $output_dir"
    output_path="$output_dir/$output_name"
    [ ! -e "$output_path" ] && [ ! -L "$output_path" ] ||
        die "refusing to replace archive output: $output_path"

    # An explicit safe.directory applies only to this known checkout.  This
    # also keeps sudo/root callers independent of per-user Git configuration.
    git_root="$(
        git -c "safe.directory=$repository" -C "$repository" \
            rev-parse --show-toplevel
    )" || die "not a Git working tree: $repository"
    git_root="$(cd -- "$git_root" && pwd -P)" ||
        die "cannot resolve Git root: $git_root"
    [ "$git_root" = "$repository" ] ||
        die "repository argument is not the Git working-tree root: $repository"

    snapshot_work_dir="$(mktemp -d "$output_dir/.git-tracked-tree.XXXXXX")" ||
        die "cannot create tracked-tree work directory in: $output_dir"
    trap 'rm -rf -- "$snapshot_work_dir"' EXIT

    git -c "safe.directory=$repository" -C "$repository" \
        ls-files --cached --stage -z -- ":(literal)$subtree" \
        > "$snapshot_work_dir/index-entries" ||
        die "cannot enumerate tracked paths below: $subtree"

    while IFS= read -r -d '' entry; do
        case "$entry" in
            *$'\t'*) ;;
            *) die "Git returned a malformed index entry" ;;
        esac
        header="${entry%%$'\t'*}"
        path="${entry#*$'\t'}"
        if [[ ! "$header" =~ ^(100644|100755|120000)\ ([0-9a-f]{40}|[0-9a-f]{64})\ 0$ ]]; then
            die "unsupported or unmerged tracked entry: $path"
        fi
        mode="${BASH_REMATCH[1]}"
        _git_tracked_tree_safe_relative_path "$path" ||
            die "Git returned an unconfined tracked path: $path"
        case "$path" in
            "$subtree"/*) ;;
            *) die "Git returned a path outside $subtree: $path" ;;
        esac

        _git_tracked_tree_validate_parents "$repository" "$path"
        source_path="$repository/$path"
        staged_path="$snapshot_work_dir/tree/$path"
        mkdir -p -- "$(dirname -- "$staged_path")" ||
            die "cannot create staging directory for tracked path: $path"
        case "$mode" in
            100644)
                [ -f "$source_path" ] && [ ! -L "$source_path" ] ||
                    die "tracked regular file is missing or changed type: $path"
                install -m 0644 -- "$source_path" "$staged_path" ||
                    die "cannot stage tracked regular file: $path"
                ;;
            100755)
                [ -f "$source_path" ] && [ ! -L "$source_path" ] ||
                    die "tracked executable is missing or changed type: $path"
                install -m 0755 -- "$source_path" "$staged_path" ||
                    die "cannot stage tracked executable: $path"
                ;;
            120000)
                [ -L "$source_path" ] ||
                    die "tracked symlink is missing or changed type: $path"
                cp -P -- "$source_path" "$staged_path" ||
                    die "cannot stage tracked symlink: $path"
                ;;
        esac

        printf '%s\0' "$path" >> "$snapshot_work_dir/paths" ||
            die "cannot write the tracked path allowlist"
        tracked_count=$((tracked_count + 1))
    done < "$snapshot_work_dir/index-entries"

    [ "$tracked_count" -gt 0 ] ||
        die "no tracked paths found below: $subtree"

    archive_tmp="$snapshot_work_dir/archive.tar"
    tar --create \
        --file "$archive_tmp" \
        --directory "$snapshot_work_dir/tree" \
        --null \
        --verbatim-files-from \
        --no-recursion \
        --files-from "$snapshot_work_dir/paths" ||
        die "cannot archive tracked paths below: $subtree"

    # Publish without an overwrite window.  The temporary archive is on the
    # same filesystem as OUTPUT, so a hard link gives us atomic no-clobber
    # semantics without accepting a pre-existing symlink.
    ln -- "$archive_tmp" "$output_path" ||
        die "cannot publish tracked-tree archive: $output_path"
    rm -f -- "$archive_tmp" ||
        die "cannot remove temporary tracked-tree archive: $archive_tmp"
)
