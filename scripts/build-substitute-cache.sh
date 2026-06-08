#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build a static Guix substitute cache for the Qubes channel and lay it out as
# plain files a static host (e.g. GitHub Pages) can serve.
#
# Why this exists: the Qubes channel has no substitute server, so a template's
# "guix pull && guix system reconfigure" rebuilds every Qubes derivation locally
# whenever the upstream Guix toolchain moves.  Guix stays UNPINNED for security;
# this cache simply offers prebuilt nars for the channel-specific store paths so
# that the in-template update DOWNLOADS them instead of rebuilding.  Trust is by
# signature, so an untrusted static host is fine.
#
# Output tree (served at the Pages site root):
#   nix-cache-info
#   <hash>.narinfo
#   nar/<compression>/<hash>-<name>
#
# Usage:
#   build-substitute-cache.sh --output DIR --public-key FILE --private-key FILE
#                             [--variant normal|minimal|both]
#                             [--compression METHOD:LEVEL]
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

output=""
public_key=""
private_key=""
variant="both"
compression="zstd:19"
guix_bin="${GUIX:-guix}"
publish_port="8181"
publish_pid=""
work_dir=""

usage() {
    cat <<'EOF'
Usage: build-substitute-cache.sh --output DIR --public-key FILE --private-key FILE [options]

Options:
  --output DIR           Directory to write the static cache into (required).
  --public-key FILE      guix publish signing public key (required).
  --private-key FILE     guix publish signing private key (required).
  --variant NAME         normal | minimal | both. Default: both.
  --compression M:L      guix publish compression. Default: zstd:19.
  -h, --help             Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) require_arg "$1" "${2:-}"; output="$2"; shift 2 ;;
        --public-key) require_arg "$1" "${2:-}"; public_key="$2"; shift 2 ;;
        --private-key) require_arg "$1" "${2:-}"; private_key="$2"; shift 2 ;;
        --variant) require_arg "$1" "${2:-}"; variant="$2"; shift 2 ;;
        --compression) require_arg "$1" "${2:-}"; compression="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$output" ] || die "--output is required"
[ -r "$public_key" ] || die "--public-key not readable: $public_key"
[ -r "$private_key" ] || die "--private-key not readable: $private_key"
case "$variant" in normal|minimal|both) ;; *) die "invalid --variant: $variant" ;; esac
need "$guix_bin"
need curl

cleanup() {
    [ -n "$publish_pid" ] && kill "$publish_pid" 2>/dev/null || true
    [ -n "$work_dir" ] && [ -d "$work_dir" ] && rm -rf "$work_dir" || true
}
trap cleanup EXIT

work_dir="$(mktemp -d)"
publish_cache="$work_dir/publish-cache"
mkdir -p "$publish_cache" "$output"

build_system() {
    local v="$1"
    printf 'building %s system closure...\n' "$v" >&2
    "$guix_bin" system build -L "$repo_root/modules" \
        "$repo_root/config/qubes-os-$v.scm" 2>/dev/null | tail -1
}

build_pull_closure() {
    # Build the channel-composed Guix that "guix pull" instantiates for this
    # channel set, and return its store path.  Adding a custom channel changes
    # the Guix derivation hash, so ci.guix has no substitute for it and an
    # in-template "guix pull" would otherwise rebuild Guix from source on every
    # update.  Publishing this closure is what makes the update download instead.
    printf 'building channel-composed guix (guix pull closure)...\n' >&2
    "$guix_bin" pull -C "$repo_root/config/guix-channels.scm" \
        -p "$work_dir/pull-profile" 2>/dev/null
    readlink -f "$work_dir/pull-profile" 2>/dev/null
}

systems=""
case "$variant" in
    both) systems="$(build_system normal) $(build_system minimal)" ;;
    *) systems="$(build_system "$variant")" ;;
esac

# Also include the channel-composed Guix closure so "guix pull" downloads it.
pull_closure="$(build_pull_closure)"
[ -n "$pull_closure" ] && systems="$systems $pull_closure"

# Collect the union closure of the built systems, then keep only the store paths
# that official Guix CI does NOT already serve.  Those upstream-substitutable
# paths (gtk, ffmpeg, ...) must NOT be republished: they are large and would
# blow the static-host size budget while adding no value, since templates fetch
# them from ci.guix.gnu.org directly.
printf 'computing channel-specific store paths...\n' >&2
closure="$work_dir/closure.txt"
ours="$work_dir/ours.txt"
: > "$closure"
for s in $systems; do
    "$guix_bin" gc -R "$s" 2>/dev/null >> "$closure"
done
sort -u "$closure" -o "$closure"

: > "$ours"
upstream="https://ci.guix.gnu.org"
while read -r path; do
    [ -n "$path" ] || continue
    hash="$(basename "$path" | cut -d- -f1)"
    code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
        "$upstream/$hash.narinfo" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] || printf '%s\n' "$path" >> "$ours"
done < "$closure"

count="$(wc -l < "$ours" | tr -d ' ')"
printf 'channel-specific paths to publish: %s\n' "$count" >&2
[ "$count" -gt 0 ] || die "no channel-specific paths found; nothing to publish"

# Start a local guix publish backed by a cache directory.  Requesting each
# narinfo makes it compress ("bake") the nar into the cache; we then assemble a
# flat static tree from those baked files.
"$guix_bin" publish -p "$publish_port" -C "$compression" -c "$publish_cache" \
    --public-key="$public_key" --private-key="$private_key" \
    --ttl=30d >/dev/null 2>&1 &
publish_pid="$!"

base="http://localhost:$publish_port"
for i in $(seq 1 30); do
    [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$base/nix-cache-info")" = "200" ] \
        && break
    sleep 1
done

mkdir -p "$output/nar"
curl -s -m 10 "$base/nix-cache-info" > "$output/nix-cache-info"

# Bake + fetch each path's narinfo and nar into the static layout clients expect:
# narinfo at the root as <hash>.narinfo, nar under the relative URL it names.
published=0
while read -r path; do
    [ -n "$path" ] || continue
    hash="$(basename "$path" | cut -d- -f1)"
    narinfo=""
    for attempt in $(seq 1 20); do
        narinfo="$(curl -s -m 30 "$base/$hash.narinfo" || true)"
        printf '%s' "$narinfo" | grep -q '^StorePath:' && break
        narinfo=""
        sleep 1
    done
    [ -n "$narinfo" ] || { printf 'warning: could not bake %s\n' "$hash" >&2; continue; }

    printf '%s' "$narinfo" > "$output/$hash.narinfo"
    nar_url="$(printf '%s' "$narinfo" | sed -n 's/^URL: //p')"
    [ -n "$nar_url" ] || { printf 'warning: no URL in narinfo for %s\n' "$hash" >&2; continue; }
    mkdir -p "$output/$(dirname "$nar_url")"
    curl -s -m 120 "$base/$nar_url" -o "$output/$nar_url"
    published=$((published + 1))
done < "$ours"

printf 'published %s store paths into %s\n' "$published" "$output" >&2
du -sh "$output" 2>/dev/null | sed 's/^/static cache size: /' >&2
