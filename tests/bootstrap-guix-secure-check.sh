#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d "$repo_root/work.bootstrap-secure.XXXXXX")"
fake_bin="$test_root/bin"
bootstrap_profile="$test_root/bootstrap-guix"
fixture_root="$test_root/fixtures"
guix_fixture="$fixture_root/guix"
guile_git_fixture="$fixture_root/guile-git"
event_log="$test_root/events"
mkdir -p \
    "$fake_bin" "$bootstrap_profile/bin" \
    "$guix_fixture/etc/substitutes" "$guix_fixture/scripts" \
    "$guile_git_fixture"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local output pid

    for output in "$test_root"/output-*; do
        [ -f "$output" ] || continue
        pid="$(sed -n 's/^guix_daemon_pid=//p' "$output")"
        case "$pid" in
            ''|*[!0-9]*) ;;
            *) kill "$pid" 2>/dev/null || true ;;
        esac
    done
    rm -rf -- "$test_root"
}
trap cleanup EXIT

# Authenticated Guix source is materialized only after the fake authentication
# and floor gates.  Configure installs the pre-inst-env fixture; make creates
# the native client/daemon outputs.
cat > "$guix_fixture/bootstrap" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'build:guix-bootstrap\n' >> "${EVENT_LOG:?}"
EOF

cat > "$guix_fixture/configure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'build:guix-configure:' >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"
root="$(cd -- "$(dirname -- "$0")" && pwd -P)"
cp -- "$root/.pre-inst-env-template" "$root/pre-inst-env"
chmod +x "$root/pre-inst-env"
EOF

cat > "$guix_fixture/.pre-inst-env-template" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")" && pwd -P)"
printf 'pre-inst:' >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"
# Bare names can resolve the vulnerable binary bootstrap from PATH.  Require
# the caller to select an artifact from this authenticated native build.
case "${1:-}" in
    "$root/scripts/guix"|"$root/guix-daemon") exec "$@" ;;
    *) exit 70 ;;
esac
EOF

printf '%s\n' 'ci-key' > "$guix_fixture/etc/substitutes/ci.guix.gnu.org.pub"
printf '%s\n' 'bordeaux-key' \
    > "$guix_fixture/etc/substitutes/bordeaux.guix.gnu.org.pub"

cat > "$guile_git_fixture/configure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${GUILE_LOAD_PATH:-}" ]
[ -z "${GUILE_LOAD_COMPILED_PATH:-}" ]
[ -n "${XDG_CACHE_HOME:-}" ] && [ -n "${XDG_CONFIG_HOME:-}" ]
printf 'build:guile-git-configure:' >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"
for argument in "$@"; do
    case "$argument" in
        --prefix=*) printf '%s\n' "${argument#--prefix=}" > .fake-prefix ;;
    esac
done
[ -s .fake-prefix ]
EOF

chmod +x \
    "$guix_fixture/bootstrap" "$guix_fixture/configure" \
    "$guix_fixture/.pre-inst-env-template" \
    "$guile_git_fixture/configure"

cat > "$fake_bin/guix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

role=unknown
case "$0" in
    "${FAKE_BOOTSTRAP_PROFILE:?}"/*) role=bootstrap ;;
    */guix-source/scripts/guix) role=native ;;
    */current-guix/bin/guix) role=fixed ;;
esac
[ "$role" != unknown ]
[ -z "${GUIX:-}" ]
[ -z "${GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES:-}" ]
[ -z "${GUIX_PACKAGE_PATH:-}" ]
[ -z "${GUIX_EXTENSIONS_PATH:-}" ]
[ -z "${GUIX_PULL_URL:-}" ]
[ -z "${NIX_STORE_DIR:-}" ]
printf 'guix:%s:' "$role" >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"

case "${1:-} ${2:-}" in
    'git authenticate')
        [ -n "${XDG_CACHE_HOME:-}" ]
        [ -n "${XDG_CONFIG_HOME:-}" ]
        [ "${GUIX_DAEMON_SOCKET:-}" = "${FAKE_RUN_DIR:?}/no-bootstrap-daemon" ]
        printf '%s\n' "$*" | grep -Fq -- '--keyring=origin/keyring'
        printf '%s\n' "$*" | grep -Fq -- \
            '--cache-key=9edb3f66fd807b096b48283debdcddccfea34bad'
        case "$role" in
            bootstrap)
                printf 'gate:authenticated-initial\n' >> "$EVENT_LOG"
                [ "${FAKE_MODE:?}" != initial-auth-failure ]
                ;;
            native)
                printf 'gate:authenticated-final\n' >> "$EVENT_LOG"
                [ "${FAKE_MODE:?}" != final-auth-failure ]
                ;;
            *) exit 31 ;;
        esac
        ;;
    'archive --authorize')
        [ "$role" = native ]
        IFS= read -r key
        printf 'gate:authorized:%s\n' "$key" >> "$EVENT_LOG"
        ;;
    'build --no-grafts')
        [ "${3:-}" = '--substitute-urls=https://ci.guix.gnu.org https://bordeaux.guix.gnu.org' ]
        [ "${4:-}" = cfunge ]
        [ "$#" -eq 4 ]
        case "$role" in
            native) xdg_phase=native ;;
            fixed) xdg_phase=fixed ;;
            *) exit 32 ;;
        esac
        [ "${XDG_CACHE_HOME:-}" = "${FAKE_RUN_DIR:?}/$xdg_phase-xdg-cache" ]
        [ "${XDG_CONFIG_HOME:-}" = "$FAKE_RUN_DIR/$xdg_phase-xdg-config" ]
        printf 'gate:advisory-prerequisite:%s\n' "$role" >> "$EVENT_LOG"
        if [ "${FAKE_MODE:?}" = "$role-prerequisite-failure" ]; then
            exit 1
        fi
        ;;
    'repl --')
        [ -s "${3:?}" ]
        [ "${LC_ALL:-}" = C ]
        case "$role" in
            native) xdg_phase=native ;;
            fixed) xdg_phase=fixed ;;
            *) exit 33 ;;
        esac
        [ "${XDG_CACHE_HOME:-}" = "${FAKE_RUN_DIR:?}/$xdg_phase-xdg-cache" ]
        [ "${XDG_CONFIG_HOME:-}" = "$FAKE_RUN_DIR/$xdg_phase-xdg-config" ]
        printf 'gate:advisory-check:%s\n' "$role" >> "$EVENT_LOG"
        vulnerable=0
        if [ "${FAKE_MODE:?}" = native-checker-failure ] &&
                [ "$role" = native ]; then
            vulnerable=1
        elif [ "$FAKE_MODE" = final-checker-failure ] &&
                [ "$role" = fixed ]; then
            vulnerable=1
        fi
        if [ "$vulnerable" -eq 1 ]; then
            printf '%s\n' \
                'restore-file: vulnerable' \
                'fetch-narinfos: not vulnerable' \
                'file-uris: not vulnerable' \
                'cache-key: not vulnerable'
            exit 1
        fi
        if [ "$FAKE_MODE" = final-checker-inconclusive ] &&
                [ "$role" = fixed ]; then
            printf '%s\n' \
                'restore-file: not vulnerable' \
                'fetch-narinfos: not vulnerable' \
                'file-uris: not vulnerable'
            exit 0
        fi
        printf '%s\n' \
            'restore-file: not vulnerable' \
            'fetch-narinfos: not vulnerable' \
            'file-uris: not vulnerable' \
            'cache-key: not vulnerable'
        ;;
    'pull '*)
        [ "$role" = native ]
        [[ " $* " != *' --no-substitutes '* ]]
        profile=""
        channels=""
        for argument in "$@"; do
            case "$argument" in
                --profile=*) profile="${argument#--profile=}" ;;
                --channels=*) channels="${argument#--channels=}" ;;
            esac
        done
        [ -n "$profile" ] && [ -r "$channels" ]
        printf 'gate:unpinned-pull\n' >> "$EVENT_LOG"
        mkdir -p "$profile/bin"
        ln -s "${FAKE_GUIX:?}" "$profile/bin/guix"
        ln -s "${FAKE_DAEMON:?}" "$profile/bin/guix-daemon"
        ;;
    'describe --format=json')
        [ "$role" = native ]
        printf '[{"name":"guix","url":"https://codeberg.org/guix/guix.git",'
        printf '"branch":"master","commit":"%s"}]\n' \
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        ;;
    *)
        printf 'unexpected fake guix invocation\n' >&2
        exit 30
        ;;
esac
EOF

cat > "$fake_bin/guix-daemon" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import socket
import sys

arguments = sys.argv[1:]
for name in (
    "GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES",
    "GUIX_PACKAGE_PATH",
    "GUIX_EXTENSIONS_PATH",
    "GUIX_PULL_URL",
    "NIX_STORE_DIR",
):
    if os.environ.get(name):
        raise SystemExit(f"unsafe ambient variable reached daemon: {name}")
listen = next(value.split("=", 1)[1] for value in arguments
              if value.startswith("--listen="))
if "/guix-source/" in sys.argv[0]:
    phase = "native-safe" if "--no-substitutes" in arguments else "native"
elif "/current-guix/" in sys.argv[0]:
    phase = "fixed"
else:
    raise SystemExit("unexpected daemon path")
xdg_phase = "native" if phase.startswith("native") else "fixed"
expected_cache = os.path.join(os.environ["FAKE_RUN_DIR"],
                              f"{xdg_phase}-xdg-cache")
expected_config = os.path.join(os.environ["FAKE_RUN_DIR"],
                               f"{xdg_phase}-xdg-config")
if os.environ.get("XDG_CACHE_HOME") != expected_cache:
    raise SystemExit("daemon has unexpected XDG cache")
if os.environ.get("XDG_CONFIG_HOME") != expected_config:
    raise SystemExit("daemon has unexpected XDG config")
with open(os.environ["EVENT_LOG"], "a", encoding="utf-8") as events:
    events.write(f"daemon:start:{phase}: {' '.join(arguments)}\n")

server = socket.socket(socket.AF_UNIX)
server.bind(listen)
server.listen(1)

def stop(_signum, _frame):
    server.close()
    try:
        os.unlink(listen)
    except FileNotFoundError:
        pass
    with open(os.environ["EVENT_LOG"], "a", encoding="utf-8") as events:
        events.write(f"daemon:stop:{phase}\n")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    signal.pause()
EOF

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ]
[ "${GIT_CONFIG_SYSTEM:-}" = /dev/null ]
[ "${GIT_CONFIG_NOSYSTEM:-}" = 1 ]
[ "${GIT_TERMINAL_PROMPT:-}" = 0 ]
[ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ]

directory=$PWD
if [ "${1:-}" = -C ]; then
    directory="${2:?}"
    shift 2
fi
operation="${1:?}"
shift
printf 'git:%s:%s:' "$directory" "$operation" >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"

initial=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
final=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
floor=897832f374dcdc9eeaf19d01e70b9a92fccfc68c
tag=a4811307677141cb3600aba42f8a6fd2ac096d4e
tag_commit=05d4a48c811f29c8db80ee6697fe658950fb503e

case "$operation" in
    init)
        printf '%s\n' "$*" | grep -Fq -- '--template='
        mkdir -p "$directory/.git"
        ;;
    remote) ;;
    fetch)
        case "$directory" in
            */guix-source)
                count_file="$directory/.fetch-count"
                count=0
                [ ! -f "$count_file" ] || read -r count < "$count_file"
                count=$((count + 1))
                printf '%s\n' "$count" > "$count_file"
                printf 'gate:fetch-guix:%s\n' "$count" >> "$EVENT_LOG"
                ;;
            */guile-git-source)
                printf 'gate:fetch-guile-git\n' >> "$EVENT_LOG"
                ;;
            *) exit 41 ;;
        esac
        ;;
    rev-parse)
        target="${*: -1}"
        case "$directory:$target" in
            */guix-source:*origin/master*|*/guix-source:*refs/remotes/origin/master*)
                printf '%s\n' "$initial"
                ;;
            */guile-git-source:*refs/tags/v0.10.0)
                if [ "${FAKE_MODE:?}" = tag-object-mismatch ]; then
                    printf '%040d\n' 0
                else
                    printf '%s\n' "$tag"
                fi
                ;;
            */guile-git-source:*"$tag^{commit}") printf '%s\n' "$tag_commit" ;;
            *) exit 42 ;;
        esac
        ;;
    cat-file)
        if [ "${1:-}" = -t ]; then
            printf '%s\n' tag
        elif [ "${1:-}" = -e ]; then
            :
        else
            exit 43
        fi
        ;;
    update-ref)
        [ "$directory" = "${FAKE_RUN_DIR:?}/guix-source" ]
        [ "${1:-}" = refs/heads/master ]
        [ "${2:-}" = "$initial" ]
        [ "${3:-}" = 0000000000000000000000000000000000000000 ]
        printf 'gate:initialized-local-guix-head\n' >> "$EVENT_LOG"
        ;;
    show)
        [ "$directory" = "${FAKE_RUN_DIR:?}/guix-source" ]
        [ "${1:-}" = refs/remotes/origin/keyring:civodul-3D9AEBB5.key ]
        printf '%s\n' 'fake authenticated OpenPGP key'
        ;;
    checkout)
        commit="${*: -1}"
        case "$directory:$commit" in
            */guix-source:"$initial")
                cp -a -- "${FAKE_GUIX_FIXTURE:?}/." "$directory/"
                printf 'gate:checkout-initial-guix\n' >> "$EVENT_LOG"
                ;;
            */guix-source:"$final")
                printf 'gate:checkout-final-guix\n' >> "$EVENT_LOG"
                ;;
            */guile-git-source:"$tag_commit")
                cp -a -- "${FAKE_GUILE_GIT_FIXTURE:?}/." "$directory/"
                printf 'gate:checkout-guile-git\n' >> "$EVENT_LOG"
                ;;
            *) exit 44 ;;
        esac
        ;;
    merge-base)
        [ "${1:-}" = --is-ancestor ]
        ancestor="${2:?}"
        descendant="${3:?}"
        if [ "$ancestor" = "$floor" ]; then
            if [ "$descendant" = "$initial" ]; then
                printf 'gate:security-floor-initial\n' >> "$EVENT_LOG"
                [ "${FAKE_MODE:?}" != floor-failure ]
            elif [ "$descendant" = "$final" ]; then
                printf 'gate:security-floor-final\n' >> "$EVENT_LOG"
            else
                exit 45
            fi
        elif [ "$ancestor" = "$final" ] && \
                [ "$descendant" = refs/remotes/origin/master ]; then
            printf 'gate:refreshed-branch-membership\n' >> "$EVENT_LOG"
            [ "${FAKE_MODE:?}" != branch-membership-failure ]
        elif [ "$ancestor" = "$initial" ] && [ "$descendant" = "$final" ]; then
            printf 'gate:authenticated-extension\n' >> "$EVENT_LOG"
            [ "${FAKE_MODE:?}" != extension-failure ]
        else
            exit 46
        fi
        ;;
    verify-tag)
        [ "${1:-}" = --raw ]
        [ "${2:-}" = "$tag" ]
        printf '%s\n' \
            '[GNUPG:] EXPKEYSIG 090B11993D9AEBB5 Fixture' >&2
        if [ "${FAKE_MODE:?}" = tag-signature-mismatch ]; then
            signer=0000000000000000000000000000000000000000
        else
            signer=3CE464558A84FDC69DB40CFB090B11993D9AEBB5
        fi
        printf '[GNUPG:] VALIDSIG %s 2025-04-17 1744920044 0 4 0 1 10 00 %s\n' \
            "$signer" "$signer" >&2
        exit 1
        ;;
    *) exit 47 ;;
esac
EOF

cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gpg:' >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"
case " $* " in
    *' --import '*) printf 'gate:imported-guile-git-key\n' >> "$EVENT_LOG" ;;
    *' --with-colons --fingerprint '*)
        signer=3CE464558A84FDC69DB40CFB090B11993D9AEBB5
        if [ "${FAKE_MODE:?}" = key-fingerprint-mismatch ]; then
            signer=0000000000000000000000000000000000000000
        fi
        printf 'pub:-:4096:1:090B11993D9AEBB5::::::::::\n'
        printf 'fpr:::::::::%s:\n' "$signer"
        ;;
    *) exit 51 ;;
esac
EOF

cat > "$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'make:%s:' "$PWD" >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"
case "$PWD" in
    */guile-git-source)
        [ -z "${GUILE_LOAD_PATH:-}" ]
        [ -z "${GUILE_LOAD_COMPILED_PATH:-}" ]
        [ -n "${XDG_CACHE_HOME:-}" ] && [ -n "${XDG_CONFIG_HOME:-}" ]
        if [[ " $* " == *' install '* ]]; then
            read -r prefix < .fake-prefix
            mkdir -p \
                "$prefix/share/guile/site/3.0/git" \
                "$prefix/lib/guile/3.0/site-ccache/git"
            printf 'gate:installed-guile-git\n' >> "$EVENT_LOG"
        else
            printf 'gate:built-guile-git\n' >> "$EVENT_LOG"
        fi
        ;;
    */guix-source)
        [[ " $* " == *' make-core-go '* ]]
        [[ " $* " == *' nix/libstore/schema.sql.hh '* ]]
        [[ " $* " == *' guix-daemon '* ]]
        [[ " $* " == *' scripts/guix '* ]]
        ln -s "${FAKE_GUIX:?}" scripts/guix
        ln -s "${FAKE_DAEMON:?}" guix-daemon
        printf 'gate:built-native-guix\n' >> "$EVENT_LOG"
        ;;
    *) exit 61 ;;
esac
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output="${2:?}"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$output" ]
printf '%s\n' '```scheme' '(display "fixture")' '```' > "$output"
printf 'gate:downloaded-pinned-advisory\n' >> "${EVENT_LOG:?}"
EOF

cat > "$fake_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${*: -1}"
case "$target" in
    *.md) digest=d410b62e5753c5a4d8d0446033fdd252980c0207cce8590cade381f498375428 ;;
    *.scm) digest=a20c52fb0f968aa9b2bbddd96c3f55479bb70dede503a9a0a4534f34ffa283bb ;;
    *) exit 1 ;;
esac
printf '%s  %s\n' "$digest" "$target"
EOF

cat > "$fake_bin/nproc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 2
EOF

cat > "$fake_bin/autoreconf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$PWD" in
    */guile-git-source) ;;
    *) exit 1 ;;
esac
[ "$*" = '-vfi' ]
printf 'build:guile-git-autoreconf\n' >> "${EVENT_LOG:?}"
EOF

cat > "$fake_bin/as-root" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF

chmod +x "$fake_bin"/*
ln -s "$fake_bin/guix" "$bootstrap_profile/bin/guix"

channels="$test_root/channels.scm"
cat > "$channels" <<'EOF'
(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
EOF

export FAKE_BOOTSTRAP_PROFILE="$bootstrap_profile"
export FAKE_GUIX="$fake_bin/guix"
export FAKE_DAEMON="$fake_bin/guix-daemon"
export FAKE_GUIX_FIXTURE="$guix_fixture"
export FAKE_GUILE_GIT_FIXTURE="$guile_git_fixture"
export EVENT_LOG="$event_log"
export PATH="$fake_bin:$PATH"
export GUIX=/untrusted/guix
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes
export GUIX_PACKAGE_PATH=/untrusted/packages
export GUIX_EXTENSIONS_PATH=/untrusted/extensions
export GUIX_PULL_URL=https://example.invalid/untrusted-guix.git
export GUILE_LOAD_PATH=/untrusted/guile-source
export GUILE_LOAD_COMPILED_PATH=/untrusted/guile-compiled
export NIX_STORE_DIR=/untrusted/store
export GIT_CONFIG_GLOBAL=/untrusted/gitconfig
export GIT_CONFIG_SYSTEM=/untrusted/system-gitconfig
export GIT_CONFIG_PARAMETERS="'core.hooksPath'='/untrusted/hooks'"
export GIT_DIR=/untrusted/git-dir
export GIT_WORK_TREE=/untrusted/git-work-tree

run_case() {
    local name=$1
    local mode=$2
    local channel_file=${3:-$channels}
    local output="$test_root/output-$name"
    local stderr="$test_root/stderr-$name"
    local run_dir="$test_root/run-$name"

    : > "$output"
    : > "$event_log"
    export FAKE_MODE="$mode"
    export FAKE_RUN_DIR="$run_dir"
    if "$repo_root/scripts/bootstrap-guix-secure.sh" \
            --work-dir "$run_dir" \
            --output-file "$output" \
            --channels "$channel_file" \
            --bootstrap-profile "$bootstrap_profile" \
            --root-command "$fake_bin/as-root" \
            > "$test_root/stdout-$name" 2> "$stderr"; then
        return 0
    else
        return $?
    fi
}

event_line() {
    local pattern=$1
    local line

    line="$(grep -n -m1 -E -- "$pattern" "$event_log" | cut -d: -f1)"
    [ -n "$line" ] || fail "missing event matching $pattern"
    printf '%s\n' "$line"
}

assert_absent() {
    local pattern=$1

    if grep -Eq -- "$pattern" "$event_log"; then
        fail "unexpected event matching $pattern"
    fi
}

# The successful path proves both authentication passes and the complete trust
# transition around the native unpinned pull.
run_case success success || {
    sed 's/^/  /' "$test_root/stderr-success" >&2
    fail "secure bootstrap success fixture failed"
}
initial_fetch="$(event_line '^gate:fetch-guix:1$')"
local_head="$(event_line '^gate:initialized-local-guix-head$')"
initial_auth="$(event_line '^gate:authenticated-initial$')"
initial_floor="$(event_line '^gate:security-floor-initial$')"
source_checkout="$(event_line '^gate:checkout-initial-guix$')"
tag_fetch="$(event_line '^gate:fetch-guile-git$')"
tag_verify="$(event_line '^git:.*/guile-git-source:verify-tag:')"
guile_build="$(event_line '^build:guile-git-autoreconf$')"
guile_install="$(event_line '^gate:installed-guile-git$')"
guix_build="$(event_line '^gate:built-native-guix$')"
safe_start="$(event_line '^daemon:start:native-safe:.*--no-substitutes')"
ci_key="$(event_line '^gate:authorized:ci-key$')"
bordeaux_key="$(event_line '^gate:authorized:bordeaux-key$')"
native_start="$(event_line '^daemon:start:native:.*--substitute-urls=https://ci\.guix\.gnu\.org https://bordeaux\.guix\.gnu\.org')"
native_prerequisite="$(event_line '^gate:advisory-prerequisite:native$')"
native_checker="$(event_line '^gate:advisory-check:native$')"
pull="$(event_line '^gate:unpinned-pull$')"
final_auth="$(event_line '^gate:authenticated-final$')"
branch_membership="$(event_line '^gate:refreshed-branch-membership$')"
extension="$(event_line '^gate:authenticated-extension$')"
final_floor="$(event_line '^gate:security-floor-final$')"
final_checkout="$(event_line '^gate:checkout-final-guix$')"
fixed_start="$(event_line '^daemon:start:fixed:.*--substitute-urls=https://ci\.guix\.gnu\.org https://bordeaux\.guix\.gnu\.org')"
fixed_prerequisite="$(event_line '^gate:advisory-prerequisite:fixed$')"
fixed_checker="$(event_line '^gate:advisory-check:fixed$')"

[ "$initial_fetch" -lt "$local_head" ] || fail "local Guix head preceded fetch"
[ "$local_head" -lt "$initial_auth" ] || fail "authentication ran with an unresolved HEAD"
[ "$initial_auth" -lt "$initial_floor" ] || fail "floor preceded initial authentication"
[ "$initial_floor" -lt "$source_checkout" ] || fail "Guix source executed before its floor"
[ "$source_checkout" -lt "$tag_fetch" ] || fail "Guile-Git fetch preceded authenticated source"
[ "$tag_verify" -lt "$guile_build" ] || fail "Guile-Git source executed before signature verification"
[ "$guile_build" -lt "$guile_install" ] || fail "Guile-Git install preceded its build"
[ "$guile_install" -lt "$guix_build" ] || fail "native Guix build preceded Guile-Git"
[ "$guix_build" -lt "$safe_start" ] || fail "native daemon preceded native build"
[ "$safe_start" -lt "$ci_key" ] || fail "key authorization preceded safe daemon"
[ "$ci_key" -lt "$bordeaux_key" ] || fail "official key order changed"
[ "$bordeaux_key" -lt "$native_start" ] || fail "substitutes preceded authorization"
[ "$native_start" -lt "$native_prerequisite" ] ||
    fail "native checker prerequisite preceded daemon"
[ "$native_prerequisite" -lt "$native_checker" ] ||
    fail "native checker preceded its prerequisite"
[ "$native_checker" -lt "$pull" ] || fail "pull preceded native checker"
[ "$pull" -lt "$final_auth" ] || fail "final authentication preceded pull"
[ "$final_auth" -lt "$branch_membership" ] ||
    fail "refreshed branch check preceded authentication"
[ "$branch_membership" -lt "$extension" ] ||
    fail "extension check preceded refreshed branch check"
[ "$extension" -lt "$final_floor" ] || fail "final floor preceded extension check"
[ "$final_floor" -lt "$final_checkout" ] || fail "final checkout preceded authentication"
[ "$final_checkout" -lt "$fixed_start" ] || fail "fixed daemon preceded final checkout"
[ "$fixed_start" -lt "$fixed_prerequisite" ] ||
    fail "final checker prerequisite preceded fixed daemon"
[ "$fixed_prerequisite" -lt "$fixed_checker" ] ||
    fail "final checker preceded its prerequisite"
if head -n "$initial_floor" "$event_log" | grep -q -- '--substitute-urls'; then
    fail "a substitute URL was enabled before the initial authenticated floor"
fi
assert_absent '^daemon:start:bootstrap:'
assert_absent 'pull --no-substitutes'
grep -q '^guix_profile=.*/run-success/current-guix$' \
    "$test_root/output-success" || fail "fixed profile output missing"
grep -q '^guix_bin=.*/run-success/current-guix/bin$' \
    "$test_root/output-success" || fail "fixed bin output missing"
grep -q '^guix_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb$' \
    "$test_root/output-success" || fail "resolved commit output missing"
grep -q '^authenticated_guix_checkout=.*/run-success/guix-source$' \
    "$test_root/output-success" || fail "authenticated checkout output missing"
grep -q '^guix_security_floor=897832f374dcdc9eeaf19d01e70b9a92fccfc68c$' \
    "$test_root/output-success" || fail "security floor output missing"
[ -d "$test_root/run-success/guix-source/.git" ] ||
    fail "authenticated checkout was not retained for the caller"

# Authentication, floor, key, and tag failures all stop before untrusted build
# inputs can execute.
for mode in initial-auth-failure floor-failure; do
    if run_case "$mode" "$mode"; then
        fail "$mode unexpectedly succeeded"
    fi
    assert_absent '^gate:checkout-initial-guix$'
    assert_absent '^build:'
    assert_absent '^daemon:start:'
    [ ! -s "$test_root/output-$mode" ] || fail "$mode emitted trusted outputs"
done

for mode in tag-object-mismatch tag-signature-mismatch key-fingerprint-mismatch; do
    if run_case "$mode" "$mode"; then
        fail "$mode unexpectedly succeeded"
    fi
    event_line '^gate:checkout-initial-guix$' >/dev/null
    assert_absent '^build:guile-git-autoreconf$'
    assert_absent '^gate:built-native-guix$'
    assert_absent '^daemon:start:'
    [ ! -s "$test_root/output-$mode" ] || fail "$mode emitted trusted outputs"
done

# Native checker failure prevents the pull; failures after the pull still stop
# the native/final daemon and emit no handoff outputs.
if run_case native-checker-failure native-checker-failure; then
    fail "native checker failure unexpectedly succeeded"
fi
event_line '^gate:advisory-check:native$' >/dev/null
event_line '^daemon:stop:native$' >/dev/null
assert_absent '^gate:unpinned-pull$'
assert_absent '^daemon:start:fixed:'

if run_case native-prerequisite-failure native-prerequisite-failure; then
    fail "native checker prerequisite failure unexpectedly succeeded"
fi
event_line '^gate:advisory-prerequisite:native$' >/dev/null
event_line '^daemon:stop:native$' >/dev/null
assert_absent '^gate:advisory-check:native$'
assert_absent '^gate:unpinned-pull$'
assert_absent '^daemon:start:fixed:'
[ ! -s "$test_root/output-native-prerequisite-failure" ] ||
    fail "native checker prerequisite failure emitted trusted outputs"

for mode in final-auth-failure branch-membership-failure extension-failure; do
    if run_case "$mode" "$mode"; then
        fail "$mode unexpectedly succeeded"
    fi
    event_line '^gate:unpinned-pull$' >/dev/null
    event_line '^daemon:stop:native$' >/dev/null
    assert_absent '^daemon:start:fixed:'
    [ ! -s "$test_root/output-$mode" ] || fail "$mode emitted trusted outputs"
done

for mode in final-checker-failure final-checker-inconclusive; do
    if run_case "$mode" "$mode"; then
        fail "$mode unexpectedly succeeded"
    fi
    event_line '^gate:advisory-check:fixed$' >/dev/null
    event_line '^daemon:stop:fixed$' >/dev/null
    [ ! -s "$test_root/output-$mode" ] ||
        fail "$mode emitted trusted outputs"
done

if run_case fixed-prerequisite-failure fixed-prerequisite-failure; then
    fail "fixed checker prerequisite failure unexpectedly succeeded"
fi
event_line '^gate:advisory-prerequisite:fixed$' >/dev/null
event_line '^daemon:stop:fixed$' >/dev/null
assert_absent '^gate:advisory-check:fixed$'
[ ! -s "$test_root/output-fixed-prerequisite-failure" ] ||
    fail "fixed checker prerequisite failure emitted trusted outputs"

# Pinning the channel is rejected before any external command is launched.
pinned_channels="$test_root/channels-pinned.scm"
sed '/(branch/a\        (commit "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")' \
    "$channels" > "$pinned_channels"
if run_case pinned success "$pinned_channels"; then
    fail "pinned Guix channel unexpectedly succeeded"
fi
[ ! -s "$event_log" ] || fail "pinned channel launched external commands"

printf '%s\n' 'secure Guix bootstrap contract: PASS'
