#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
packages_file="$repo_root/config.scm"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: missing required command: %s\n' "$1" >&2
        exit 1
    }
}

latest_series_tag() {
    local component="$1"
    local series="$2"
    local url="https://github.com/QubesOS/$component.git"

    git ls-remote --tags --sort=v:refname "$url" "refs/tags/${series}*" |
        awk '$2 !~ /\^\{\}$/ { sub("^refs/tags/", "", $2); print $2 }' |
        tail -n 1
}

tag_commit() {
    local component="$1"
    local tag="$2"
    local url="https://github.com/QubesOS/$component.git"
    local refs
    local peeled
    local direct

    refs="$(git ls-remote --tags "$url" "refs/tags/$tag" "refs/tags/$tag^{}")"
    peeled="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
    if [ -n "$peeled" ]; then
        printf '%s\n' "$peeled"
        return
    fi
    direct="$(printf '%s\n' "$refs" | awk '$2 !~ /\^\{\}$/ { print $1; exit }')"
    [ -n "$direct" ] || {
        printf 'error: could not resolve %s %s\n' "$component" "$tag" >&2
        exit 1
    }
    printf '%s\n' "$direct"
}

need awk
need git

failed=0
while read -r component version commit; do
    series="${version%.*}."
    latest_tag="$(latest_series_tag "$component" "$series")"
    if [ -z "$latest_tag" ]; then
        printf 'error: no upstream tags found for %s series %s\n' \
            "$component" "$series" >&2
        failed=1
        continue
    fi
    latest_commit="$(tag_commit "$component" "$latest_tag")"
    if [ "$version" != "$latest_tag" ]; then
        printf 'stale version: %s is %s, latest %s tag is %s\n' \
            "$component" "$version" "$series" "$latest_tag" >&2
        failed=1
        continue
    fi
    if [ "$commit" != "$latest_commit" ]; then
        printf 'stale commit: %s %s is %s, upstream tag points to %s\n' \
            "$component" "$version" "$commit" "$latest_commit" >&2
        failed=1
        continue
    fi
    printf 'ok: %s %s %s\n' "$component" "$version" "$commit"
done < <(
    awk '
        /"qubes-[^"]+"[[:space:]]+"v[0-9][^"]+"/ {
            match($0, /"qubes-[^"]+"[[:space:]]+"v[0-9][^"]+"/)
            fields = substr($0, RSTART, RLENGTH)
            split(fields, parts, "\"")
            component = parts[2]
            version = parts[4]
            getline
            commit = $1
            gsub(/"/, "", commit)
            print component, version, commit
        }
    ' "$packages_file"
)

if [ "$failed" -ne 0 ]; then
    exit 1
fi
