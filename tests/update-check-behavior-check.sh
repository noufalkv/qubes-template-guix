#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/modules/qubes/files/guix-updates-installed-check"
guix_bin="${GUIX:-guix}"
work=""

if ! command -v "$guix_bin" >/dev/null 2>&1; then
    if [ "${REQUIRE_GUIX:-0}" = 1 ]; then
        printf 'error: Guix update-check behavior test requires guix\n' >&2
        exit 1
    fi
    printf 'SKIP: Guix update-check behavior test requires guix\n'
    exit 0
fi

command -v git >/dev/null 2>&1 || {
    printf 'error: Guix update-check behavior test requires git\n' >&2
    exit 1
}

[ -r "$helper" ] || {
    printf 'error: missing Guix update-check helper: %s\n' "$helper" >&2
    exit 1
}

cleanup() {
    if [ -n "$work" ] && [ -d "$work" ]; then
        rm -rf -- "$work"
    fi
}
trap cleanup EXIT

work="$(mktemp -d "${TMPDIR:-/tmp}/qubes-update-check.XXXXXX")"
channel_repo="$work/channel"
state_file="$work/applied.scm"
channels_file="$work/channels.scm"
cache_file="$work/latest.scm"
error_file="$work/check.stderr"

# Quote a shell string for use as a Scheme string literal.  The mktemp path is
# normally simple, but escaping it keeps the fixture correct for arbitrary
# TMPDIR values too.
scheme_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

channel_url="$(scheme_string "$channel_repo")"

mkdir -p "$channel_repo"
git -C "$channel_repo" init -q --initial-branch=main
git -C "$channel_repo" config user.name "Update Check Test"
git -C "$channel_repo" config user.email "update-check@example.invalid"

GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" \
    GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
    git -C "$channel_repo" commit -q --allow-empty -m initial
applied_commit="$(git -C "$channel_repo" rev-parse --verify HEAD)"

write_state() {
    local commit="$1"

    printf '((test "%s"))\n' "$commit" > "$state_file"
}

write_state "$applied_commit"

write_unpinned_channels() {
    local url="$1"

    printf '%s\n' \
        "(list (channel (name 'test) (url \"$url\") (branch \"main\")))" \
        > "$channels_file"
}

write_pinned_channels() {
    local url="$1"
    local commit="$2"

    printf '%s\n' \
        "(list (channel (name 'test) (url \"$url\") (branch \"main\") (commit \"$commit\")))" \
        > "$channels_file"
}

expect_success() {
    local label="$1"
    local expected="$2"
    shift 2
    local output
    local status

    if output=$("$guix_bin" repl -q -- "$helper" "$@" 2> "$error_file"); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ] || [ "$output" != "$expected" ]; then
        printf 'error: %s: expected %s/0, got %s/%s\n' \
            "$label" "$expected" "$output" "$status" >&2
        sed 's/^/  /' "$error_file" >&2
        exit 1
    fi
}

expect_failure() {
    local label="$1"
    shift
    local output
    local status

    set +e
    output=$("$guix_bin" repl -q -- "$helper" "$@" 2> "$error_file")
    status=$?
    set -e

    if [ "$status" -eq 0 ] || [ -n "$output" ]; then
        printf 'error: %s: expected empty output/nonzero, got %s/%s\n' \
            "$label" "$output" "$status" >&2
        sed 's/^/  /' "$error_file" >&2
        exit 1
    fi
}

write_unpinned_channels "$channel_url"
expect_success "equal revisions" true \
    "$state_file" "$channels_file" "$cache_file"
[ "$(stat -c '%a' "$cache_file")" = 600 ] || {
    printf 'error: update-check cache is not private\n' >&2
    exit 1
}
expect_success "skip refresh with matching cache" true \
    "$state_file" "$channels_file" "$cache_file" skip-refresh

GIT_AUTHOR_DATE="2000-01-02T00:00:00Z" \
    GIT_COMMITTER_DATE="2000-01-02T00:00:00Z" \
    git -C "$channel_repo" commit -q --allow-empty -m advanced
advanced_commit="$(git -C "$channel_repo" rev-parse --verify HEAD)"
expect_success "branch advance" false \
    "$state_file" "$channels_file" "$cache_file"

# A config-only reconfigure leaves the old channel revisions active.  Preserve
# dom0's pending state because inequality cannot prove which side is newer.
expect_failure "skip refresh before applying update" \
    "$state_file" "$channels_file" "$cache_file" skip-refresh

write_state "$advanced_commit"
expect_success "skip refresh after applying update" true \
    "$state_file" "$channels_file" "$cache_file" skip-refresh

write_state "$applied_commit"
write_pinned_channels "$channel_url" "$applied_commit"
expect_success "explicit pin" true \
    "$state_file" "$channels_file" "$cache_file"
expect_success "skip refresh with pinned cache" true \
    "$state_file" "$channels_file" "$cache_file" skip-refresh

missing_url="$(scheme_string "$work/missing-channel")"
write_unpinned_channels "$missing_url"
expect_failure "skip refresh after channels change" \
    "$state_file" "$channels_file" "$cache_file" skip-refresh
expect_failure "refresh failure" \
    "$state_file" "$channels_file" "$cache_file"

# A failed refresh must not replace the last successful cache.
write_pinned_channels "$channel_url" "$applied_commit"
expect_success "cache preserved after refresh failure" true \
    "$state_file" "$channels_file" "$cache_file" skip-refresh

rm -f -- "$cache_file"
expect_failure "skip refresh without cache" \
    "$state_file" "$channels_file" "$cache_file" skip-refresh

# A compiled module loaded with -L reports a relative current-filename.  Prove
# that the installed offline marker is still resolved from that load path and
# overrides a conflicting explicit/profile provenance source.
offline_tree="$work/offline-channel"
offline_probe="$work/offline-provenance.scm"
marker_commit=1111111111111111111111111111111111111111
environment_commit=2222222222222222222222222222222222222222
mkdir -p "$offline_tree/config/substitute-cache"
cp -a -- "$repo_root/modules" "$offline_tree/modules"
cp -- "$repo_root/config/substitute-cache/signing-key.pub" \
    "$offline_tree/config/substitute-cache/signing-key.pub"
printf '%s\n' "$marker_commit" \
    > "$offline_tree/modules/qubes/.qubes-channel-commit"
printf '%s\n' \
    '(use-modules (qubes system))' \
    '(write ((@@ (qubes system) source-qubes-channel-revision)))' \
    '(newline)' > "$offline_probe"
if ! offline_output="$(
    env QUBES_TEMPLATE_CHANNEL_COMMIT="$environment_commit" \
        "$guix_bin" repl -q -L "$offline_tree/modules" -- "$offline_probe" \
        2> "$error_file"
)"; then
    printf 'error: offline channel provenance probe failed\n' >&2
    sed 's/^/  /' "$error_file" >&2
    exit 1
fi
[ "$offline_output" = "(qubes \"$marker_commit\")" ] || {
    printf 'error: offline marker did not override explicit provenance: %s\n' \
        "$offline_output" >&2
    exit 1
}

printf 'Guix update-check behavior passed\n'
