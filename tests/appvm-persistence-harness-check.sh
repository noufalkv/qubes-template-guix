#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/qubes-guix-appvm-persistence.XXXXXX")"
trap 'if [ -d "$workdir/pids" ]; then xargs -r kill <"$workdir/pids/all" 2>/dev/null || true; fi; rm -rf "$workdir"' EXIT

fake_bin="$workdir/bin"
state_dir="$workdir/state"
socket_dir="$workdir/qrexec"
mkdir -p "$fake_bin" "$state_dir/running" "$state_dir/pids" "$socket_dir"
printf 'guix-test\n' >"$state_dir/vms"
: >"$state_dir/lifecycle.log"
: >"$state_dir/qvm-run.log"
: >"$state_dir/pids/all"

write_fake() {
    local name="$1"
    shift
    cat >"$fake_bin/$name"
    chmod 0755 "$fake_bin/$name"
}

write_fake qvm-ls <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "$GUIX_FAKE_STATE/vms"
EOF

write_fake qvm-check <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
running=0
if [ "${1:-}" = "--running" ]; then
    running=1
    shift
fi
vm="${1:?missing VM}"
grep -Fxq "$vm" "$GUIX_FAKE_STATE/vms" || exit 1
if [ "$running" -eq 1 ]; then
    test -e "$GUIX_FAKE_STATE/running/$vm"
fi
EOF

write_fake qvm-create <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm="${@: -1}"
printf 'qvm-create %s\n' "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
grep -Fxq "$vm" "$GUIX_FAKE_STATE/vms" ||
    printf '%s\n' "$vm" >>"$GUIX_FAKE_STATE/vms"
EOF

write_fake qvm-prefs <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm="${1:?missing VM}"
pref="${2:-}"
case "$#" in
    1)
        printf 'name: %s\n' "$vm"
        exit 0
        ;;
    2)
        case "$pref" in
            klass)
                if [ "$vm" = "guix-test" ]; then
                    printf 'TemplateVM\n'
                else
                    printf 'AppVM\n'
                fi
                ;;
            default_user) printf 'user\n' ;;
            netvm)
                if [ -r "$GUIX_FAKE_STATE/netvm.$vm" ]; then
                    cat "$GUIX_FAKE_STATE/netvm.$vm"
                else
                    printf 'None\n'
                fi
                ;;
            provides_network) printf 'False\n' ;;
            *) printf '\n' ;;
        esac
        ;;
    *)
        printf 'qvm-prefs %s\n' "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
        if [ "$pref" = "netvm" ]; then
            printf '%s\n' "$3" >"$GUIX_FAKE_STATE/netvm.$vm"
        fi
        ;;
esac
EOF

write_fake qvm-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm="${1:?missing VM}"
sock="$QUBES_QREXEC_SOCKET_DIR/qrexec.$vm"
printf 'qvm-start %s\n' "$vm" >>"$GUIX_FAKE_STATE/lifecycle.log"
touch "$GUIX_FAKE_STATE/running/$vm"
if [ ! -S "$sock" ]; then
    rm -f "$sock"
    python3 - "$sock" <<'PY' &
import os
import signal
import socket
import sys
import time

sock_path = sys.argv[1]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX)
server.bind(sock_path)
server.listen(1)

def stop(_signum, _frame):
    try:
        server.close()
    finally:
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        sys.exit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

while True:
    time.sleep(60)
PY
    pid=$!
    printf '%s\n' "$pid" >"$GUIX_FAKE_STATE/pids/$vm"
    printf '%s\n' "$pid" >>"$GUIX_FAKE_STATE/pids/all"
fi
EOF

write_fake qvm-shutdown <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm="${@: -1}"
printf 'qvm-shutdown %s\n' "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
rm -f "$GUIX_FAKE_STATE/running/$vm"
if [ -r "$GUIX_FAKE_STATE/pids/$vm" ]; then
    kill "$(cat "$GUIX_FAKE_STATE/pids/$vm")" 2>/dev/null || true
    rm -f "$GUIX_FAKE_STATE/pids/$vm"
fi
rm -f "$QUBES_QREXEC_SOCKET_DIR/qrexec.$vm"
EOF

write_fake qvm-kill <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm="${@: -1}"
printf 'qvm-kill %s\n' "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
rm -f "$GUIX_FAKE_STATE/running/$vm" "$QUBES_QREXEC_SOCKET_DIR/qrexec.$vm"
EOF

write_fake qvm-remove <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm="${@: -1}"
printf 'qvm-remove %s\n' "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
grep -Fxv "$vm" "$GUIX_FAKE_STATE/vms" >"$GUIX_FAKE_STATE/vms.new" || true
mv "$GUIX_FAKE_STATE/vms.new" "$GUIX_FAKE_STATE/vms"
EOF

write_fake qvm-run <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vm=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            shift 2
            ;;
        --*)
            shift
            ;;
        *)
            vm="$1"
            shift
            break
            ;;
    esac
done
printf 'VM=%s CMD=%s\n' "$vm" "$*" >>"$GUIX_FAKE_STATE/qvm-run.log"
printf 'qvm-run VM=%s CMD=%s\n' "$vm" "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
EOF

write_fake qrexec-client <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'qrexec-client %s\n' "$*" >>"$GUIX_FAKE_STATE/lifecycle.log"
cat >/dev/null || true
EOF

env PATH="$fake_bin:$PATH" \
    GUIX_FAKE_STATE="$state_dir" \
    QUBES_QREXEC_SOCKET_DIR="$socket_dir" \
    "$repo_root/scripts/test-native-guix-template-dom0.sh" \
    --template guix-test --appvm guix-test-app \
    >"$workdir/smoke.out" 2>"$workdir/smoke.err"

line_of() {
    local pattern="$1"
    local file="$2"
    local line

    line="$(grep -nF "$pattern" "$file" | head -n1 | cut -d: -f1 || true)"
    printf '%s\n' "${line:-0}"
}

nth_line_of() {
    local pattern="$1"
    local file="$2"
    local ordinal="$3"
    local line

    line="$(awk -v pattern="$pattern" -v ordinal="$ordinal" '
        index($0, pattern) {
            count++;
            if (count == ordinal) {
                print NR;
                exit;
            }
        }
    ' "$file")"
    printf '%s\n' "${line:-0}"
}

assert_line_order() {
    local before="$1"
    local after="$2"
    [ "$before" -gt 0 ] && [ "$after" -gt 0 ] && [ "$before" -lt "$after" ] || {
        printf 'unexpected lifecycle order: %s before %s\n' "$before" "$after" >&2
        printf '%s\n' '--- lifecycle ---' >&2
        cat "$state_dir/lifecycle.log" >&2
        printf '%s\n' '--- qvm-run ---' >&2
        cat "$state_dir/qvm-run.log" >&2
        exit 1
    }
}

app_start_1="$(line_of 'qvm-start guix-test-app' "$state_dir/lifecycle.log")"
app_shutdown="$(line_of 'qvm-shutdown --wait guix-test-app' "$state_dir/lifecycle.log")"
app_start_2="$(awk '/qvm-start guix-test-app/ { count++; if (count == 2) { print NR; exit } }' "$state_dir/lifecycle.log")"
[ -n "$app_start_2" ] || app_start_2=0
assert_line_order "$app_start_1" "$app_shutdown"
assert_line_order "$app_shutdown" "$app_start_2"

home_write="$(line_of 'test_path="$HOME/.guix-native-template-test"' "$state_dir/lifecycle.log")"
home_read="$(line_of 'cat "$HOME/.guix-native-template-test"' "$state_dir/lifecycle.log")"
rw_write="$(line_of 'guix-rw > /rw/.guix-native-template-rw-test' "$state_dir/lifecycle.log")"
rw_read="$(line_of 'cat /rw/.guix-native-template-rw-test' "$state_dir/lifecycle.log")"
usrlocal_write="$(line_of 'guix-usrlocal > /usr/local/share/.guix-native-template-usrlocal-test' "$state_dir/lifecycle.log")"
usrlocal_read="$(line_of 'cat /usr/local/share/.guix-native-template-usrlocal-test' "$state_dir/lifecycle.log")"
volatile_write="$(line_of 'touch /var/guix/.qubes-appvm-volatile-test' "$state_dir/lifecycle.log")"
volatile_absent="$(line_of 'test ! -e /var/guix/.qubes-appvm-volatile-test' "$state_dir/lifecycle.log")"
wait_session_1="$(nth_line_of 'QUBESRPC qubes.WaitForSession dom0' "$state_dir/lifecycle.log" 1)"
wait_session_2="$(nth_line_of 'QUBESRPC qubes.WaitForSession dom0' "$state_dir/lifecycle.log" 2)"

assert_line_order "$app_start_1" "$home_write"
assert_line_order "$app_start_1" "$wait_session_1"
assert_line_order "$wait_session_1" "$home_write"
assert_line_order "$home_write" "$app_shutdown"
assert_line_order "$app_start_1" "$rw_write"
assert_line_order "$rw_write" "$app_shutdown"
assert_line_order "$app_start_1" "$usrlocal_write"
assert_line_order "$usrlocal_write" "$app_shutdown"
assert_line_order "$app_start_1" "$volatile_write"
assert_line_order "$volatile_write" "$app_shutdown"
assert_line_order "$app_start_2" "$home_read"
assert_line_order "$app_start_2" "$rw_read"
assert_line_order "$app_start_2" "$usrlocal_read"
assert_line_order "$app_start_2" "$volatile_absent"
assert_line_order "$app_start_2" "$wait_session_2"
assert_line_order "$volatile_absent" "$wait_session_2"

grep -F '/rw/.guix-native-template-rw-test' "$state_dir/qvm-run.log" >/dev/null
grep -F '/usr/local/share/.guix-native-template-usrlocal-test' "$state_dir/qvm-run.log" >/dev/null
grep -F '/var/guix/.qubes-appvm-volatile-test' "$state_dir/qvm-run.log" >/dev/null
grep -F 'private' "$state_dir/qvm-run.log" >/dev/null
grep -F 'test ! -L /etc/fstab' "$state_dir/qvm-run.log" >/dev/null
grep -F '$2 == "/rw"' "$state_dir/qvm-run.log" >/dev/null
! grep -F '^[^#][[:space:]]*/rw[[:space:]]' "$state_dir/qvm-run.log" >/dev/null
grep -F '/usr/lib/qubes-bind-dirs.d' "$state_dir/qvm-run.log" >/dev/null
grep -F '/etc/qubes-rpc/qubes.WaitForSession' "$state_dir/qvm-run.log" >/dev/null
grep -F 'test_path="$HOME/.guix-native-template-test"' "$state_dir/qvm-run.log" >/dev/null
grep -F 'cat "$HOME/.guix-native-template-test"' "$state_dir/qvm-run.log" >/dev/null
grep -F 'cat /rw/.guix-native-template-rw-test' "$state_dir/qvm-run.log" >/dev/null
grep -F 'cat /usr/local/share/.guix-native-template-usrlocal-test' "$state_dir/qvm-run.log" >/dev/null
grep -F 'test ! -e /var/guix/.qubes-appvm-volatile-test' "$state_dir/qvm-run.log" >/dev/null
grep -F 'after restart' "$state_dir/qvm-run.log" >/dev/null

printf 'AppVM persistence harness check passed\n'
