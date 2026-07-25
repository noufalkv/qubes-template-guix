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
#   build-substitute-cache.sh prepare --manifest FILE
#       --authenticated-guix-checkout DIR --guix-security-floor COMMIT
#       [--variant normal|minimal|both]
#   build-substitute-cache.sh export --manifest FILE --manifest-sha256 SHA256
#                             --output DIR --public-key FILE --private-key FILE
#                             [--compression METHOD:LEVEL]
#                             [--bake-timeout SECONDS]
#
# The historical all-in-one form remains available by omitting the mode.  New
# automation should use two steps: prepare before making the private key
# available, then export after injecting it.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"
# shellcheck source=scripts/git-tracked-tree.sh
. "$repo_root/scripts/git-tracked-tree.sh"

output=""
public_key=""
private_key=""
manifest=""
manifest_sha256=""
authenticated_guix_checkout=""
guix_security_floor=""
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
pulled_channels_json=""
guix_repository=https://codeberg.org/guix/guix.git
guix_branch=master
source_paths=(
    .guix-channel
    config/guix-channels.scm
    config/substitute-cache/signing-key.pub
    modules
    scripts/build-substitute-cache.sh
    scripts/git-tracked-tree.sh
    scripts/lib.sh
    scripts/substitute-cache-manifest.py
)
cache_marker_name=".qubes-template-guix-cache"
cache_marker_value="qubes-template-guix static cache v1"
manifest_schema="qubes-template-guix-substitute-cache-manifest-v1"
mode="all"
variant_set=0
compression_set=0
bake_timeout_set=0

usage() {
    cat <<'EOF'
Usage:
  build-substitute-cache.sh prepare --manifest FILE
      --authenticated-guix-checkout DIR --guix-security-floor COMMIT
      [--variant NAME]
  build-substitute-cache.sh export --manifest FILE --manifest-sha256 SHA256
      --output DIR --public-key FILE --private-key FILE [options]
  build-substitute-cache.sh --output DIR --public-key FILE --private-key FILE
      --authenticated-guix-checkout DIR --guix-security-floor COMMIT
      [--variant NAME] [options]

Options:
  --manifest FILE        Prepare: write the realized-path manifest. Export:
                         consume that manifest without evaluating repository
                         Scheme code or realizing additional store items.
  --manifest-sha256 HASH Export: expected SHA-256 printed by prepare. This
                         out-of-band value detects modification between steps.
  --authenticated-guix-checkout DIR
                         Prepare: checkout authenticated by the secure
                         bootstrap. Its master history is refreshed before
                         applying the Guix security floor.
  --guix-security-floor COMMIT
                         Prepare: minimum acceptable Guix commit (40 hex
                         characters). This is an ancestry floor, not a pin.
  --output DIR           Dedicated static-cache directory (required).  A
                         completed build replaces this directory atomically;
                         an existing non-cache directory is rejected.
  --public-key FILE      Export signing public key (required by export).
  --private-key FILE     Export signing private key (required by export).
  --variant NAME         Prepare normal | minimal | both. Default: both.
  --compression M:L      Export compression. Default: zstd:19.
  --bake-timeout SECONDS Maximum time to wait for each narinfo bake.
                         Default: 900 (15 minutes).
  -h, --help             Show this help.
EOF
}

case "${1:-}" in
    prepare|export)
        mode="$1"
        shift
        ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) require_arg "$1" "${2:-}"; output="$2"; shift 2 ;;
        --public-key) require_arg "$1" "${2:-}"; public_key="$2"; shift 2 ;;
        --private-key) require_arg "$1" "${2:-}"; private_key="$2"; shift 2 ;;
        --manifest) require_arg "$1" "${2:-}"; manifest="$2"; shift 2 ;;
        --manifest-sha256)
            require_arg "$1" "${2:-}"
            manifest_sha256="$2"
            shift 2
            ;;
        --authenticated-guix-checkout)
            require_arg "$1" "${2:-}"
            authenticated_guix_checkout="$2"
            shift 2
            ;;
        --guix-security-floor)
            require_arg "$1" "${2:-}"
            guix_security_floor="$2"
            shift 2
            ;;
        --variant)
            require_arg "$1" "${2:-}"
            variant="$2"
            variant_set=1
            shift 2
            ;;
        --compression)
            require_arg "$1" "${2:-}"
            compression="$2"
            compression_set=1
            shift 2
            ;;
        --bake-timeout)
            require_arg "$1" "${2:-}"
            bake_timeout="$2"
            bake_timeout_set=1
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

python_bin="${PYTHON:-python3}"

set_source_paths() {
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
        *) die "invalid --variant: $variant" ;;
    esac
}

validate_bake_timeout() {
    case "$bake_timeout" in
        ''|*[!0-9]*) die "invalid --bake-timeout: $bake_timeout" ;;
    esac
    [ "${#bake_timeout}" -le 5 ] ||
        die "invalid --bake-timeout: $bake_timeout"
    bake_timeout_number=$((10#$bake_timeout))
    [ "$bake_timeout_number" -ge 1 ] &&
            [ "$bake_timeout_number" -le 86400 ] ||
        die "invalid --bake-timeout: $bake_timeout"
    bake_timeout="$bake_timeout_number"
}

case "$mode" in
    prepare)
        [ -n "$manifest" ] || die "--manifest is required by prepare"
        [ -n "$authenticated_guix_checkout" ] ||
            die "--authenticated-guix-checkout is required by prepare"
        [ -n "$guix_security_floor" ] ||
            die "--guix-security-floor is required by prepare"
        [ -z "$output" ] || die "--output is not accepted by prepare"
        [ -z "$public_key" ] || die "--public-key is not accepted by prepare"
        [ -z "$private_key" ] || die "--private-key is not accepted by prepare"
        [ -z "$manifest_sha256" ] ||
            die "--manifest-sha256 is not accepted by prepare"
        [ "$compression_set" -eq 0 ] ||
            die "--compression is not accepted by prepare"
        [ "$bake_timeout_set" -eq 0 ] ||
            die "--bake-timeout is not accepted by prepare"
        set_source_paths
        ;;
    export)
        [ -n "$manifest" ] || die "--manifest is required by export"
        [ -n "$manifest_sha256" ] ||
            die "--manifest-sha256 is required by export"
        [ -n "$output" ] || die "--output is required by export"
        [ -n "$public_key" ] || die "--public-key is required by export"
        [ -n "$private_key" ] || die "--private-key is required by export"
        [ -z "$authenticated_guix_checkout" ] ||
            die "--authenticated-guix-checkout is not accepted by export"
        [ -z "$guix_security_floor" ] ||
            die "--guix-security-floor is not accepted by export"
        [ "$variant_set" -eq 0 ] || die "--variant is not accepted by export"
        validate_bake_timeout
        ;;
    all)
        [ -z "$manifest" ] ||
            die "--manifest requires an explicit prepare or export mode"
        [ -z "$manifest_sha256" ] ||
            die "--manifest-sha256 requires export mode"
        [ -n "$output" ] || die "--output is required"
        [ -n "$public_key" ] || die "--public-key is required"
        [ -n "$private_key" ] || die "--private-key is required"
        [ -n "$authenticated_guix_checkout" ] ||
            die "--authenticated-guix-checkout is required"
        [ -n "$guix_security_floor" ] ||
            die "--guix-security-floor is required"
        set_source_paths
        validate_bake_timeout
        ;;
esac

sha256_file() {
    "$python_bin" - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

# The completed cache atomically replaces OUTPUT.  Resolve a concrete, narrow
# target and reject paths whose replacement could affect a parent directory or
# follow a symlink unexpectedly.
normalize_output_target() {
    output_display="$output"
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
    [ "$output" != "$repo_root" ] ||
        die "--output must not be the repository root"
}

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

if [ "$mode" = export ] || [ "$mode" = all ]; then
    normalize_output_target
    validate_output_target
fi

# Keep the old command line as a compatibility adapter, but execute the two
# phases in separate processes.  In particular, the prepare child neither
# receives nor opens either signing-key path.
if [ "$mode" = all ]; then
    compatibility_work_dir="$(
        mktemp -d "${TMPDIR:-/tmp}/qubes-cache-all.XXXXXX"
    )"
    compatibility_manifest="$compatibility_work_dir/manifest.json"
    cleanup_compatibility() {
        rm -rf -- "$compatibility_work_dir"
    }
    trap cleanup_compatibility EXIT

    manifest_sha256="$(
        "$repo_root/scripts/build-substitute-cache.sh" prepare \
            --manifest "$compatibility_manifest" \
            --authenticated-guix-checkout "$authenticated_guix_checkout" \
            --guix-security-floor "$guix_security_floor" \
            --variant "$variant"
    )"
    [[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] ||
        die "prepare returned an invalid manifest SHA-256"

    "$repo_root/scripts/build-substitute-cache.sh" export \
        --manifest "$compatibility_manifest" \
        --manifest-sha256 "$manifest_sha256" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        --compression "$compression" \
        --bake-timeout "$bake_timeout"
    cleanup_compatibility
    trap - EXIT
    exit
fi

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
need "$python_bin"

if [ "$mode" = prepare ]; then
    need "$guix_bin"
    need curl
    need env
    need git

    [[ "$guix_security_floor" =~ ^[0-9a-f]{40}$ ]] ||
        die "--guix-security-floor must be a full lowercase commit ID"
    [ -d "$authenticated_guix_checkout" ] &&
            [ ! -L "$authenticated_guix_checkout" ] ||
        die "--authenticated-guix-checkout is not a directory: $authenticated_guix_checkout"
    case "$authenticated_guix_checkout" in
        *$'\n'*|*$'\r'*)
            die "--authenticated-guix-checkout must not contain newlines"
            ;;
    esac
    authenticated_guix_checkout="$(
        cd -- "$authenticated_guix_checkout" && pwd -P
    )"
    checkout_top="$(
        git -C "$authenticated_guix_checkout" rev-parse --show-toplevel
    )" || die "--authenticated-guix-checkout is not a Git checkout"
    [ "$checkout_top" = "$authenticated_guix_checkout" ] ||
        die "--authenticated-guix-checkout must name the checkout root"
    checkout_origin="$(
        git -C "$authenticated_guix_checkout" remote get-url origin
    )" || die "authenticated Guix checkout has no origin remote"
    [ "$checkout_origin" = "$guix_repository" ] ||
        die "authenticated Guix checkout origin is not $guix_repository"
    git -C "$authenticated_guix_checkout" \
        cat-file -e "$guix_security_floor^{commit}" ||
        die "authenticated Guix checkout lacks security floor $guix_security_floor"
    git -C "$authenticated_guix_checkout" \
        merge-base --is-ancestor "$guix_security_floor" HEAD ||
        die "authenticated Guix checkout HEAD predates security floor $guix_security_floor"

    manifest_parent="$(dirname -- "$manifest")"
    manifest_name="$(basename -- "$manifest")"
    case "$manifest_name" in
        ''|.|..) die "--manifest must name a file, not $manifest" ;;
    esac
    [ -d "$manifest_parent" ] && [ ! -L "$manifest_parent" ] ||
        die "--manifest parent is not a directory: $manifest_parent"
    manifest_parent="$(cd -- "$manifest_parent" && pwd -P)"
    manifest="$manifest_parent/$manifest_name"
    [ ! -e "$manifest" ] && [ ! -L "$manifest" ] ||
        die "refusing to replace manifest: $manifest"

    source_commit="$(
        clean_git_commit \
            "$repo_root" \
            "${source_paths[@]}"
    )"

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
    local profile="$work_dir/pull-profile"
    local profile_guix resolved_guix_commit

    pulled_channels_json="$work_dir/pull-profile-channels.json"

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
        --profile="$pull_profile_store" > "$pulled_channels_json" ||
        die "failed to inspect the guix pull channel manifest"
    resolved_guix_commit="$(
        "$python_bin" - \
            "$pulled_channels_json" \
            "$source_commit" \
            "$guix_repository" \
            "$guix_branch" <<'PY'
import json
import re
import sys

manifest_path, expected_qubes_commit, expected_url, expected_branch = sys.argv[1:]
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
guix_channels = [
    channel
    for channel in channels
    if isinstance(channel, dict) and channel.get("name") == "guix"
]
if len(guix_channels) != 1:
    raise SystemExit(
        "pulled channel manifest must contain exactly one Guix channel; "
        f"found {len(guix_channels)}"
    )
if len(qubes_channels) != 1:
    raise SystemExit(
        "pulled channel manifest must contain exactly one Qubes channel; "
        f"found {len(qubes_channels)}"
    )
actual_commit = qubes_channels[0].get("commit")
if actual_commit != expected_qubes_commit:
    raise SystemExit(
        "pulled Qubes channel commit does not match immutable source: "
        f"expected {expected_qubes_commit}, got {actual_commit!r}"
    )
guix_channel = guix_channels[0]
if (guix_channel.get("url") != expected_url or
        guix_channel.get("branch") != expected_branch):
    raise SystemExit(
        "pulled Guix channel is not the expected Codeberg master channel"
    )
guix_commit = guix_channel.get("commit", "")
if not re.fullmatch(r"[0-9a-f]{40}", guix_commit):
    raise SystemExit("pulled Guix channel commit is not a full lowercase object ID")
print(guix_commit)
PY
    )" || die "authenticated pull profile has invalid channel provenance"

    # The pull above authenticated RESOLVED_GUIX_COMMIT through the unpinned
    # channel introduction.  Refresh the bootstrap-authenticated checkout to
    # obtain its commit graph.  Master may advance, but the selected revision
    # must remain on it and cannot roll back behind the authenticated head.
    git -C "$authenticated_guix_checkout" fetch \
        --no-tags \
        origin \
        "+refs/heads/$guix_branch:refs/remotes/origin/$guix_branch" ||
        die "failed to refresh authenticated Guix $guix_branch"
    git -C "$authenticated_guix_checkout" \
        cat-file -e "$resolved_guix_commit^{commit}" ||
        die "authenticated Guix checkout lacks resolved commit $resolved_guix_commit"
    git -C "$authenticated_guix_checkout" merge-base --is-ancestor \
        HEAD "refs/remotes/origin/$guix_branch" ||
        die "refreshed Guix $guix_branch does not extend the authenticated checkout"
    git -C "$authenticated_guix_checkout" merge-base --is-ancestor \
        "$resolved_guix_commit" "refs/remotes/origin/$guix_branch" ||
        die "resolved Guix $resolved_guix_commit is not on refreshed $guix_branch"
    git -C "$authenticated_guix_checkout" merge-base --is-ancestor \
        HEAD "$resolved_guix_commit" ||
        die "resolved Guix $resolved_guix_commit predates the bootstrap-authenticated head"
    git -C "$authenticated_guix_checkout" merge-base --is-ancestor \
        "$guix_security_floor" "$resolved_guix_commit" ||
        die "resolved Guix $resolved_guix_commit predates security floor $guix_security_floor"

    # Everything below, including both system variants and publication, uses
    # the Guix implementation produced by this exact authenticated channel set.
    guix_bin="$profile_guix"
    printf 'using authenticated channel-composed Guix: %s\n' "$guix_bin" >&2
}

validate_concrete_store_path() {
    local path="$1"
    local description="$2"
    local store_directory store_name

    store_directory="$(dirname -- "$pull_profile_store")"
    [ "$(dirname -- "$path")" = "$store_directory" ] ||
        die "$description is outside the Guix store: $path"
    store_name="$(basename -- "$path")"
    [[ "$store_name" =~ ^[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$ ]] ||
        die "$description is not a concrete Guix store path: $path"
    [ -e "$path" ] || die "$description does not exist: $path"
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
    validate_concrete_store_path "$system" "$v system store path"
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
validate_concrete_store_path "$pull_profile_store" "guix pull profile"
[ -d "$pull_profile_store" ] ||
    die "guix pull profile is not a directory: $pull_profile_store"

systems=()
system_names=()
system_roots=()
case "$variant" in
    both)
        system_names+=(normal minimal)
        system_roots+=("$(build_system normal)")
        system_roots+=("$(build_system minimal)")
        ;;
    *)
        system_names+=("$variant")
        system_roots+=("$(build_system "$variant")")
        ;;
esac
systems+=("${system_roots[@]}")

# Also include the channel-composed Guix closure so "guix pull" downloads it.
pull_paths="$(build_pull_closure)"
[ -n "$pull_paths" ] || die "guix pull closure returned no store paths"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    validate_concrete_store_path "$path" "guix pull closure path"
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
    validate_concrete_store_path "$path" "system closure path"
    hash="$(basename -- "$path" | cut -d- -f1)"
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

systems_manifest="$work_dir/system-roots.txt"
: > "$systems_manifest"
for ((index = 0; index < ${#system_names[@]}; index++)); do
    printf '%s\t%s\n' \
        "${system_names[index]}" "${system_roots[index]}" \
        >> "$systems_manifest"
done
repository_public_key_sha256="$(
    sha256_file "$source_tree/config/substitute-cache/signing-key.pub"
)" || die "failed to hash the substitute signing public key"

# Serialize only concrete, already-realized store paths.  Publishing this file
# uses atomic no-clobber semantics and mode 0400.  Its digest is handed to the
# export step out of band (for Actions, through a step output).
"$python_bin" "$repo_root/scripts/substitute-cache-manifest.py" create \
    --channels "$pulled_channels_json" \
    --paths "$ours" \
    --systems "$systems_manifest" \
    --output "$manifest" \
    --schema "$manifest_schema" \
    --source-commit "$source_commit" \
    --variant "$variant" \
    --public-key-sha256 "$repository_public_key_sha256" \
    --pull-profile "$pull_profile_store" \
    --guix "$guix_bin" ||
    die "failed to write the substitute manifest"

manifest_digest="$(sha256_file "$manifest")" ||
    die "failed to hash the substitute manifest"
printf 'prepared %s store paths in %s\n' "$count" "$manifest" >&2
printf '%s\n' "$manifest_digest"
exit
fi

# Export validates the manifest from one immutable read, including its
# out-of-band digest, exact schema, permissions, provenance, and every path.
# It emits a private line-oriented path file for the shell; no manifest value
# is ever evaluated as shell syntax.
manifest_metadata="$work_dir/manifest-metadata"
ours="$work_dir/store-paths"
"$python_bin" "$repo_root/scripts/substitute-cache-manifest.py" validate \
    --manifest "$manifest" \
    --sha256 "$manifest_sha256" \
    --schema "$manifest_schema" \
    --paths-output "$ours" > "$manifest_metadata" ||
    die "substitute manifest validation failed"

mapfile -d '' -t manifest_fields < "$manifest_metadata"
[ "${#manifest_fields[@]}" -eq 5 ] ||
    die "substitute manifest validator returned malformed metadata"
source_commit="${manifest_fields[0]}"
variant="${manifest_fields[1]}"
repository_public_key_sha256="${manifest_fields[2]}"
guix_bin="${manifest_fields[3]}"
pull_profile_store="${manifest_fields[4]}"

# Re-bind the prepared result to the still-clean checkout and the public key
# committed there.  This reads repository bytes but never loads/evaluates its
# Scheme modules; all realization decisions came from prepare.
set_source_paths
current_source_commit="$(
    clean_git_commit "$repo_root" "${source_paths[@]}"
)"
[ "$current_source_commit" = "$source_commit" ] ||
    die "substitute manifest source commit is not the current clean commit"
current_public_key_sha256="$(
    sha256_file "$repo_root/config/substitute-cache/signing-key.pub"
)" || die "failed to hash the committed substitute signing key"
[ "$current_public_key_sha256" = "$repository_public_key_sha256" ] ||
    die "substitute manifest is not bound to the current signing key"

[ -r "$public_key" ] || die "--public-key not readable: $public_key"
provided_public_key_sha256="$(sha256_file "$public_key")" ||
    die "failed to hash --public-key"
[ "$provided_public_key_sha256" = "$repository_public_key_sha256" ] ||
    die "--public-key does not match the key bound into the clean source"
[ -r "$private_key" ] || die "--private-key not readable: $private_key"

need "$guix_bin"
need curl
need chmod
need flock
need stat

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
[ "${#publish_port}" -le 5 ] ||
    die "invalid GUIX_PUBLISH_PORT: $publish_port"
publish_port_number=$((10#$publish_port))
[ "$publish_port_number" -ge 1 ] &&
        [ "$publish_port_number" -le 65535 ] ||
    die "invalid GUIX_PUBLISH_PORT: $publish_port"
publish_port="$publish_port_number"

count="$(wc -l < "$ours" | tr -d ' ')"
[ "$count" -gt 0 ] || die "validated manifest has no store paths"
publish_cache="$work_dir/publish-cache"
staged_output="$(mktemp -d "$output_parent/.${output_name}.tmp.XXXXXX")"
staged_output_identity="$(path_identity "$staged_output")" ||
    die "failed to identify staged cache directory: $staged_output"
mkdir -p "$publish_cache" "$staged_output/nar"
printf '%s\n' "$cache_marker_value" > "$staged_output/$cache_marker_name"

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
