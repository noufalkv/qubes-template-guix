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
#                             [--bake-timeout SECONDS]
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"
# shellcheck source=scripts/git-tracked-tree.sh
. "$repo_root/scripts/git-tracked-tree.sh"

output=""
public_key=""
private_key=""
variant="both"
compression="zstd:19"
bake_timeout="900"
guix_bin="${GUIX:-guix}"
publish_port="${GUIX_PUBLISH_PORT:-}"
publish_pid=""
work_dir=""
staged_output=""
staged_output_identity=""
retired_output_dir=""
pull_profile_store=""
source_archive=""
source_commit=""
source_tree=""
source_paths=(
    .guix-channel
    config/guix-channels.scm
    config/substitute-cache/signing-key.pub
    modules
)
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
  --bake-timeout SECONDS Maximum time to wait for each narinfo bake.
                         Default: 900 (15 minutes).
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
        --bake-timeout) require_arg "$1" "${2:-}"; bake_timeout="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$output" ] || die "--output is required"
output_display="$output"
[ -r "$public_key" ] || die "--public-key not readable: $public_key"
[ -r "$private_key" ] || die "--private-key not readable: $private_key"
case "$variant" in normal|minimal|both) ;; *) die "invalid --variant: $variant" ;; esac
case "$bake_timeout" in
    ''|*[!0-9]*) die "invalid --bake-timeout: $bake_timeout" ;;
esac
[ "${#bake_timeout}" -le 5 ] || die "invalid --bake-timeout: $bake_timeout"
bake_timeout_number=$((10#$bake_timeout))
[ "$bake_timeout_number" -ge 1 ] && [ "$bake_timeout_number" -le 86400 ] ||
    die "invalid --bake-timeout: $bake_timeout"
bake_timeout="$bake_timeout_number"
need "$guix_bin"
need curl
need chmod
need env
need flock
need stat
python_bin="${PYTHON:-python3}"
need "$python_bin"
case "$variant" in
    normal)
        source_paths+=(config/qubes-os-normal.scm)
        ;;
    minimal)
        source_paths+=(config/qubes-os-minimal.scm)
        ;;
    both)
        source_paths+=(
            config/qubes-os-normal.scm
            config/qubes-os-minimal.scm
        )
        ;;
esac
source_commit="$(
    clean_git_commit \
        "$repo_root" \
        "${source_paths[@]}"
)"

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

validate_output_target() {
    local marker unknown_entry

    [ ! -L "$output" ] || die "--output must not be a symbolic link: $output"
    [ ! -e "$output" ] || [ -d "$output" ] ||
        die "--output exists and is not a directory: $output"
    if [ -d "$output" ] &&
            find "$output" -mindepth 1 -maxdepth 1 -print -quit |
                grep -q .; then
        marker="$output/$cache_marker_name"
        unknown_entry="$(
            find "$output" -mindepth 1 -maxdepth 1 \
                ! -name "$cache_marker_name" \
                ! -name nix-cache-info \
                ! -name nar \
                ! -name '*.narinfo' \
                -print -quit
        )"
        if [ -f "$marker" ] && [ ! -L "$marker" ] &&
                [ "$(< "$marker")" = "$cache_marker_value" ]; then
            :
        elif [ ! -e "$marker" ] && [ ! -L "$marker" ] &&
                [ -f "$output/nix-cache-info" ] && [ -d "$output/nar" ] &&
                [ -z "$unknown_entry" ]; then
            # Accept and migrate caches produced before the ownership marker
            # was introduced, but only when every top-level entry has cache
            # shape.
            :
        else
            die "refusing to replace non-cache output directory: $output"
        fi
    fi
}

path_identity() {
    stat --format='%d:%i' -- "$1"
}

validate_output_target

cleanup() {
    local current_staged_identity=""

    if [ -n "$publish_pid" ]; then
        kill "$publish_pid" 2>/dev/null || true
        wait "$publish_pid" 2>/dev/null || true
        publish_pid=""
    fi
    # An atomic exchange changes what STAGED_OUTPUT names.  Only recursively
    # remove it while it still names the private directory created below;
    # never remove a destination that raced with publication.
    if [ -n "$staged_output" ] && [ -n "$staged_output_identity" ] &&
            [ -d "$staged_output" ]; then
        current_staged_identity="$(
            path_identity "$staged_output" 2>/dev/null || true
        )"
    fi
    if [ -n "$current_staged_identity" ] &&
            [ "$current_staged_identity" = "$staged_output_identity" ]; then
        rm -rf -- "$staged_output" || true
    fi
    # Never recurse into a retirement directory from the exit trap.  It may
    # contain data preserved after an identity mismatch; rmdir only removes it
    # when it is empty.
    [ -z "$retired_output_dir" ] ||
        rmdir -- "$retired_output_dir" 2>/dev/null || true
    [ -n "$work_dir" ] && [ -d "$work_dir" ] && rm -rf "$work_dir" || true
}
trap cleanup EXIT

work_dir="$(mktemp -d)"
publish_cache="$work_dir/publish-cache"
staged_output="$(mktemp -d "$output_parent/.${output_name}.tmp.XXXXXX")"
staged_output_identity="$(path_identity "$staged_output")" ||
    die "failed to identify staged cache directory: $staged_output"
mkdir -p "$publish_cache" "$staged_output/nar"
printf '%s\n' "$cache_marker_value" > "$staged_output/$cache_marker_name"

source_archive="$work_dir/qubes-channel-source.tar"
source_tree="$work_dir/qubes-channel-source"
# Archive every repository-owned input used below.  All later reads use this
# tree, so a checkout change during the build cannot change the cache while its
# contents retain SOURCE_COMMIT as provenance.
archive_git_commit_tree \
    "$repo_root" "$source_commit" "$source_archive" \
    "${source_paths[@]}"
mkdir "$source_tree"
tar --extract \
    --file "$source_archive" \
    --directory "$source_tree" \
    --no-same-owner \
    --same-permissions
[ -r "$source_tree/.guix-channel" ] ||
    die "immutable Qubes channel snapshot lacks .guix-channel"
[ -r "$source_tree/config/substitute-cache/signing-key.pub" ] ||
    die "immutable Qubes channel snapshot lacks substitute signing key"
[ -r "$source_tree/config/guix-channels.scm" ] ||
    die "immutable Qubes channel snapshot lacks pull channels"
[ -r "$source_tree/modules/qubes/packages.scm" ] ||
    die "immutable Qubes channel snapshot lacks package definitions"
[ ! -e "$source_tree/modules/qubes/.qubes-channel-commit" ] ||
    die "Qubes channel revision marker is reserved for installed snapshots"

resolve_authenticated_pull_profile() {
    local manifest="$work_dir/pull-profile-channels.json"
    local profile="$work_dir/pull-profile"
    local profile_guix

    printf 'building authenticated channel-composed guix profile...\n' >&2
    "$guix_bin" pull -C "$source_tree/config/guix-channels.scm" --fallback \
        -p "$profile" >&2 ||
        die "failed to build the guix pull profile"

    pull_profile_store="$(readlink -f -- "$profile")" ||
        die "guix pull did not create a readable profile"
    [ -n "$pull_profile_store" ] ||
        die "guix pull returned an empty profile path"
    [ -e "$pull_profile_store" ] ||
        die "guix pull profile does not exist: $pull_profile_store"
    profile_guix="$pull_profile_store/bin/guix"
    [ -x "$profile_guix" ] ||
        die "guix pull profile has no executable guix: $profile_guix"

    "$profile_guix" describe --format=json \
        --profile="$pull_profile_store" > "$manifest" ||
        die "failed to inspect the guix pull channel manifest"
    "$python_bin" - "$manifest" "$source_commit" <<'PY' ||
import json
import sys

manifest_path, expected_commit = sys.argv[1:]
try:
    with open(manifest_path, encoding="utf-8") as manifest_file:
        channels = json.load(manifest_file)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid pulled channel manifest: {error}")

if not isinstance(channels, list):
    raise SystemExit("invalid pulled channel manifest: expected a list")
qubes_channels = [
    channel
    for channel in channels
    if isinstance(channel, dict) and channel.get("name") == "qubes"
]
if len(qubes_channels) != 1:
    raise SystemExit(
        "pulled channel manifest must contain exactly one Qubes channel; "
        f"found {len(qubes_channels)}"
    )
actual_commit = qubes_channels[0].get("commit")
if actual_commit != expected_commit:
    raise SystemExit(
        "pulled Qubes channel commit does not match immutable source: "
        f"expected {expected_commit}, got {actual_commit!r}"
    )
PY
        die "authenticated pull profile does not match the immutable Qubes source"

    # Everything below, including both system variants and publication, uses
    # the Guix implementation produced by this exact authenticated channel set.
    guix_bin="$profile_guix"
    printf 'using authenticated channel-composed Guix: %s\n' "$guix_bin" >&2
}

build_system() {
    local v="$1"
    local system

    printf 'building %s system closure...\n' "$v" >&2
    system="$(
        env "QUBES_TEMPLATE_CHANNEL_COMMIT=$source_commit" \
            "$guix_bin" system build -L "$source_tree/modules" \
            "$source_tree/config/qubes-os-$v.scm" | tail -n 1
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
    printf 'collecting channel-composed guix pull closure...\n' >&2
    local derivers drv drv_closure closure_path
    # The runtime closure of the profile, plus the build closure of its deriver
    # (which contains the guix-<commit>-modules output guix pull realizes).
    "$guix_bin" gc -R "$pull_profile_store" ||
        die "failed to resolve the guix pull runtime closure"
    derivers="$("$guix_bin" gc --derivers "$pull_profile_store")" ||
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

resolve_authenticated_pull_profile

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
    # This read-only probe runs once per closure path.  Tolerate bounded
    # transient CI/TLS stalls, but never classify an indeterminate response as
    # a missing substitute.
    code="$(
        curl --disable --globoff --silent --show-error --location \
            --connect-timeout 10 --max-time 30 \
            --retry 5 --retry-all-errors --retry-delay 2 \
            --retry-max-time 180 \
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
    local context="$1"
    local publish_status=0

    wait "$publish_pid" || publish_status="$?"
    publish_pid=""
    sed 's/^/guix publish: /' "$work_dir/guix-publish.log" >&2
    die "guix publish exited $context (status $publish_status)"
}

publisher_ready=0
attempt=1
publisher_attempts=30
while [ "$attempt" -le "$publisher_attempts" ]; do
    publisher_running || publisher_died "before becoming ready"
    if curl --disable --globoff --fail --silent --location \
        --connect-timeout 2 --max-time 5 --output /dev/null \
        "$base/nix-cache-info"; then
        # Give a just-started process time to report a bind failure before
        # accepting a response that could have come from a colliding service.
        sleep 0.2
        publisher_running || publisher_died "before becoming ready"
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
curl --disable --globoff --fail --silent --show-error --location \
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
    narinfo_headers="$work_dir/$hash.narinfo.headers"
    attempt=1
    bake_started="$SECONDS"
    bake_deadline=$((bake_started + bake_timeout))
    last_result="not requested"
    while [ "$SECONDS" -lt "$bake_deadline" ]; do
        publisher_running ||
            publisher_died "while baking narinfo for $path"
        rm -f "$narinfo_download" "$narinfo_headers"
        remaining=$((bake_deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        request_timeout="$remaining"
        [ "$request_timeout" -le 30 ] || request_timeout=30
        curl_status=0
        if http_code="$(
            curl --disable --globoff --silent --show-error \
                --connect-timeout 2 --max-time "$request_timeout" \
                --dump-header "$narinfo_headers" \
                --output "$narinfo_download" --write-out '%{http_code}' \
                "$base/$hash.narinfo"
        )"; then
            last_result="HTTP $http_code"
            case "$http_code" in
                200)
                    grep -q '^StorePath:' "$narinfo_download" || {
                        sed 's/^/guix publish: /' \
                            "$work_dir/guix-publish.log" >&2
                        die "guix publish returned malformed narinfo for $path"
                    }
                    narinfo="$(< "$narinfo_download")"
                    break
                    ;;
                404)
                    if ! tr -d '\r' < "$narinfo_headers" |
                            grep -qi '^x-baking:[[:space:]]*1$'; then
                        sed 's/^/guix publish: /' \
                            "$work_dir/guix-publish.log" >&2
                        die "guix publish returned HTTP 404 without" \
                            "X-Baking: 1 for $path"
                    fi
                    ;;
                *)
                    sed 's/^/guix publish: /' \
                        "$work_dir/guix-publish.log" >&2
                    die "guix publish returned HTTP $http_code for $path"
                    ;;
            esac
        else
            curl_status="$?"
            last_result="curl status $curl_status"
        fi
        publisher_running ||
            publisher_died "while baking narinfo for $path"
        narinfo=""
        if [ "$attempt" -eq 1 ]; then
            printf 'waiting up to %ss for guix publish to bake %s...\n' \
                "$bake_timeout" "$path" >&2
        fi
        remaining=$((bake_deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        sleep_for="$remaining"
        [ "$sleep_for" -le 2 ] || sleep_for=2
        sleep "$sleep_for"
        attempt=$((attempt + 1))
    done
    if [ -z "$narinfo" ]; then
        publisher_running ||
            publisher_died "while baking narinfo for $path"
        bake_elapsed=$((SECONDS - bake_started))
        sed 's/^/guix publish: /' "$work_dir/guix-publish.log" >&2
        die "could not bake narinfo for $path within ${bake_elapsed}s" \
            "(timeout ${bake_timeout}s; $attempt attempts;" \
            "last result $last_result)"
    fi

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
    curl --disable --globoff --fail --silent --show-error --location \
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

atomic_rename() {
    "$python_bin" -c '
import ctypes
import os
import sys

at_fdcwd = -100
operations = {"noreplace": 1, "exchange": 2}
operation, source, destination = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = (
    ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint
)
renameat2.restype = ctypes.c_int
if renameat2(
    at_fdcwd,
    os.fsencode(source),
    at_fdcwd,
    os.fsencode(destination),
    operations[operation],
) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
' "$1" "$2" "$3"
}

# Do not expose a partial cache if any build, bake, or download above failed.
# Serialize the short publication step, then validate OUTPUT again: a cache
# build can take hours and the path approved at startup may have been replaced
# meanwhile.  The lock coordinates concurrent builders using this script; the
# identity checks also detect a non-cooperating replacement in the final gap
# between validation and rename.
exec {publish_lock_fd}<"$output_parent" ||
    die "failed to open output parent for publication locking: $output_parent"
flock --exclusive "$publish_lock_fd" ||
    die "failed to lock output parent for publication: $output_parent"
validate_output_target

if [ -e "$output" ]; then
    approved_output_identity="$(path_identity "$output")" ||
        die "failed to identify cache selected for replacement: $output"
    atomic_rename exchange "$staged_output" "$output" ||
        die "failed to atomically exchange completed cache at $output"

    installed_output_identity="$(path_identity "$output" 2>/dev/null || true)"
    displaced_output_identity="$(
        path_identity "$staged_output" 2>/dev/null || true
    )"
    if [ "$installed_output_identity" != "$staged_output_identity" ] ||
            [ "$displaced_output_identity" != "$approved_output_identity" ]; then
        # OUTPUT changed after the locked validation.  Put the displaced entry
        # back when our completed tree is still at OUTPUT.  If recovery cannot
        # be proven, leave both paths untouched for manual recovery; cleanup()
        # only removes the known staged inode.
        if [ "$installed_output_identity" = "$staged_output_identity" ] &&
                [ -n "$displaced_output_identity" ] &&
                atomic_rename exchange "$staged_output" "$output"; then
            restored_output_identity="$(
                path_identity "$output" 2>/dev/null || true
            )"
            recovered_stage_identity="$(
                path_identity "$staged_output" 2>/dev/null || true
            )"
            if [ "$restored_output_identity" = "$displaced_output_identity" ] &&
                    [ "$recovered_stage_identity" = "$staged_output_identity" ]; then
                die "output changed during publication; restored it without replacing: $output"
            fi
        fi
        die "output changed during publication; preserved paths for recovery: $output and $staged_output"
    fi

    # Move the approved displaced inode out of the shared namespace before
    # recursively deleting it.  The retirement directory is a same-filesystem
    # sibling (so the rename is atomic) and is private before anything enters
    # it.  Re-identification inside that directory closes the gap between the
    # exchange checks above and recursive cleanup.
    retired_output_dir="$(
        mktemp -d "$output_parent/.${output_name}.retired.XXXXXX"
    )" || die "failed to create private retirement directory"
    chmod 0700 "$retired_output_dir" ||
        die "failed to secure retirement directory: $retired_output_dir"
    [ "$(stat --format='%a' -- "$retired_output_dir")" = 700 ] ||
        die "retirement directory is not private: $retired_output_dir"
    retired_output="$retired_output_dir/cache"
    atomic_rename noreplace "$staged_output" "$retired_output" ||
        die "failed to retire displaced cache at $staged_output"
    retired_output_identity="$(
        path_identity "$retired_output" 2>/dev/null || true
    )"
    if [ "$retired_output_identity" != "$approved_output_identity" ]; then
        # Something replaced STAGED_OUTPUT after the exchange checks.  Restore
        # it to that path if it is still free.  Otherwise leave it protected in
        # the private directory and report both recovery locations.
        if [ -n "$retired_output_identity" ] &&
                atomic_rename noreplace "$retired_output" "$staged_output"; then
            rmdir -- "$retired_output_dir" || true
            retired_output_dir=""
            die "displaced output changed before cleanup; restored unexpected data at $staged_output"
        fi
        die "displaced output changed before cleanup; preserved recovery paths: $staged_output and $retired_output"
    fi

    staged_output=""
    staged_output_identity=""
    rm -rf -- "$retired_output"
    rmdir -- "$retired_output_dir" ||
        die "failed to remove empty retirement directory: $retired_output_dir"
    retired_output_dir=""
else
    # RENAME_NOREPLACE closes the corresponding absent-destination race; mv
    # could otherwise replace an entry created after the validation above.
    atomic_rename noreplace "$staged_output" "$output" ||
        die "failed to install completed cache at $output"
fi
staged_output=""
staged_output_identity=""
flock --unlock "$publish_lock_fd"
exec {publish_lock_fd}<&-

printf 'published %s store paths into %s\n' "$published" "$output_display" >&2
du -sh "$output" 2>/dev/null | sed 's/^/static cache size: /' >&2
