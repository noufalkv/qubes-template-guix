#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
real_git="$(command -v git)"
real_chmod="$(command -v chmod)"
real_mv="$(command -v mv)"
base_path="$PATH"
work_dir="$(mktemp -d "$repo_root/work.pin-writer.XXXXXX")"
stub_bin="$work_dir/bin"
tmp_dir="$work_dir/tmp"
git_log="$work_dir/git.log"
guix_log="$work_dir/guix.log"
mv_log="$work_dir/mv.log"
writer_pid=""
barrier_release=""

cleanup() {
    if [ -n "$barrier_release" ]; then
        : > "$barrier_release"
    fi
    if [ -n "$writer_pid" ]; then
        kill "$writer_pid" 2>/dev/null || true
        wait "$writer_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

fail() {
    printf 'pin writer regression check failed: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local text="$2"

    grep -Fq -- "$text" "$file" || {
        printf 'expected output containing: %s\n' "$text" >&2
        sed -n '1,160p' "$file" >&2
        fail "unexpected command output"
    }
}

assert_no_staging_files() {
    local fake_repo="$1"

    if find "$fake_repo/modules/qubes" -maxdepth 1 \
            -name 'packages.scm.tmp.*' -print -quit | grep -q .; then
        fail "pin writer left a destination-side staging file"
    fi
    if find "$tmp_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        find "$tmp_dir" -mindepth 1 -maxdepth 1 -print >&2
        fail "pin writer left a temporary file or directory"
    fi
}

wait_for_barrier() {
    local marker="$1"
    local pid="$2"
    local output="$3"
    local attempt

    for ((attempt = 0; attempt < 1000; attempt++)); do
        [ -e "$marker" ] && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            writer_pid=""
            sed -n '1,160p' "$output" >&2
            fail "pin writer exited before reaching the race barrier"
        fi
        sleep 0.01
    done
    fail "timed out waiting for the pin writer race barrier"
}

old_commit='1111111111111111111111111111111111111111'
new_commit='2222222222222222222222222222222222222222'
tag_object='3333333333333333333333333333333333333333'
old_sha='0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
new_sha='1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
latest_tag='4.2.1'

write_fixture() {
    local file="$1"
    local version="$2"
    local commit="$3"
    local sha256="$4"

    cat > "$file" <<EOF
;;; Content outside the table must remain byte-for-byte identical.
(define before-pins '(keep this))

(define %qubes-source-components
  '(("qubes-test-component" "$version"
     "$commit"
     "$sha256")))

(define after-pins '(keep this too))
EOF
}

make_fake_repo() {
    local name="$1"
    local version="$2"
    local commit="$3"
    local sha256="$4"
    local fake_repo="$work_dir/$name"

    mkdir -p "$fake_repo/scripts" "$fake_repo/modules/qubes"
    cp -- "$repo_root/scripts/check-qubes-pins.sh" "$fake_repo/scripts/"
    cp -- "$repo_root/scripts/lib.sh" "$fake_repo/scripts/"
    write_fixture "$fake_repo/modules/qubes/packages.scm" \
        "$version" "$commit" "$sha256"
    chmod 0640 "$fake_repo/modules/qubes/packages.scm"
    printf '%s\n' "$fake_repo"
}

mkdir -p "$stub_bin" "$tmp_dir"
: > "$git_log"
: > "$guix_log"
: > "$mv_log"

cat > "$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${FAKE_GIT_LOG:?}"
printf '\n' >> "${FAKE_GIT_LOG:?}"

barrier() {
    local attempt

    : > "${FAKE_BARRIER_REACHED:?}"
    for ((attempt = 0; attempt < 1000; attempt++)); do
        [ -e "${FAKE_BARRIER_RELEASE:?}" ] && return 0
        sleep 0.01
    done
    printf 'fake git timed out at the test barrier\n' >&2
    exit 90
}

case "${1:-}" in
    --no-pager)
        zero_context=0
        for argument in "$@"; do
            [ "$argument" = -U0 ] && zero_context=1
        done
        case "${FAKE_GIT_DIFF_FAILURE:-}" in
            verify)
                if [ "$zero_context" -eq 1 ]; then
                    printf 'fatal fake git diff failure\n' >&2
                    exit 74
                fi
                ;;
            display)
                if [ "$zero_context" -eq 0 ]; then
                    printf 'fatal fake git diff failure\n' >&2
                    exit 74
                fi
                ;;
        esac
        exec "${REAL_GIT:?}" "$@"
        ;;
    ls-remote)
        sorted=0
        tag_lookup=0
        for argument in "$@"; do
            case "$argument" in
                --sort=v:refname) sorted=1 ;;
                refs/tags/*'^{}') tag_lookup=1 ;;
            esac
        done
        if [ "$sorted" -eq 1 ]; then
            printf '%s\trefs/tags/%s\n' \
                "${FAKE_LATEST_COMMIT:?}" "${FAKE_LATEST_TAG:?}"
        elif [ "$tag_lookup" -eq 1 ]; then
            if [ "${FAKE_GIT_BLOCK:-}" = tag-lookup ]; then
                barrier
            fi
            printf '%s\trefs/tags/%s\n' \
                "${FAKE_TAG_OBJECT:?}" "${FAKE_LATEST_TAG:?}"
            printf '%s\trefs/tags/%s^{}\n' \
                "${FAKE_LATEST_COMMIT:?}" "${FAKE_LATEST_TAG:?}"
        else
            printf 'unexpected fake git ls-remote invocation\n' >&2
            exit 91
        fi
        ;;
    clone)
        destination="${*: -1}"
        mkdir -p "$destination/.git"
        ;;
    -C)
        case "${3:-}" in
            fetch|checkout) ;;
            rev-parse) printf '%s\n' "${FAKE_LATEST_COMMIT:?}" ;;
            *)
                printf 'unexpected fake git -C operation: %s\n' \
                    "${3:-<missing>}" >&2
                exit 92
                ;;
        esac
        ;;
    *)
        printf 'unexpected fake git invocation: %s\n' "${1:-<missing>}" >&2
        exit 93
        ;;
esac
EOF

cat > "$stub_bin/guix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${FAKE_GUIX_LOG:?}"
printf '\n' >> "${FAKE_GUIX_LOG:?}"

if [ "${1:-}" != hash ] || [ "${2:-}" != -rx ] || [ "$#" -ne 3 ]; then
    printf 'unexpected fake guix invocation\n' >&2
    exit 94
fi

if [ "${FAKE_GUIX_BLOCK:-}" = hash ]; then
    : > "${FAKE_BARRIER_REACHED:?}"
    for ((attempt = 0; attempt < 1000; attempt++)); do
        [ -e "${FAKE_BARRIER_RELEASE:?}" ] && break
        sleep 0.01
    done
    [ -e "${FAKE_BARRIER_RELEASE:?}" ] || {
        printf 'fake guix timed out at the test barrier\n' >&2
        exit 95
    }
fi

printf '%s\n' "${FAKE_NEW_SHA:?}"
if [ -n "${FAKE_GUIX_EXIT:-}" ]; then
    exit "$FAKE_GUIX_EXIT"
fi
EOF

cat > "$stub_bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

"${REAL_CHMOD:?}" "$@"
if [ "${FAKE_CHMOD_BLOCK:-}" = destination-stage ]; then
    if [ "$#" -ne 2 ]; then
        printf 'unexpected destination-staging chmod arguments\n' >&2
        exit 96
    fi
    case "$1" in
        --reference=*) ;;
        *)
            printf 'destination staging did not preserve the snapshot mode\n' >&2
            exit 96
            ;;
    esac
    case "$2" in
        "${FAKE_PACKAGES_FILE:?}".tmp.*) ;;
        *)
            printf 'destination staging chmod targeted the wrong file\n' >&2
            exit 96
            ;;
    esac
    : > "${FAKE_BARRIER_REACHED:?}"
    for ((attempt = 0; attempt < 1000; attempt++)); do
        [ -e "${FAKE_BARRIER_RELEASE:?}" ] && exit 0
        sleep 0.01
    done
    printf 'fake chmod timed out at the test barrier\n' >&2
    exit 99
fi
EOF

cat > "$stub_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ] || [ "$1" != -T ] || [ "$2" != -- ]; then
    printf 'pin writer did not use an atomic mv -T publish\n' >&2
    exit 97
fi

source_file="$3"
destination="$4"
case "$source_file" in
    "$destination".tmp.*) ;;
    *)
        printf 'pin writer staged outside the destination directory\n' >&2
        exit 98
        ;;
esac
printf '%s\n' "$destination" >> "${FAKE_MV_LOG:?}"
exec "${REAL_MV:?}" "$@"
EOF
chmod +x "$stub_bin/git" "$stub_bin/guix" "$stub_bin/chmod" "$stub_bin/mv"

git_block=""
git_diff_failure=""
guix_block=""
guix_exit=""
chmod_block=""
barrier_reached=""

run_writer() {
    local fake_repo="$1"

    env \
        FAKE_BARRIER_REACHED="$barrier_reached" \
        FAKE_BARRIER_RELEASE="$barrier_release" \
        FAKE_GIT_BLOCK="$git_block" \
        FAKE_GIT_DIFF_FAILURE="$git_diff_failure" \
        FAKE_GIT_LOG="$git_log" \
        FAKE_GUIX_BLOCK="$guix_block" \
        FAKE_GUIX_EXIT="$guix_exit" \
        FAKE_GUIX_LOG="$guix_log" \
        FAKE_CHMOD_BLOCK="$chmod_block" \
        FAKE_LATEST_COMMIT="$new_commit" \
        FAKE_LATEST_TAG="$latest_tag" \
        FAKE_MV_LOG="$mv_log" \
        FAKE_NEW_SHA="$new_sha" \
        FAKE_PACKAGES_FILE="$fake_repo/modules/qubes/packages.scm" \
        FAKE_TAG_OBJECT="$tag_object" \
        PATH="$stub_bin:$base_path" \
        REAL_CHMOD="$real_chmod" \
        REAL_GIT="$real_git" \
        REAL_MV="$real_mv" \
        TMPDIR="$tmp_dir" \
        "$fake_repo/scripts/check-qubes-pins.sh" --write --yes
}

# A stale pin is updated as one complete replacement, preserving its mode.
success_repo="$(make_fake_repo success 4.2.0 "$old_commit" "$old_sha")"
success_file="$success_repo/modules/qubes/packages.scm"
success_output="$work_dir/success.out"
expected_current="$work_dir/expected-current.scm"
write_fixture "$expected_current" "$latest_tag" "$new_commit" "$new_sha"
inode_before="$(stat -c '%d:%i' "$success_file")"
mode_before="$(stat -c '%a' "$success_file")"
if ! run_writer "$success_repo" > "$success_output" 2>&1; then
    sed -n '1,160p' "$success_output" >&2
    fail "ordinary stale-pin refresh failed"
fi
cmp -s -- "$expected_current" "$success_file" ||
    fail "successful refresh did not produce the exact expected file"
[ "$(stat -c '%a' "$success_file")" = "$mode_before" ] ||
    fail "successful refresh changed the packages file mode"
[ "$(stat -c '%d:%i' "$success_file")" != "$inode_before" ] ||
    fail "successful refresh did not replace the packages file atomically"
assert_contains "$success_output" 'updated modules/qubes/packages.scm'
[ "$(wc -l < "$guix_log")" -eq 1 ] ||
    fail "successful refresh did not hash exactly one stale component"
[ "$(wc -l < "$mv_log")" -eq 1 ] ||
    fail "successful refresh published more than once"
grep -Fxq -- "$success_file" "$mv_log" ||
    fail "successful refresh did not atomically publish beside its destination"
assert_no_staging_files "$success_repo"

# Re-running with current pins is a true no-op: no hash and no destination
# replacement.
: > "$guix_log"
: > "$mv_log"
noop_output="$work_dir/noop.out"
inode_before="$(stat -c '%d:%i' "$success_file")"
if ! run_writer "$success_repo" > "$noop_output" 2>&1; then
    sed -n '1,160p' "$noop_output" >&2
    fail "all-current no-op refresh failed"
fi
cmp -s -- "$expected_current" "$success_file" ||
    fail "all-current refresh changed file contents"
[ "$(stat -c '%d:%i' "$success_file")" = "$inode_before" ] ||
    fail "all-current refresh replaced the packages file"
[ ! -s "$guix_log" ] || fail "all-current refresh invoked guix"
[ ! -s "$mv_log" ] || fail "all-current refresh published a replacement"
assert_contains "$noop_output" 'all pins current; no changes.'
assert_no_staging_files "$success_repo"

# The hash helper must relay a guix failure status and clean both its clone and
# the outer snapshot rather than emitting a candidate hash.
hash_failure_repo="$(make_fake_repo hash-failure 4.2.0 "$old_commit" "$old_sha")"
hash_failure_file="$hash_failure_repo/modules/qubes/packages.scm"
hash_failure_output="$work_dir/hash-failure.out"
hash_failure_expected="$work_dir/hash-failure-expected.scm"
cp -- "$hash_failure_file" "$hash_failure_expected"
inode_before="$(stat -c '%d:%i' "$hash_failure_file")"
guix_exit=73
: > "$guix_log"
: > "$mv_log"
if run_writer "$hash_failure_repo" > "$hash_failure_output" 2>&1; then
    fail "writer accepted a failed component hash"
else
    hash_failure_status=$?
fi
guix_exit=""
[ "$hash_failure_status" -eq 73 ] ||
    fail "hash failure status changed from 73 to $hash_failure_status"
cmp -s -- "$hash_failure_expected" "$hash_failure_file" ||
    fail "hash failure changed the packages file"
[ "$(stat -c '%d:%i' "$hash_failure_file")" = "$inode_before" ] ||
    fail "hash failure replaced the packages file"
[ ! -s "$mv_log" ] || fail "hash failure published a replacement"
assert_no_staging_files "$hash_failure_repo"

assert_fatal_diff_refused() {
    local mode="$1"
    local expected_hashes="$2"
    local fake_repo packages output expected inode status

    fake_repo="$(make_fake_repo "diff-$mode" 4.2.0 "$old_commit" "$old_sha")"
    packages="$fake_repo/modules/qubes/packages.scm"
    output="$work_dir/diff-$mode.out"
    expected="$work_dir/diff-$mode-expected.scm"
    cp -- "$packages" "$expected"
    inode="$(stat -c '%d:%i' "$packages")"
    git_diff_failure="$mode"
    : > "$guix_log"
    : > "$mv_log"
    if run_writer "$fake_repo" > "$output" 2>&1; then
        fail "writer ignored a fatal $mode git diff failure"
    else
        status=$?
    fi
    git_diff_failure=""

    [ "$status" -ne 0 ] || fail "fatal $mode git diff returned success"
    cmp -s -- "$expected" "$packages" ||
        fail "fatal $mode git diff changed the packages file"
    [ "$(stat -c '%d:%i' "$packages")" = "$inode" ] ||
        fail "fatal $mode git diff replaced the packages file"
    [ "$(wc -l < "$guix_log")" -eq "$expected_hashes" ] ||
        fail "fatal $mode git diff hashed an unexpected number of components"
    [ ! -s "$mv_log" ] || fail "fatal $mode git diff published a replacement"
    assert_contains "$output" 'fatal fake git diff failure'
    assert_no_staging_files "$fake_repo"
}

# Exit 1 from git diff means "files differ"; every other nonzero status is a
# fatal verifier/display error and must fail closed without publishing.
assert_fatal_diff_refused verify 0
assert_fatal_diff_refused display 1

# Force an edit while the stale component hash is being computed.  The writer
# must retain that edit and reject its candidate derived from the old snapshot.
stale_race_repo="$(make_fake_repo stale-race 4.2.0 "$old_commit" "$old_sha")"
stale_race_file="$stale_race_repo/modules/qubes/packages.scm"
stale_race_output="$work_dir/stale-race.out"
stale_race_expected="$work_dir/stale-race-expected.scm"
barrier_reached="$work_dir/hash.reached"
barrier_release="$work_dir/hash.release"
guix_block="hash"
: > "$guix_log"
: > "$mv_log"
run_writer "$stale_race_repo" > "$stale_race_output" 2>&1 &
writer_pid=$!
wait_for_barrier "$barrier_reached" "$writer_pid" "$stale_race_output"
cp -- "$stale_race_file" "$stale_race_expected"
printf '%s\n' '(define concurrent-hash-edit #t)' >> "$stale_race_file"
printf '%s\n' '(define concurrent-hash-edit #t)' >> "$stale_race_expected"
: > "$barrier_release"
if wait "$writer_pid"; then
    writer_pid=""
    fail "writer accepted an edit made while hashing"
fi
writer_pid=""
barrier_release=""
guix_block=""
cmp -s -- "$stale_race_expected" "$stale_race_file" ||
    fail "writer overwrote an edit made while hashing"
assert_contains "$stale_race_output" \
    'refused pin update: modules/qubes/packages.scm changed during refresh'
[ ! -s "$mv_log" ] || fail "hash-race refusal published a replacement"
assert_no_staging_files "$stale_race_repo"

# Force an edit after the complete candidate has been staged beside the
# destination.  This reaches the final comparison immediately before rename
# and also proves that a refused update cleans the destination-side temp file.
late_race_repo="$(make_fake_repo late-race 4.2.0 "$old_commit" "$old_sha")"
late_race_file="$late_race_repo/modules/qubes/packages.scm"
late_race_output="$work_dir/late-race.out"
late_race_expected="$work_dir/late-race-expected.scm"
barrier_reached="$work_dir/chmod.reached"
barrier_release="$work_dir/chmod.release"
chmod_block="destination-stage"
: > "$guix_log"
: > "$mv_log"
run_writer "$late_race_repo" > "$late_race_output" 2>&1 &
writer_pid=$!
wait_for_barrier "$barrier_reached" "$writer_pid" "$late_race_output"
cp -- "$late_race_file" "$late_race_expected"
printf '%s\n' '(define concurrent-late-edit #t)' >> "$late_race_file"
printf '%s\n' '(define concurrent-late-edit #t)' >> "$late_race_expected"
: > "$barrier_release"
if wait "$writer_pid"; then
    writer_pid=""
    fail "writer accepted an edit made after staging"
fi
writer_pid=""
barrier_release=""
chmod_block=""
cmp -s -- "$late_race_expected" "$late_race_file" ||
    fail "writer overwrote an edit made after staging"
assert_contains "$late_race_output" \
    'refused pin update: modules/qubes/packages.scm changed during refresh'
[ ! -s "$mv_log" ] || fail "late-race refusal published a replacement"
assert_no_staging_files "$late_race_repo"

# The all-current fast path must perform the same snapshot check even though it
# never clones or hashes anything.
noop_race_repo="$(make_fake_repo noop-race "$latest_tag" "$new_commit" "$new_sha")"
noop_race_file="$noop_race_repo/modules/qubes/packages.scm"
noop_race_output="$work_dir/noop-race.out"
noop_race_expected="$work_dir/noop-race-expected.scm"
barrier_reached="$work_dir/tag.reached"
barrier_release="$work_dir/tag.release"
git_block=tag-lookup
: > "$guix_log"
: > "$mv_log"
run_writer "$noop_race_repo" > "$noop_race_output" 2>&1 &
writer_pid=$!
wait_for_barrier "$barrier_reached" "$writer_pid" "$noop_race_output"
cp -- "$noop_race_file" "$noop_race_expected"
printf '%s\n' '(define concurrent-noop-edit #t)' >> "$noop_race_file"
printf '%s\n' '(define concurrent-noop-edit #t)' >> "$noop_race_expected"
: > "$barrier_release"
if wait "$writer_pid"; then
    writer_pid=""
    fail "all-current writer accepted a concurrent edit"
fi
writer_pid=""
barrier_release=""
git_block=""
cmp -s -- "$noop_race_expected" "$noop_race_file" ||
    fail "all-current writer overwrote a concurrent edit"
[ ! -s "$guix_log" ] || fail "all-current race invoked guix"
[ ! -s "$mv_log" ] || fail "all-current race published a replacement"
assert_contains "$noop_race_output" \
    'refused pin update: modules/qubes/packages.scm changed during refresh'
assert_no_staging_files "$noop_race_repo"

printf '%s\n' 'Qubes pin writer regression check passed'
