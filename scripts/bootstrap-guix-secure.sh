#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build a current Guix from authenticated source before allowing substitutes.
# The signed Guix 1.5 binary is used only to authenticate Git history.  The
# security floor below is a minimum, not a channel pin: config/channels.scm
# stays unpinned and each invocation resolves its current authenticated head.
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

# Current Guix needs a newer Guile-Git than Ubuntu 24.04 ships.  Pin both the
# signed annotated tag object and its peeled commit, and verify the signature
# with the maintainer key from Guix's authenticated keyring before executing
# any of this source.
readonly guile_git_repository=https://codeberg.org/guile-git/guile-git.git
readonly guile_git_tag=v0.10.0
readonly guile_git_tag_object=a4811307677141cb3600aba42f8a6fd2ac096d4e
readonly guile_git_commit=05d4a48c811f29c8db80ee6697fe658950fb503e
readonly guile_git_signer=3CE464558A84FDC69DB40CFB090B11993D9AEBB5
readonly guile_git_key=civodul-3D9AEBB5.key

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
  --work-dir DIR           New private directory for the profile, authenticated
                           source, daemon socket, and logs (required).
  --output-file FILE       Existing regular file to receive GitHub Actions
                           key=value outputs (required; defaults to GITHUB_OUTPUT).
  --channels FILE          Unpinned authenticated channels file.
                           Default: config/channels.scm.
  --bootstrap-profile DIR  Signed Guix 1.5 binary-bootstrap profile.  It is
                           used only for local Git authentication.
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
[ -x "$bootstrap_guix" ] || die "bootstrap guix is not executable: $bootstrap_guix"

for command in autoreconf awk cat chmod cmp curl env git gpg grep make mkdir \
        nproc python3 rm seq sha256sum sleep; do
    need "$command"
done
env_command="$(command -v env)"
if [ "$root_command_set" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    root_command=sudo
fi
[ -z "$root_command" ] || need "$root_command"

# Do not let ambient Git configuration redirect the reviewed HTTPS remotes,
# install executable template hooks, or relocate the repositories.  HOME is
# deliberately left untouched; Git's explicit config controls are sufficient.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
unset GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE

# These variables can replace Guix modules, redirect the pull, move state and
# authorization files, or explicitly disable substitute authentication.  None
# is a valid caller override for this trust bootstrap.
unset GUIX GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES GUIX_BUILD_OPTIONS
unset GUIX_CONFIGURATION_DIRECTORY GUIX_DAEMON_SOCKET GUIX_DATABASE_DIRECTORY
unset GUIX_DOWNLOAD_METHODS GUIX_EXTENSIONS_PATH GUIX_LOG_DIRECTORY
unset GUIX_PACKAGE_PATH GUIX_PROFILE GUIX_PULL_URL GUIX_STATE_DIRECTORY
unset GUIX_SUBSTITUTE_URLS GUIX_TLS_CERTIFICATE_DIRECTORY GUIX_UNINSTALLED
unset NIX_CONF_DIR NIX_DB_DIR NIX_LOG_DIR NIX_REMOTE NIX_STATE_DIR
unset NIX_STORE NIX_STORE_DIR

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
case "$work_dir" in
    *[?#]*) die "--work-dir cannot contain '?' or '#'" ;;
esac
[ ! -e "$work_dir" ] && [ ! -L "$work_dir" ] ||
    die "--work-dir already exists: $work_dir"
mkdir -m 700 -- "$work_dir"

profile="$work_dir/current-guix"
daemon_socket="$work_dir/daemon-socket"
source_checkout="$work_dir/guix-source"
guile_git_checkout="$work_dir/guile-git-source"
guile_git_prefix="$work_dir/guile-git"
guile_git_gnupg="$work_dir/guile-git-gnupg"
bootstrap_xdg_cache="$work_dir/bootstrap-xdg-cache"
bootstrap_xdg_config="$work_dir/bootstrap-xdg-config"
final_xdg_cache="$work_dir/final-xdg-cache"
final_xdg_config="$work_dir/final-xdg-config"
native_xdg_cache="$work_dir/native-xdg-cache"
native_xdg_config="$work_dir/native-xdg-config"
host_build_xdg_cache="$work_dir/host-build-xdg-cache"
host_build_xdg_config="$work_dir/host-build-xdg-config"
native_prefix="$work_dir/native-guix"
empty_git_template="$work_dir/empty-git-template"
describe_json="$work_dir/guix-describe.json"
advisory_source="$work_dir/2026-07-02-security-advisory.md"
advisory_checker="$work_dir/guix-substitute-and-pull-vuln-check.scm"

mkdir -m 700 -- \
    "$bootstrap_xdg_cache" "$bootstrap_xdg_config" \
    "$final_xdg_cache" "$final_xdg_config" \
    "$native_xdg_cache" "$native_xdg_config" \
    "$host_build_xdg_cache" "$host_build_xdg_config" \
    "$guile_git_gnupg" "$empty_git_template"

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
    local command=$2
    local log_file=$3
    local pid_file="$work_dir/daemon-$phase.pid"
    local attempt recorded_pid=""
    shift 3

    [ -x "$command" ] || die "$phase daemon command is not executable: $command"
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
            sh "$pid_file" "$command" "$@" >> "$log_file" 2>&1 &
    else
        # shellcheck disable=SC2016
        sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
            sh "$pid_file" "$command" "$@" >> "$log_file" 2>&1 &
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

authenticate_guix() {
    local guix=$1
    local end=$2
    local xdg_cache=$3
    local xdg_config=$4

    env \
        -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
        -u GUIX_BUILD_OPTIONS -u GUIX_DOWNLOAD_METHODS \
        -u GUIX_SUBSTITUTE_URLS -u GUIX \
        XDG_CACHE_HOME="$xdg_cache" \
        XDG_CONFIG_HOME="$xdg_config" \
        GUIX_DAEMON_SOCKET="$work_dir/no-bootstrap-daemon" \
        "$guix" git authenticate \
        --repository="$source_checkout" \
        --end="$end" \
        --keyring=origin/keyring \
        --cache-key="$guix_introduction" \
        "$guix_introduction" "$guix_introduction_signer"
}

check_security_floor() {
    local commit=$1

    git -C "$source_checkout" merge-base --is-ancestor \
        "$security_floor" "$commit" ||
        die "resolved Guix $commit predates security floor $security_floor"
}

# Fetch objects without checking out or executing repository content.  Guix
# 1.5 authenticates the full history from the official introduction; only then
# is the source materialized for the native build.
mkdir -m 700 -- "$source_checkout"
git -C "$source_checkout" init --quiet --template="$empty_git_template"
git -C "$source_checkout" remote add origin "$guix_repository"
retry_network git -C "$source_checkout" fetch \
    --no-tags \
    origin \
    "+refs/heads/$guix_branch:refs/remotes/origin/$guix_branch" \
    '+refs/heads/keyring:refs/remotes/origin/keyring'
authenticated_head="$(
    git -C "$source_checkout" rev-parse --verify \
        "refs/remotes/origin/$guix_branch^{commit}"
)"
[[ "$authenticated_head" =~ ^[0-9a-f]{40}$ ]] ||
    die "fetched Guix head is not a full lowercase object ID"
git -C "$source_checkout" cat-file -e "$security_floor^{commit}"
# `guix git authenticate` inspects HEAD even when --end is explicit.  A fresh
# non-bare repository starts with HEAD pointing at refs/heads/master, so make
# that ref resolve to the fetched candidate without checking out or executing
# any unauthenticated source.  Requiring the ref not to exist keeps this a
# one-time initialization rather than a hidden branch update.
git -C "$source_checkout" update-ref \
    "refs/heads/$guix_branch" "$authenticated_head" \
    0000000000000000000000000000000000000000
authenticate_guix \
    "$bootstrap_guix" "$authenticated_head" \
    "$bootstrap_xdg_cache" "$bootstrap_xdg_config"
check_security_floor "$authenticated_head"
git -C "$source_checkout" checkout --quiet --detach "$authenticated_head"

# Verify and build the host Guile-Git needed by current Guix.  The key is read
# from the already authenticated Guix keyring.  The historical signing key is
# expired today, so git-verify-tag exits nonzero even though it emits VALIDSIG;
# accept only the exact primary fingerprint and exact pinned tag object.
mkdir -m 700 -- "$guile_git_checkout"
git -C "$guile_git_checkout" init --quiet --template="$empty_git_template"
git -C "$guile_git_checkout" remote add origin "$guile_git_repository"
retry_network git -C "$guile_git_checkout" fetch \
    --no-tags \
    origin \
    "+refs/tags/$guile_git_tag:refs/tags/$guile_git_tag"
[ "$(git -C "$guile_git_checkout" rev-parse --verify \
        "refs/tags/$guile_git_tag")" = "$guile_git_tag_object" ] ||
    die "Guile-Git tag object does not match the reviewed object"
[ "$(git -C "$guile_git_checkout" cat-file -t "$guile_git_tag_object")" = tag ] ||
    die "Guile-Git release reference is not an annotated tag"
[ "$(git -C "$guile_git_checkout" rev-parse --verify \
        "$guile_git_tag_object^{commit}")" = "$guile_git_commit" ] ||
    die "Guile-Git tag does not resolve to the reviewed commit"

guile_git_key_file="$work_dir/$guile_git_key"
git -C "$source_checkout" show \
    "refs/remotes/origin/keyring:$guile_git_key" > "$guile_git_key_file"
chmod 600 "$guile_git_key_file"
GNUPGHOME="$guile_git_gnupg" gpg --batch --import "$guile_git_key_file" \
    > "$work_dir/guile-git-key-import.log" 2>&1
primary_fingerprint="$(
    GNUPGHOME="$guile_git_gnupg" gpg --batch --with-colons --fingerprint \
        "$guile_git_signer" 2>/dev/null |
        awk -F: '$1 == "pub" { public = 1; next }
                  public && $1 == "fpr" { print $10; exit }'
)"
[ "$primary_fingerprint" = "$guile_git_signer" ] ||
    die "Guile-Git signing key has an unexpected primary fingerprint"

set +e
GNUPGHOME="$guile_git_gnupg" git -C "$guile_git_checkout" verify-tag \
    --raw "$guile_git_tag_object" \
    > "$work_dir/guile-git-tag-status" 2>&1
verify_tag_status=$?
set -e
# A zero status is allowed too if the authenticated keyring is renewed later.
if [ "$verify_tag_status" -ne 0 ] &&
        ! grep -Fq '[GNUPG:] EXPKEYSIG ' "$work_dir/guile-git-tag-status"; then
    cat "$work_dir/guile-git-tag-status" >&2
    die "Guile-Git tag signature verification failed"
fi
valid_signature_count="$(
    awk -v fingerprint="$guile_git_signer" '
        $1 == "[GNUPG:]" && $2 == "VALIDSIG" && NF == 12 &&
        $3 == fingerprint && $12 == fingerprint { count++ }
        END { print count + 0 }
    ' "$work_dir/guile-git-tag-status"
)"
[ "$valid_signature_count" -eq 1 ] || {
    cat "$work_dir/guile-git-tag-status" >&2
    die "Guile-Git tag lacks the exact expected valid signature"
}
if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|NO_PUBKEY|REVKEYSIG) ' \
        "$work_dir/guile-git-tag-status"; then
    cat "$work_dir/guile-git-tag-status" >&2
    die "Guile-Git tag reported a bad or revoked signature"
fi

git -C "$guile_git_checkout" checkout --quiet --detach "$guile_git_commit"
run_host_build() {
    env \
        -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
        XDG_CACHE_HOME="$host_build_xdg_cache" \
        XDG_CONFIG_HOME="$host_build_xdg_config" \
        "$@"
}
(
    cd -- "$guile_git_checkout"
    run_host_build autoreconf -vfi
    run_host_build ./configure --prefix="$guile_git_prefix"
    run_host_build make -j"$(nproc)"
    run_host_build make install
)

guile_load_path="$guile_git_prefix/share/guile/site/3.0"
guile_compiled_path="$guile_git_prefix/lib/guile/3.0/site-ccache"
[ -d "$guile_load_path/git" ] || die "Guile-Git source modules were not installed"
[ -d "$guile_compiled_path/git" ] ||
    die "Guile-Git compiled modules were not installed"

# Build just the native Guix core, command launcher, and daemon.  This avoids
# the multi-hour source-only `guix pull` while still ensuring that no Guix
# source executes before authentication and the security-floor check.
(
    cd -- "$source_checkout"
    env \
        GUILE_LOAD_PATH="$guile_load_path" \
        GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
        ./bootstrap
    env \
        GUILE_LOAD_PATH="$guile_load_path" \
        GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
        ./configure \
        --prefix="$native_prefix" \
        --localstatedir=/var \
        --sysconfdir=/etc
    env \
        GUILE_LOAD_PATH="$guile_load_path" \
        GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
        make -j"$(nproc)" \
        make-core-go nix/libstore/schema.sql.hh guix-daemon scripts/guix
)

native_pre_inst="$source_checkout/pre-inst-env"
native_daemon="$source_checkout/guix-daemon"
[ -x "$native_pre_inst" ] || die "native Guix build lacks pre-inst-env"
[ -x "$native_daemon" ] || die "native Guix build lacks guix-daemon"
[ -x "$source_checkout/scripts/guix" ] || die "native Guix build lacks guix"

run_native_guix() {
    env \
        -u GUIX_BUILD_OPTIONS -u GUIX_DOWNLOAD_METHODS \
        -u GUIX_SUBSTITUTE_URLS \
        GUILE_LOAD_PATH="$guile_load_path" \
        GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
        XDG_CACHE_HOME="$native_xdg_cache" \
        XDG_CONFIG_HOME="$native_xdg_config" \
        GUIX_DAEMON_SOCKET="$daemon_socket" \
        "$native_pre_inst" guix "$@"
}

authenticate_with_native_guix() {
    local end=$1

    env \
        -u GUIX_BUILD_OPTIONS -u GUIX_DOWNLOAD_METHODS \
        -u GUIX_SUBSTITUTE_URLS \
        GUILE_LOAD_PATH="$guile_load_path" \
        GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
        XDG_CACHE_HOME="$final_xdg_cache" \
        XDG_CONFIG_HOME="$final_xdg_config" \
        GUIX_DAEMON_SOCKET="$work_dir/no-bootstrap-daemon" \
        "$native_pre_inst" guix git authenticate \
        --repository="$source_checkout" \
        --end="$end" \
        --keyring=origin/keyring \
        --cache-key="$guix_introduction" \
        "$guix_introduction" "$guix_introduction_signer"
}

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

check_advisory() {
    local phase=$1
    local output="$work_dir/advisory-$phase.out"
    local results="$work_dir/advisory-$phase.results"
    local LC_ALL=C
    shift

    export LC_ALL

    if ! "$@" repl -- "$advisory_checker" > "$output" 2>&1; then
        cat "$output" >&2
        die "$phase Guix vulnerability checker did not pass"
    fi
    awk '
        /^(restore-file|fetch-narinfos|file-uris|cache-key):/ { print }
    ' "$output" > "$results"
    printf '%s\n' \
        'restore-file: not vulnerable' \
        'fetch-narinfos: not vulnerable' \
        'file-uris: not vulnerable' \
        'cache-key: not vulnerable' > "$results.expected"
    if ! cmp -s "$results.expected" "$results"; then
        cat "$output" >&2
        die "$phase Guix vulnerability checker results are vulnerable or inconclusive"
    fi
}

# Start the authenticated native daemon with substitutes disabled, authorize
# only keys from the authenticated source, then restart with official URLs and
# require the advisory checker to pass before the unpinned pull.
start_daemon \
    native-safe "$env_command" "$work_dir/daemon-native-safe.log" \
    GUILE_LOAD_PATH="$guile_load_path" \
    GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
    "$native_pre_inst" guix-daemon \
    --build-users-group="$build_users_group" \
    --listen="$daemon_socket" \
    --no-substitutes

for key_name in ci.guix.gnu.org.pub bordeaux.guix.gnu.org.pub; do
    key_file="$source_checkout/etc/substitutes/$key_name"
    [ -f "$key_file" ] && [ -r "$key_file" ] ||
        die "authenticated Guix source lacks official substitute key: $key_name"
    run_root env \
        -u GUIX_BUILD_OPTIONS -u GUIX_DOWNLOAD_METHODS \
        -u GUIX_SUBSTITUTE_URLS \
        GUILE_LOAD_PATH="$guile_load_path" \
        GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
        GUIX_DAEMON_SOCKET="$daemon_socket" \
        "$native_pre_inst" guix archive --authorize < "$key_file"
done

stop_daemon
start_daemon \
    native "$env_command" "$work_dir/daemon-native.log" \
    GUILE_LOAD_PATH="$guile_load_path" \
    GUILE_LOAD_COMPILED_PATH="$guile_compiled_path" \
    "$native_pre_inst" guix-daemon \
    --build-users-group="$build_users_group" \
    --listen="$daemon_socket" \
    --substitute-urls="$official_substitute_urls"

check_advisory native run_native_guix

# This is the only pull.  It remains unpinned and now has authenticated,
# advisory-checked native Guix plus official substitutes, instead of asking the
# old binary bootstrap to build all of current Guix without substitutes.
retry_network run_native_guix pull \
    --channels="$channels" \
    --profile="$profile"

fixed_guix="$profile/bin/guix"
fixed_daemon="$profile/bin/guix-daemon"
[ -x "$fixed_guix" ] || die "guix pull did not produce an executable guix"
[ -x "$fixed_daemon" ] || die "guix pull did not produce an executable guix-daemon"

run_native_guix describe --format=json --profile="$profile" > "$describe_json"

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

# The branch may have advanced while the native pull ran.  Fetch and
# authenticate the exact revision recorded by the profile, require it to extend
# both the initially authenticated head and the security floor, and only then
# update the retained checkout.
retry_network git -C "$source_checkout" fetch \
    --no-tags \
    origin \
    "+refs/heads/$guix_branch:refs/remotes/origin/$guix_branch" \
    '+refs/heads/keyring:refs/remotes/origin/keyring'
git -C "$source_checkout" cat-file -e "$resolved_commit^{commit}"
authenticate_with_native_guix "$resolved_commit"
git -C "$source_checkout" merge-base --is-ancestor \
    "$resolved_commit" "refs/remotes/origin/$guix_branch" ||
    die "pulled Guix revision is not on the refreshed channel branch"
git -C "$source_checkout" merge-base --is-ancestor \
    "$authenticated_head" "$resolved_commit" ||
    die "pulled Guix revision does not extend the initially authenticated head"
check_security_floor "$resolved_commit"

# The native daemon's GUIX points into the source tree, so stop it before
# switching that checkout to the newly authenticated revision.
stop_daemon
git -C "$source_checkout" checkout --quiet --detach "$resolved_commit"

start_daemon \
    fixed "$env_command" "$work_dir/daemon-fixed.log" \
    -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH -u GUIX \
    "$fixed_daemon" \
    --build-users-group="$build_users_group" \
    --listen="$daemon_socket" \
    --substitute-urls="$official_substitute_urls"

check_advisory fixed env \
    -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
    -u GUIX_BUILD_OPTIONS -u GUIX_DOWNLOAD_METHODS \
    -u GUIX_SUBSTITUTE_URLS \
    GUIX_DAEMON_SOCKET="$daemon_socket" \
    "$fixed_guix"

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
