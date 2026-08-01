#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    printf '%s\n' \
        "Usage: $0 --guix GUIX --index DIR --repository OWNER/REPO --work-dir DIR" \
        >&2
    exit 2
}

guix=""
index=""
repository=""
work_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --guix) guix="${2:-}"; shift 2 ;;
        --index) index="${2:-}"; shift 2 ;;
        --repository) repository="${2:-}"; shift 2 ;;
        --work-dir) work_dir="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done

[ -x "$guix" ] || usage
[ -d "$index" ] || usage
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ -n "$work_dir" ] || usage
[ -n "${GUIX_CONFIGURATION_DIRECTORY:-}" ]
[ -r "$GUIX_CONFIGURATION_DIRECTORY/acl" ]
[ -n "${XDG_CACHE_HOME:-}" ]

index="$(realpath -e -- "$index")"
mkdir -m 700 -- "$work_dir"
test -s "$index/nix-cache-info"

narinfo_list="$work_dir/narinfos"
find "$index" -maxdepth 1 -type f -name '*.narinfo' -print0 |
    LC_ALL=C sort -z > "$narinfo_list"
mapfile -d '' -t narinfos < "$narinfo_list"
test "${#narinfos[@]}" -gt 0

expected="$work_dir/expected-paths"
: > "$expected"
url_prefix="https://github.com/$repository/releases/download/"
for narinfo in "${narinfos[@]}"; do
    mapfile -t store_paths < <(sed -n 's/^StorePath: //p' "$narinfo")
    mapfile -t nar_urls < <(sed -n 's/^URL: //p' "$narinfo")
    test "${#store_paths[@]}" -eq 1
    test "${#nar_urls[@]}" -eq 1

    store_hash="$(basename -- "$narinfo" .narinfo)"
    store_path="${store_paths[0]}"
    nar_url="${nar_urls[0]}"
    [[ "$store_hash" =~ ^[0-9abcdfghijklmnpqrsvwxyz]{32}$ ]]
    [[ "$store_path" == "/gnu/store/$store_hash-"* ]]
    [[ "$store_path" =~ ^/gnu/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-.+$ ]]
    [[ "$nar_url" == "$url_prefix"* ]]
    nar_location="${nar_url#"$url_prefix"}"
    [[ "$nar_location" =~ ^substitute-cache-nars-v2-[0-9a-f]{40}-[0-9a-f]{40}-[0-9]{4}-[0-9a-f]{64}/nar-v2-sha256-[0-9a-f]{64}$ ]]
    printf '%s\n' "$store_path" >> "$expected"
done
LC_ALL=C sort -u -o "$expected" "$expected"
test "$(wc -l < "$expected")" -eq "${#narinfos[@]}"

query="$work_dir/query"
{
    printf 'have'
    while IFS= read -r store_path; do
        printf ' %s' "$store_path"
    done < "$expected"
    printf '\n'
} > "$query"

cache_url="$(python3 - "$index" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).as_uri())
PY
)"
actual="$work_dir/actual-paths"
# _NIX_OPTIONS selects daemon mode; protocol replies use file descriptor 4.
_NIX_OPTIONS="substitute-urls=$cache_url" \
    "$guix" substitute --query 4>&1 \
    < "$query" | sed '/^$/d' | LC_ALL=C sort -u > "$actual"
cmp -- "$expected" "$actual"
printf 'Validated %s signed narinfos.\n' "${#narinfos[@]}"
