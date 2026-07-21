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
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

output=""
public_key=""
private_key=""
variant="both"
compression="zstd:19"
guix_bin="${GUIX:-guix}"
publish_port="${GUIX_PUBLISH_PORT:-}"
publish_pid=""
work_dir=""
staged_output=""
cache_marker_name=".qubes-template-guix-cache"
cache_marker_value="qubes-template-guix static cache v1"

usage() {
    cat <<'EOF'
Usage: build-substitute-cache.sh --output DIR --public-key FILE --private-key FILE [options]

Options:
  --output DIR           Dedicated static-cache directory (required).  A
                         completed build replaces this directory atomically;
                         an existing non-cache directory is rejected.
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
output_display="$output"
[ -r "$public_key" ] || die "--public-key not readable: $public_key"
[ -r "$private_key" ] || die "--private-key not readable: $private_key"
case "$variant" in normal|minimal|both) ;; *) die "invalid --variant: $variant" ;; esac
need "$guix_bin"
need curl
python_bin="${PYTHON:-python3}"
need "$python_bin"

# Use an ephemeral loopback port by default.  The publisher PID is also checked
# during readiness below, so a rare bind race cannot make an unrelated local
# HTTP service look like the publisher started by this invocation.
if [ -z "$publish_port" ]; then
    publish_port="$(
        "$python_bin" -c \
            'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
    )"
fi
case "$publish_port" in
    ''|*[!0-9]*) die "invalid GUIX_PUBLISH_PORT: $publish_port" ;;
esac
[ "${#publish_port}" -le 5 ] || die "invalid GUIX_PUBLISH_PORT: $publish_port"
publish_port_number=$((10#$publish_port))
[ "$publish_port_number" -ge 1 ] && [ "$publish_port_number" -le 65535 ] ||
    die "invalid GUIX_PUBLISH_PORT: $publish_port"
publish_port="$publish_port_number"

# The completed cache atomically replaces OUTPUT.  Resolve a concrete, narrow
# target and reject paths whose replacement could affect a parent directory or
# follow a symlink unexpectedly.
while [ "$output" != "/" ] && [ "$output" != "${output%/}" ]; do
    output="${output%/}"
done
output_parent="$(dirname -- "$output")"
output_name="$(basename -- "$output")"
case "$output_name" in
    ''|.|..) die "--output must name a cache directory, not $output" ;;
esac
[ "$output" != "/" ] || die "--output must not be the filesystem root"
mkdir -p "$output_parent"
output_parent="$(cd -- "$output_parent" && pwd -P)"
output="$output_parent/$output_name"
[ "$output" != "$repo_root" ] || die "--output must not be the repository root"
[ ! -L "$output" ] || die "--output must not be a symbolic link: $output"
[ ! -e "$output" ] || [ -d "$output" ] ||
    die "--output exists and is not a directory: $output"
if [ -d "$output" ] &&
        find "$output" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    marker="$output/$cache_marker_name"
    unknown_entry="$(
        find "$output" -mindepth 1 -maxdepth 1 \
            ! -name "$cache_marker_name" \
            ! -name nix-cache-info \
            ! -name nar \
            ! -name '*.narinfo' \
            -print -quit
    )"
    if [ -f "$marker" ] && [ "$(< "$marker")" = "$cache_marker_value" ]; then
        :
    elif [ -f "$output/nix-cache-info" ] && [ -d "$output/nar" ] &&
            [ -z "$unknown_entry" ]; then
        # Accept and migrate caches produced before the ownership marker was
        # introduced, but only when every top-level entry has cache shape.
        :
    else
        die "refusing to replace non-cache output directory: $output"
    fi
fi

cleanup() {
    if [ -n "$publish_pid" ]; then
        kill "$publish_pid" 2>/dev/null || true
        wait "$publish_pid" 2>/dev/null || true
        publish_pid=""
    fi
    [ -n "$staged_output" ] && [ -d "$staged_output" ] &&
        rm -rf -- "$staged_output" || true
    [ -n "$work_dir" ] && [ -d "$work_dir" ] && rm -rf "$work_dir" || true
}
trap cleanup EXIT

work_dir="$(mktemp -d)"
publish_cache="$work_dir/publish-cache"
staged_output="$(mktemp -d "$output_parent/.${output_name}.tmp.XXXXXX")"
mkdir -p "$publish_cache" "$staged_output/nar"
printf '%s\n' "$cache_marker_value" > "$staged_output/$cache_marker_name"

build_system() {
    local v="$1"
    local system

    printf 'building %s system closure...\n' "$v" >&2
    system="$(
        "$guix_bin" system build -L "$repo_root/modules" \
            "$repo_root/config/qubes-os-$v.scm" | tail -n 1
    )" || die "failed to build $v system closure"
    [ -n "$system" ] || die "$v system build returned no store path"
    [ -e "$system" ] || die "$v system store path does not exist: $system"
    printf '%s\n' "$system"
}

build_pull_closure() {
    # Build the channel-composed Guix that "guix pull" instantiates for this
    # channel set, and return its store paths.  Adding a custom channel changes
    # the Guix derivation hash, so ci.guix has no substitute for it and an
    # in-template "guix pull" would otherwise rebuild Guix from source on every
    # update.  Realize the profile AND its full build-time closure (so the
    # compiled-modules derivation guix pull needs is published too, not just the
    # runtime profile), then emit every resulting store path.
    printf 'building channel-composed guix (guix pull closure)...\n' >&2
    "$guix_bin" pull -C "$repo_root/config/guix-channels.scm" \
        -p "$work_dir/pull-profile" >&2 ||
        die "failed to build the guix pull profile"
    local prof derivers drv drv_closure closure_path
    prof="$(readlink -f -- "$work_dir/pull-profile")" ||
        die "guix pull did not create a readable profile"
    [ -n "$prof" ] || die "guix pull returned an empty profile path"
    [ -e "$prof" ] || die "guix pull profile does not exist: $prof"
    # The runtime closure of the profile, plus the build closure of its deriver
    # (which contains the guix-<commit>-modules output guix pull realizes).
    "$guix_bin" gc -R "$prof" ||
        die "failed to resolve the guix pull runtime closure"
    derivers="$("$guix_bin" gc --derivers "$prof")" ||
        die "failed to resolve the guix pull profile deriver"
    [ -n "$derivers" ] || die "guix pull profile has no deriver"
    while IFS= read -r drv; do
        [ -n "$drv" ] || continue
        [ -f "$drv" ] || die "guix pull profile deriver is missing: $drv"
        drv_closure="$("$guix_bin" gc -R "$drv")" ||
            die "failed to resolve build closure for $drv"
        while IFS= read -r closure_path; do
            [ -n "$closure_path" ] || continue
            case "$closure_path" in
                *.drv) ;;
                *) printf '%s\n' "$closure_path" ;;
            esac
        done <<< "$drv_closure"
    done <<< "$derivers"
}

systems=()
case "$variant" in
    both)
        systems+=("$(build_system normal)")
        systems+=("$(build_system minimal)")
        ;;
    *) systems+=("$(build_system "$variant")") ;;
esac

# Also include the channel-composed Guix closure so "guix pull" downloads it.
pull_paths="$(build_pull_closure)"
[ -n "$pull_paths" ] || die "guix pull closure returned no store paths"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$path" ] || die "guix pull closure path does not exist: $path"
    systems+=("$path")
done <<< "$pull_paths"

# Collect the union closure of the built systems, then keep only the store paths
# that official Guix CI does NOT already serve.  Those upstream-substitutable
# paths (gtk, ffmpeg, ...) must NOT be republished: they are large and would
# blow the static-host size budget while adding no value, since templates fetch
# them from ci.guix.gnu.org directly.
printf 'computing channel-specific store paths...\n' >&2
closure="$work_dir/closure.txt"
ours="$work_dir/ours.txt"
: > "$closure"
for system in "${systems[@]}"; do
    "$guix_bin" gc -R "$system" >> "$closure"
done
sort -u "$closure" -o "$closure"
[ -s "$closure" ] || die "built systems produced an empty store closure"

: > "$ours"
upstream="https://ci.guix.gnu.org"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    hash="$(basename "$path" | cut -d- -f1)"
    code="$(
        curl --silent --show-error --location \
            --connect-timeout 5 --max-time 15 \
            --retry 2 --retry-delay 1 \
            --output /dev/null --write-out '%{http_code}' \
            "$upstream/$hash.narinfo"
    )" || die "failed to query upstream narinfo for $path"
    case "$code" in
        200) ;;
        404) printf '%s\n' "$path" >> "$ours" ;;
        *) die "upstream narinfo query for $path returned HTTP $code" ;;
    esac
done < "$closure"

count="$(wc -l < "$ours" | tr -d ' ')"
printf 'channel-specific paths to publish: %s\n' "$count" >&2
[ "$count" -gt 0 ] || die "no channel-specific paths found; nothing to publish"

# Start a local guix publish backed by a cache directory.  Requesting each
# narinfo makes it compress ("bake") the nar into the cache; we then assemble a
# flat static tree from those baked files.
"$guix_bin" publish -p "$publish_port" -C "$compression" -c "$publish_cache" \
    --listen=127.0.0.1 \
    --public-key="$public_key" --private-key="$private_key" \
    --ttl=30d >"$work_dir/guix-publish.log" 2>&1 &
publish_pid="$!"

base="http://127.0.0.1:$publish_port"
publisher_running() {
    local state=""

    kill -0 "$publish_pid" 2>/dev/null || return 1
    if [ -r "/proc/$publish_pid/stat" ]; then
        state="$(awk '{ print $3 }' "/proc/$publish_pid/stat" 2>/dev/null)" ||
            return 1
        case "$state" in Z|X) return 1 ;; esac
    fi
    return 0
}

publisher_died() {
    local publish_status=0

    wait "$publish_pid" || publish_status="$?"
    publish_pid=""
    sed 's/^/guix publish: /' "$work_dir/guix-publish.log" >&2
    die "guix publish exited before becoming ready (status $publish_status)"
}

publisher_ready=0
attempt=1
publisher_attempts=30
while [ "$attempt" -le "$publisher_attempts" ]; do
    publisher_running || publisher_died
    if curl --fail --silent --location \
        --connect-timeout 2 --max-time 5 --output /dev/null \
        "$base/nix-cache-info"; then
        # Give a just-started process time to report a bind failure before
        # accepting a response that could have come from a colliding service.
        sleep 0.2
        publisher_running || publisher_died
        publisher_ready=1
        break
    fi
    sleep 1
    attempt=$((attempt + 1))
done
[ "$publisher_ready" -eq 1 ] || {
    sed 's/^/guix publish: /' "$work_dir/guix-publish.log" >&2
    die "guix publish did not become ready after $publisher_attempts attempts"
}

nix_cache_info="$staged_output/nix-cache-info"
curl --fail --silent --show-error --location \
    --connect-timeout 5 --max-time 10 --retry 2 --retry-delay 1 \
    --output "$nix_cache_info.part" "$base/nix-cache-info"
[ -s "$nix_cache_info.part" ] || die "downloaded nix-cache-info is empty"
mv "$nix_cache_info.part" "$nix_cache_info"

# Bake + fetch each path's narinfo and nar into the static layout clients expect:
# narinfo at the root as <hash>.narinfo, nar under the relative URL it names.
published=0
nar_urls="$work_dir/nar-urls.txt"
: > "$nar_urls"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    hash="$(basename "$path" | cut -d- -f1)"
    narinfo=""
    narinfo_download="$work_dir/$hash.narinfo"
    attempt=1
    narinfo_attempts=20
    while [ "$attempt" -le "$narinfo_attempts" ]; do
        rm -f "$narinfo_download"
        if curl --fail --silent --show-error --location \
            --connect-timeout 5 --max-time 30 \
            --output "$narinfo_download" "$base/$hash.narinfo" \
            && grep -q '^StorePath:' "$narinfo_download"; then
            narinfo="$(< "$narinfo_download")"
            break
        fi
        narinfo=""
        sleep 1
        attempt=$((attempt + 1))
    done
    [ -n "$narinfo" ] ||
        die "could not bake narinfo for $path after $narinfo_attempts attempts"

    store_path="$(printf '%s' "$narinfo" | sed -n 's/^StorePath: //p')"
    [ "$store_path" = "$path" ] ||
        die "narinfo StorePath mismatch for $path: ${store_path:-missing}"
    nar_url="$(printf '%s' "$narinfo" | sed -n 's/^URL: //p')"
    [ -n "$nar_url" ] || die "narinfo has no URL for $path"
    case "$nar_url" in
        *$'\n'*) die "narinfo has multiple URLs for $path" ;;
    esac
    case "$nar_url" in
        nar/*) ;;
        *) die "narinfo URL is not a relative nar path for $path: $nar_url" ;;
    esac
    case "/$nar_url/" in
        *'/../'*|*'/./'*|*'//'*) die "unsafe narinfo URL for $path: $nar_url" ;;
    esac
    file_size="$(printf '%s' "$narinfo" | sed -n 's/^FileSize: //p')"
    case "$file_size" in
        '') ;;
        *[!0-9]*) die "narinfo has invalid FileSize for $path: $file_size" ;;
    esac

    nar_file="$staged_output/$nar_url"
    mkdir -p "$(dirname "$nar_file")"
    curl --fail --silent --show-error --location \
        --connect-timeout 5 --max-time 120 --retry 2 --retry-delay 1 \
        --output "$nar_file.part" "$base/$nar_url"
    [ -s "$nar_file.part" ] || die "downloaded nar is empty for $path"
    actual_size="$(wc -c < "$nar_file.part" | tr -d '[:space:]')"
    if [ -n "$file_size" ] && [ "$actual_size" != "$file_size" ]; then
        die "downloaded nar size mismatch for $path: expected $file_size, got $actual_size"
    fi
    mv "$nar_file.part" "$nar_file"
    printf '%s' "$narinfo" > "$staged_output/$hash.narinfo"
    printf '%s\n' "$nar_url" >> "$nar_urls"
    published=$((published + 1))
done < "$ours"

[ "$published" -eq "$count" ] ||
    die "published path count mismatch: expected $count, got $published"
narinfo_count="$(find "$staged_output" -maxdepth 1 -type f -name '*.narinfo' | wc -l | tr -d '[:space:]')"
expected_nar_count="$(sort -u "$nar_urls" | wc -l | tr -d '[:space:]')"
nar_count="$(find "$staged_output/nar" -type f | wc -l | tr -d '[:space:]')"
[ "$narinfo_count" -eq "$count" ] ||
    die "narinfo file count mismatch: expected $count, got $narinfo_count"
[ "$nar_count" -eq "$expected_nar_count" ] ||
    die "nar file count mismatch: expected $expected_nar_count, got $nar_count"

# Do not expose a partial cache if any build, bake, or download above failed.
# STAGED_OUTPUT is a sibling of OUTPUT.  On replacement, Linux renameat2 with
# RENAME_EXCHANGE keeps one complete tree visible at OUTPUT throughout and
# leaves the old tree at STAGED_OUTPUT for cleanup.  If the process is killed
# after the exchange, the new cache remains live and only the hidden old tree
# can be stranded.
if [ -e "$output" ]; then
    "$python_bin" -c '
import ctypes
import os
import sys

at_fdcwd = -100
rename_exchange = 2
source, destination = map(os.fsencode, sys.argv[1:])
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = (
    ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
)
renameat2.restype = ctypes.c_int
if renameat2(at_fdcwd, source, at_fdcwd, destination, rename_exchange) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
' "$staged_output" "$output" ||
        die "failed to atomically exchange completed cache at $output"
    rm -rf -- "$staged_output"
else
    mv -T -- "$staged_output" "$output" ||
        die "failed to install completed cache at $output"
fi
staged_output=""

printf 'published %s store paths into %s\n' "$published" "$output_display" >&2
du -sh "$output" 2>/dev/null | sed 's/^/static cache size: /' >&2
