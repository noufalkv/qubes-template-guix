#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d "$repo_root/work.bootstrap-secure.XXXXXX")"
fake_bin="$test_root/bin"
bootstrap_profile="$test_root/bootstrap-guix"
event_log="$test_root/events"
mkdir -p "$fake_bin" "$bootstrap_profile/bin"

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

cat > "$fake_bin/guix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

role=fixed
case "$0" in
    "${FAKE_BOOTSTRAP_PROFILE:?}"/*) role=bootstrap ;;
esac
printf 'guix:%s:' "$role" >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"

case "${1:-} ${2:-}" in
    'pull --no-substitutes')
        [ "$role" = bootstrap ]
        profile=""
        channels=""
        for argument in "$@"; do
            case "$argument" in
                --profile=*) profile="${argument#--profile=}" ;;
                --channels=*) channels="${argument#--channels=}" ;;
                --substitute-urls*) exit 31 ;;
            esac
        done
        [ -n "$profile" ] && [ -r "$channels" ]
        mkdir -p "$profile/bin" "$profile/share/guix"
        ln -s "${FAKE_GUIX:?}" "$profile/bin/guix"
        ln -s "${FAKE_DAEMON:?}" "$profile/bin/guix-daemon"
        printf 'ci-key\n' > "$profile/share/guix/ci.guix.gnu.org.pub"
        printf 'bordeaux-key\n' > \
            "$profile/share/guix/bordeaux.guix.gnu.org.pub"
        ;;
    'describe --format=json')
        printf '[{"name":"guix","url":"https://codeberg.org/guix/guix.git",'
        printf '"branch":"master","commit":"%s"}]\n' \
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        ;;
    'git authenticate')
        printf 'gate:authenticated-source\n' >> "$EVENT_LOG"
        ;;
    'archive --authorize')
        IFS= read -r key
        printf 'gate:authorized:%s\n' "$key" >> "$EVENT_LOG"
        ;;
    'repl --')
        [ -s "${3:?}" ]
        printf 'gate:advisory-check\n' >> "$EVENT_LOG"
        case "${FAKE_MODE:?}" in
            success)
                printf '%s\n' \
                    'restore-file: not vulnerable' \
                    'fetch-narinfos: not vulnerable' \
                    'file-uris: not vulnerable' \
                    'cache-key: not vulnerable'
                ;;
            checker-vulnerable)
                printf '%s\n' \
                    'restore-file: vulnerable' \
                    'fetch-narinfos: not vulnerable' \
                    'file-uris: not vulnerable' \
                    'cache-key: not vulnerable'
                exit 1
                ;;
            checker-error)
                printf '%s\n' \
                    'restore-file: not vulnerable' \
                    'fetch-narinfos: error: no result' \
                    'file-uris: not vulnerable' \
                    'cache-key: not vulnerable'
                exit 1
                ;;
            checker-inconclusive)
                printf '%s\n' \
                    'restore-file: not vulnerable' \
                    'fetch-narinfos: not vulnerable' \
                    'file-uris: not vulnerable'
                ;;
            *) exit 32 ;;
        esac
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
listen = next(value.split("=", 1)[1] for value in arguments
              if value.startswith("--listen="))
bootstrap = sys.argv[0].startswith(os.environ["FAKE_BOOTSTRAP_PROFILE"] + "/")
if bootstrap:
    phase = "bootstrap"
elif "--no-substitutes" in arguments:
    phase = "fixed-safe"
else:
    phase = "fixed"
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
printf 'git:' >> "${EVENT_LOG:?}"
printf ' %s' "$@" >> "$EVENT_LOG"
printf '\n' >> "$EVENT_LOG"
case " $* " in
    *' merge-base --is-ancestor '*)
        printf 'gate:security-floor\n' >> "$EVENT_LOG"
        [ "${FAKE_MODE:?}" != floor-failure ]
        ;;
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
printf 'gate:checksum:%s\n' "${target##*/}" >> "${EVENT_LOG:?}"
EOF

cat > "$fake_bin/as-root" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF

chmod +x "$fake_bin"/*
ln -s "$fake_bin/guix" "$bootstrap_profile/bin/guix"
ln -s "$fake_bin/guix-daemon" "$bootstrap_profile/bin/guix-daemon"

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
export EVENT_LOG="$event_log"
export PATH="$fake_bin:$PATH"

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

# The successful path proves the complete trust transition and its ordering.
run_case success success || fail "secure bootstrap success fixture failed"
bootstrap_start="$(event_line '^daemon:start:bootstrap:.*--no-substitutes')"
pull="$(event_line '^guix:bootstrap: pull --no-substitutes ' )"
authenticated="$(event_line '^gate:authenticated-source$')"
floor="$(event_line '^gate:security-floor$')"
safe_start="$(event_line '^daemon:start:fixed-safe:.*--no-substitutes')"
ci_key="$(event_line '^gate:authorized:ci-key$')"
bordeaux_key="$(event_line '^gate:authorized:bordeaux-key$')"
enabled="$(event_line '^daemon:start:fixed:.*--substitute-urls=https://ci\.guix\.gnu\.org https://bordeaux\.guix\.gnu\.org')"
checker="$(event_line '^gate:advisory-check$')"

[ "$bootstrap_start" -lt "$pull" ] || fail "pull preceded bootstrap daemon"
[ "$pull" -lt "$authenticated" ] || fail "source authentication preceded pull"
[ "$authenticated" -lt "$floor" ] || fail "floor preceded authentication"
[ "$floor" -lt "$safe_start" ] || fail "fixed daemon started before floor"
[ "$safe_start" -lt "$ci_key" ] || fail "key authorization preceded fixed daemon"
[ "$ci_key" -lt "$bordeaux_key" ] || fail "official key order changed"
[ "$bordeaux_key" -lt "$enabled" ] || fail "substitutes enabled before authorization"
[ "$enabled" -lt "$checker" ] || fail "advisory checker preceded fixed daemon"
if head -n "$floor" "$event_log" | grep -q -- '--substitute-urls'; then
    fail "a substitute URL was enabled before the authenticated security floor"
fi
grep -q '^guix_profile=.*/run-success/current-guix$' \
    "$test_root/output-success" || fail "fixed profile output missing"
grep -q '^guix_bin=.*/run-success/current-guix/bin$' \
    "$test_root/output-success" || fail "fixed bin output missing"
grep -q '^guix_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$' \
    "$test_root/output-success" || fail "resolved commit output missing"
grep -q '^authenticated_guix_checkout=.*/run-success/guix-source$' \
    "$test_root/output-success" || fail "authenticated checkout output missing"
grep -q '^guix_security_floor=897832f374dcdc9eeaf19d01e70b9a92fccfc68c$' \
    "$test_root/output-success" || fail "security floor output missing"
[ -d "$test_root/run-success/guix-source" ] ||
    fail "authenticated checkout was not retained for the caller"

# A revision below the floor cannot start or authorize the replacement daemon.
if run_case floor-failure floor-failure; then
    fail "security-floor failure unexpectedly succeeded"
fi
event_line '^gate:security-floor$' >/dev/null
event_line '^daemon:stop:bootstrap$' >/dev/null
assert_absent '^daemon:start:fixed'
assert_absent '^gate:authorized:'
[ ! -s "$test_root/output-floor-failure" ] ||
    fail "floor failure emitted trusted outputs"

# Every non-clean checker outcome is fail-closed, including an exit-zero result
# set that omits one of the four exact advisory verdicts.
for mode in checker-vulnerable checker-error checker-inconclusive; do
    if run_case "$mode" "$mode"; then
        fail "$mode unexpectedly succeeded"
    fi
    event_line '^gate:advisory-check$' >/dev/null
    event_line '^daemon:stop:fixed$' >/dev/null
    [ ! -s "$test_root/output-$mode" ] ||
        fail "$mode emitted trusted outputs"
done

# Pinning the channel is rejected before any daemon is launched.
pinned_channels="$test_root/channels-pinned.scm"
sed '/(branch/a\        (commit "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")' \
    "$channels" > "$pinned_channels"
if run_case pinned success "$pinned_channels"; then
    fail "pinned Guix channel unexpectedly succeeded"
fi
[ ! -s "$event_log" ] || fail "pinned channel launched external commands"

printf 'secure Guix bootstrap contract: PASS\n'
