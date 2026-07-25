#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Replace an old binary Guix bootstrap with an authenticated, current Guix
# without letting the bootstrap daemon consume a substitute.  The security
# floor below is a minimum, not a channel pin: config/channels.scm stays
# unpinned and every invocation resolves its current authenticated head.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

readonly security_floor=897832f374dcdc9eeaf19d01e70b9a92fccfc68c
readonly guix_repository=https://codeberg.org/guix/guix.git
readonly guix_branch=master
readonly guix_introduction=9edb3f66fd807b096b48283debdcddccfea34bad
readonly guix_introduction_signer='BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA'
readonly official_substitute_urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org'

# This is the official checker embedded in the 2026-07-02 Guix advisory.  Pin
# both the artwork commit containing the post and the extracted Scheme block.
readonly advisory_source_url='https://codeberg.org/guix/artwork/raw/commit/8370c4f679731fe54bd66dd1785c56ab8ba5ba11/website/posts/2026-07-02-security-advisory.md'
readonly advisory_source_sha256=d410b62e5753c5a4d8d0446033fdd252980c0207cce8590cade381f498375428
readonly advisory_checker_sha256=a20c52fb0f968aa9b2bbddd96c3f55479bb70dede503a9a0a4534f34ffa283bb

channels="$repo_root/config/channels.scm"
bootstrap_profile=/var/guix/profiles/per-user/root/current-guix
build_users_group=guixbuild
work_dir=""
output_file="${GITHUB_OUTPUT:-}"
root_command=""
root_command_set=0

usage() {
    cat <<'EOF'
Usage: bootstrap-guix-secure.sh --work-dir DIR --output-file FILE [options]

Options:
  --work-dir DIR           New private directory for the fixed profile, source
                           checkout, daemon socket, and logs (required).
  --output-file FILE       Existing regular file to receive GitHub Actions
                           key=value outputs (required; defaults to GITHUB_OUTPUT).
  --channels FILE          Unpinned authenticated channels file.
                           Default: config/channels.scm.
  --bootstrap-profile DIR  Installed binary-bootstrap Guix profile.
  --build-users-group NAME guix-daemon build users group. Default: guixbuild.
  --root-command COMMAND   Single command used to run daemon/ACL operations as
                           root. Default: sudo when not already root.
  -h, --help               Show this help.

Outputs: guix_profile, guix_bin, guix_daemon_socket, guix_daemon_pid,
guix_commit, authenticated_guix_checkout, and guix_security_floor.  The caller
owns the final daemon and authenticated checkout after successful return.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --work-dir)
            require_arg "$1" "${2:-}"
            work_dir="$2"
            shift 2
            ;;
        --output-file)
            require_arg "$1" "${2:-}"
            output_file="$2"
            shift 2
            ;;
        --channels)
            require_arg "$1" "${2:-}"
            channels="$2"
            shift 2
            ;;
        --bootstrap-profile)
            require_arg "$1" "${2:-}"
            bootstrap_profile="$2"
            shift 2
            ;;
        --build-users-group)
            require_arg "$1" "${2:-}"
            build_users_group="$2"
            shift 2
            ;;
        --root-command)
            require_arg "$1" "${2:-}"
            root_command="$2"
            root_command_set=1
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$work_dir" ] || die "--work-dir is required"
[ -n "$output_file" ] || die "--output-file is required (or set GITHUB_OUTPUT)"
[ -r "$channels" ] || die "channels file is not readable: $channels"
[ -f "$output_file" ] && [ ! -L "$output_file" ] ||
    die "--output-file must be an existing regular file, not a symlink: $output_file"
case "$work_dir$output_file" in
    *$'\n'*|*$'\r'*) die "paths must not contain newlines" ;;
esac
case "$build_users_group" in
    ''|*[!A-Za-z0-9_-]*) die "invalid build users group: $build_users_group" ;;
esac

# A commit field here would turn the security floor into a permanent version
# pin.  Introductions are trust roots and are intentionally allowed.
if grep -Eq '\(commit([[:space:]]|\))' "$channels"; then
    die "channels file pins a commit; the secure refresh channel must stay unpinned"
fi

bootstrap_guix="$bootstrap_profile/bin/guix"
bootstrap_daemon="$bootstrap_profile/bin/guix-daemon"
[ -x "$bootstrap_guix" ] || die "bootstrap guix is not executable: $bootstrap_guix"
[ -x "$bootstrap_daemon" ] ||
    die "bootstrap guix-daemon is not executable: $bootstrap_daemon"

for command in awk cat chmod cmp curl env git grep mkdir python3 rm seq sha256sum sleep; do
    need "$command"
done
if [ "$root_command_set" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    root_command=sudo
fi
[ -z "$root_command" ] || need "$root_command"

case "$work_dir" in
    /*) ;;
    *) work_dir="$PWD/$work_dir" ;;
esac
work_parent="$(dirname -- "$work_dir")"
work_name="$(basename -- "$work_dir")"
case "$work_name" in
    ''|.|..) die "--work-dir must name a new, dedicated directory" ;;
esac
[ -d "$work_parent" ] || die "work directory parent does not exist: $work_parent"
work_parent="$(cd -- "$work_parent" && pwd -P)"
work_dir="$work_parent/$work_name"
[ ! -e "$work_dir" ] && [ ! -L "$work_dir" ] ||
    die "--work-dir already exists: $work_dir"
mkdir -m 700 -- "$work_dir"

profile="$work_dir/current-guix"
daemon_socket="$work_dir/daemon-socket"
source_checkout="$work_dir/guix-source"
describe_json="$work_dir/guix-describe.json"
advisory_source="$work_dir/2026-07-02-security-advisory.md"
advisory_checker="$work_dir/guix-substitute-and-pull-vuln-check.scm"
advisory_output="$work_dir/advisory-check.out"

daemon_pid=""
daemon_job_pid=""
handoff_daemon=0

run_root() {
    if [ -n "$root_command" ]; then
        "$root_command" "$@"
    else
        "$@"
    fi
}

daemon_alive() {
    local process_state=""

    [ -n "$daemon_pid" ] && run_root kill -0 "$daemon_pid" 2>/dev/null ||
        return 1
    if [ -r "/proc/$daemon_pid/stat" ]; then
        read -r _ _ process_state _ < "/proc/$daemon_pid/stat" || return 1
        [ "$process_state" != Z ] || return 1
    fi
}

stop_daemon() {
    local attempt

    if [ -z "$daemon_pid" ] && [ -n "$daemon_job_pid" ] &&
            kill -0 "$daemon_job_pid" 2>/dev/null; then
        # The privileged wrapper failed before recording its child PID.
        kill "$daemon_job_pid" 2>/dev/null || true
    fi
    if daemon_alive; then
        run_root kill "$daemon_pid" 2>/dev/null || true
        for attempt in $(seq 1 20); do
            daemon_alive || break
            sleep 0.25
        done
        if daemon_alive; then
            run_root kill -KILL "$daemon_pid" 2>/dev/null || true
        fi
    fi
    if [ -n "$daemon_job_pid" ]; then
        wait "$daemon_job_pid" 2>/dev/null || true
    fi
    if [ -e "$daemon_socket" ] || [ -L "$daemon_socket" ]; then
        run_root rm -f -- "$daemon_socket"
    fi
    daemon_pid=""
    daemon_job_pid=""
}

cleanup() {
    local status=$?

    trap - EXIT INT TERM
    if [ "$handoff_daemon" -ne 1 ]; then
        stop_daemon
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_daemon() {
    local phase=$1
    local daemon=$2
    local log_file=$3
    local pid_file="$work_dir/daemon-$phase.pid"
    local attempt recorded_pid=""
    shift 3

    [ -x "$daemon" ] || die "$phase daemon is not executable: $daemon"
    [ ! -e "$daemon_socket" ] && [ ! -L "$daemon_socket" ] ||
        die "refusing to replace an existing daemon socket: $daemon_socket"
    : > "$pid_file"
    chmod 600 "$pid_file"
    : > "$log_file"

    if [ -n "$root_command" ]; then
        # The variables deliberately expand in the privileged inner shell.
        # shellcheck disable=SC2016
        "$root_command" sh -c \
            'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
            sh "$pid_file" "$daemon" "$@" >> "$log_file" 2>&1 &
    else
        # shellcheck disable=SC2016
        sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
            sh "$pid_file" "$daemon" "$@" >> "$log_file" 2>&1 &
    fi
    daemon_job_pid=$!

    for attempt in $(seq 1 60); do
        if [ -s "$pid_file" ]; then
            read -r recorded_pid < "$pid_file"
            case "$recorded_pid" in
                ''|*[!0-9]*) recorded_pid="" ;;
                *) daemon_pid=$recorded_pid ;;
            esac
        fi
        if [ -S "$daemon_socket" ] && daemon_alive; then
            return 0
        fi
        if [ -n "$daemon_pid" ] && ! daemon_alive; then
            cat "$log_file" >&2
            die "$phase guix-daemon exited before becoming ready"
        fi
        sleep 1
    done
    cat "$log_file" >&2
    die "$phase guix-daemon socket did not become ready"
}

retry_network() {
    local attempt=1
    local maximum=3
    local delay

    until "$@"; do
        if [ "$attempt" -ge "$maximum" ]; then
            return 1
        fi
        delay=$((attempt * 15))
        printf 'network operation failed (attempt %d/%d); retrying in %ds\n' \
            "$attempt" "$maximum" "$delay" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

checksum() {
    local value

    value="$(sha256sum -- "$1")" || return
    printf '%s\n' "${value%% *}"
}

export GUIX_DAEMON_SOCKET="$daemon_socket"
unset GUIX_BUILD_OPTIONS GUIX_SUBSTITUTE_URLS

start_daemon \
    bootstrap "$bootstrap_daemon" "$work_dir/daemon-bootstrap.log" \
    --build-users-group="$build_users_group" \
    --listen="$daemon_socket" \
    --no-substitutes

# Both client and daemon prohibit substitutes.  Retrying this operation is
# safe: guix pull profiles are transactional and incomplete builds stay valid
# store objects or garbage.
retry_network env \
    -u GUIX_BUILD_OPTIONS -u GUIX_SUBSTITUTE_URLS \
    GUIX_DAEMON_SOCKET="$daemon_socket" \
    "$bootstrap_guix" pull \
    --no-substitutes \
    --channels="$channels" \
    --profile="$profile"

fixed_guix="$profile/bin/guix"
fixed_daemon="$profile/bin/guix-daemon"
[ -x "$fixed_guix" ] || die "guix pull did not produce an executable guix"
[ -x "$fixed_daemon" ] || die "guix pull did not produce an executable guix-daemon"

env -u GUIX_BUILD_OPTIONS -u GUIX_SUBSTITUTE_URLS \
    GUIX_DAEMON_SOCKET="$daemon_socket" \
    "$fixed_guix" describe --format=json --profile="$profile" > "$describe_json"

resolved_commit="$(python3 - "$describe_json" "$guix_repository" "$guix_branch" <<'PY'
import json
import re
import sys

path, expected_url, expected_branch = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    channels = json.load(source)
matches = [channel for channel in channels if channel.get("name") == "guix"]
if len(matches) != 1:
    raise SystemExit("guix describe must contain exactly one guix channel")
channel = matches[0]
if channel.get("url") != expected_url or channel.get("branch") != expected_branch:
    raise SystemExit("resolved guix channel does not match the authenticated source")
commit = channel.get("commit", "")
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("resolved guix commit is not a full lowercase object ID")
print(commit)
PY
)"

# Fetch the branch and keyring, authenticate from Guix's introduction through
# the exact revision selected by the unpinned pull, then apply the ancestry
# floor to that authenticated graph.
mkdir -m 700 -- "$source_checkout"
git -C "$source_checkout" init --quiet
git -C "$source_checkout" remote add origin "$guix_repository"
retry_network git -C "$source_checkout" fetch \
    --no-tags \
    origin \
    "+refs/heads/$guix_branch:refs/remotes/origin/$guix_branch" \
    '+refs/heads/keyring:refs/remotes/origin/keyring'
git -C "$source_checkout" cat-file -e "$resolved_commit^{commit}"
git -C "$source_checkout" cat-file -e "$security_floor^{commit}"
git -C "$source_checkout" checkout --quiet --detach "$resolved_commit"
env -u GUIX_BUILD_OPTIONS -u GUIX_SUBSTITUTE_URLS \
    GUIX_DAEMON_SOCKET="$daemon_socket" \
    "$fixed_guix" git authenticate \
    --repository="$source_checkout" \
    --end="$resolved_commit" \
    --keyring=refs/remotes/origin/keyring \
    "$guix_introduction" "$guix_introduction_signer"
git -C "$source_checkout" merge-base --is-ancestor \
    "$security_floor" "$resolved_commit" ||
    die "resolved Guix $resolved_commit predates security floor $security_floor"

retry_network curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --output "$advisory_source" \
    "$advisory_source_url"
[ "$(checksum "$advisory_source")" = "$advisory_source_sha256" ] ||
    die "official Guix advisory source checksum mismatch"
awk '
    $0 == "```scheme" && !seen { seen = 1; emit = 1; next }
    emit && $0 == "```" { complete = 1; exit }
    emit { print }
    END { if (!seen || !complete) exit 1 }
' "$advisory_source" > "$advisory_checker" ||
    die "could not extract the official Guix advisory checker"
[ "$(checksum "$advisory_checker")" = "$advisory_checker_sha256" ] ||
    die "official Guix advisory checker checksum mismatch"
chmod 600 "$advisory_checker"

# The bootstrap daemon has served its only purpose.  Bring up the fixed daemon
# without substitutes first, then authorize only the official keys shipped by
# that authenticated profile.  A final restart enables their URLs.
stop_daemon
start_daemon \
    fixed-safe "$fixed_daemon" "$work_dir/daemon-fixed-safe.log" \
    --build-users-group="$build_users_group" \
    --listen="$daemon_socket" \
    --no-substitutes

for key_name in ci.guix.gnu.org.pub bordeaux.guix.gnu.org.pub; do
    key_file="$profile/share/guix/$key_name"
    [ -f "$key_file" ] && [ -r "$key_file" ] ||
        die "fixed Guix profile lacks official substitute key: $key_name"
    run_root env \
        -u GUIX_BUILD_OPTIONS -u GUIX_SUBSTITUTE_URLS \
        GUIX_DAEMON_SOCKET="$daemon_socket" \
        "$fixed_guix" archive --authorize < "$key_file"
done

stop_daemon
start_daemon \
    fixed "$fixed_daemon" "$work_dir/daemon-fixed.log" \
    --build-users-group="$build_users_group" \
    --listen="$daemon_socket" \
    --substitute-urls="$official_substitute_urls"

if ! env \
        -u GUIX_BUILD_OPTIONS -u GUIX_SUBSTITUTE_URLS \
        LC_ALL=C \
        GUIX_DAEMON_SOCKET="$daemon_socket" \
        "$fixed_guix" repl -- "$advisory_checker" \
        > "$advisory_output" 2>&1; then
    cat "$advisory_output" >&2
    die "official Guix vulnerability checker did not pass"
fi
awk '
    /^(restore-file|fetch-narinfos|file-uris|cache-key):/ { print }
' "$advisory_output" > "$work_dir/advisory-results"
printf '%s\n' \
    'restore-file: not vulnerable' \
    'fetch-narinfos: not vulnerable' \
    'file-uris: not vulnerable' \
    'cache-key: not vulnerable' > "$work_dir/advisory-results.expected"
if ! cmp -s \
        "$work_dir/advisory-results.expected" \
        "$work_dir/advisory-results"; then
    cat "$advisory_output" >&2
    die "Guix vulnerability checker results are vulnerable or inconclusive"
fi

{
    printf 'guix_profile=%s\n' "$profile"
    printf 'guix_bin=%s\n' "$profile/bin"
    printf 'guix_daemon_socket=%s\n' "$daemon_socket"
    printf 'guix_daemon_pid=%s\n' "$daemon_pid"
    printf 'guix_commit=%s\n' "$resolved_commit"
    printf 'authenticated_guix_checkout=%s\n' "$source_checkout"
    printf 'guix_security_floor=%s\n' "$security_floor"
} >> "$output_file"

# From this point the caller owns the verified daemon.  Any earlier failure is
# fail-closed: the EXIT trap terminates whichever daemon was active.
handoff_daemon=1
