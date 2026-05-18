#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/qubes-guix-vmupdate-check.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

fake_bin="$workdir/bin"
state_dir="$workdir/state"
mkdir -p "$fake_bin" "$state_dir"

cat >"$fake_bin/qvm-check" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$fake_bin/qvm-prefs" <<'EOF'
#!/bin/sh
if [ "${2:-}" = "klass" ]; then
    printf 'TemplateVM\n'
    exit 0
fi
exit 1
EOF

cat >"$fake_bin/qubes-prefs" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "updatevm" ]; then
    printf 'sys-net\n'
    exit 0
fi
exit 1
EOF

cat >"$fake_bin/qvm-run" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$GUIX_FAKE_STATE/qvm-run.args"
case "$*" in
    *"guest disk space"*)
        printf 'guest updater log detail\n'
        exit 0
        ;;
esac
if [ "${GUIX_FAKE_PREFLIGHT_MODE:-ok}" = "fail" ]; then
    printf 'raw proxy probe exit status: 1\n' >&2
    printf 'raw proxy probe first response line: <empty>\n' >&2
    exit 1
fi
exit 0
EOF

cat >"$fake_bin/qubes-vm-update" <<'EOF'
#!/bin/sh
set -eu
: "${GUIX_FAKE_STATE:?}"
printf '%s\n' "$@" >"$GUIX_FAKE_STATE/qubes-vm-update.args"
if [ "${GUIX_FAKE_UPDATE_MODE:-ok}" = "log-only" ]; then
    : "${QUBES_GUIX_UPDATES_LOG_DIR:?}"
    mkdir -p "$QUBES_GUIX_UPDATES_LOG_DIR"
    {
        printf 'guix:out: Refreshing Guix channel metadata from master.\n'
        printf 'guix:out: Reconfiguring Guix System from /etc/config.scm using master.\n'
        printf 'guix:out: Reconfigured Guix System.\n'
        printf 'guix:out: Updated packages:\n'
    } >"$QUBES_GUIX_UPDATES_LOG_DIR/update-guix.log"
    exit 0
fi
printf 'Refreshing Guix channel metadata from master.\n'
if [ "${GUIX_FAKE_UPDATE_MODE:-ok}" != "missing-reconfigure" ]; then
    printf 'Reconfiguring Guix System from /etc/config.scm using master.\n'
    printf 'Reconfigured Guix System.\n'
    printf 'Updated packages:\n'
fi
if [ "${GUIX_FAKE_UPDATE_MODE:-ok}" = "fail" ]; then
    printf 'fake Guix backend failure detail\n' >&2
    exit 24
fi
exit 0
EOF

chmod 0755 "$fake_bin/qvm-check" "$fake_bin/qvm-prefs" \
    "$fake_bin/qubes-prefs" "$fake_bin/qvm-run" \
    "$fake_bin/qubes-vm-update"

env PATH="$fake_bin:$PATH" GUIX_FAKE_STATE="$state_dir" \
    "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" \
    --template guix --timeout 120 \
    --proxy-probe-url https://example.invalid/guix.git \
    --log-dir "$workdir/logs-ok" \
    >"$workdir/ok.out" 2>&1

grep -Fx -- '--force-update' "$state_dir/qubes-vm-update.args" >/dev/null
grep -Fx -- '--force-upgrade' "$state_dir/qubes-vm-update.args" >/dev/null
grep -Fx -- '--show-output' "$state_dir/qubes-vm-update.args" >/dev/null
grep -Fx -- '--no-progress' "$state_dir/qubes-vm-update.args" >/dev/null
grep -Fx -- '--no-cleanup' "$state_dir/qubes-vm-update.args" >/dev/null
grep -F -- 'https://example.invalid/guix.git' \
    "$state_dir/qvm-run.args" >/dev/null
grep -F 'dom0 qubes.UpdatesProxy policy entries:' \
    "$workdir/ok.out" >/dev/null
grep -F 'dom0 standard update target sys-net: present' \
    "$workdir/ok.out" >/dev/null

env PATH="$fake_bin:$PATH" GUIX_FAKE_STATE="$state_dir" \
    GUIX_FAKE_UPDATE_MODE=log-only \
    QUBES_GUIX_UPDATES_LOG_DIR="$workdir/fake-qubes-update-logs" \
    "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" \
    --template guix --timeout 120 --log-dir "$workdir/logs-log-only" \
    >"$workdir/log-only.out" 2>&1

grep -F 'central Guix qubes-vm-update check passed: guix' \
    "$workdir/log-only.out" >/dev/null

set +e
env PATH="$fake_bin:$PATH" GUIX_FAKE_STATE="$state_dir" \
    GUIX_FAKE_UPDATE_MODE=missing-reconfigure \
    "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" \
    --template guix --timeout 120 --log-dir "$workdir/logs-missing" \
    >"$workdir/missing-reconfigure.out" 2>&1
missing_status=$?
set -e

[ "$missing_status" -ne 0 ] || {
    printf 'central vmupdate harness accepted missing reconfigure marker\n' >&2
    exit 1
}
grep -F 'did not show Guix system reconfigure' \
    "$workdir/missing-reconfigure.out" >/dev/null || {
        printf 'missing useful reconfigure-marker failure:\n' >&2
        cat "$workdir/missing-reconfigure.out" >&2
        exit 1
    }

set +e
env PATH="$fake_bin:$PATH" GUIX_FAKE_STATE="$state_dir" \
    GUIX_FAKE_PREFLIGHT_MODE=fail \
    "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" \
    --template guix --timeout 120 --log-dir "$workdir/logs-preflight" \
    >"$workdir/preflight-failure.out" 2>&1
preflight_status=$?
set -e

[ "$preflight_status" -ne 0 ] || {
    printf 'central vmupdate harness accepted failed preflight\n' >&2
    exit 1
}
grep -F 'central updater preflight failed with status 1' \
    "$workdir/preflight-failure.out" >/dev/null || {
        printf 'missing useful preflight failure:\n' >&2
        cat "$workdir/preflight-failure.out" >&2
        exit 1
    }
grep -F 'raw proxy probe exit status: 1' \
    "$workdir/preflight-failure.out" >/dev/null || {
        printf 'missing raw proxy diagnostic pass-through:\n' >&2
        cat "$workdir/preflight-failure.out" >&2
        exit 1
    }

set +e
env PATH="$fake_bin:$PATH" GUIX_FAKE_STATE="$state_dir" \
    GUIX_FAKE_UPDATE_MODE=fail \
    "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" \
    --template guix --timeout 120 --log-dir "$workdir/logs-update-fail" \
    >"$workdir/update-failure.out" 2>&1
update_failure_status=$?
set -e

[ "$update_failure_status" -ne 0 ] || {
    printf 'central vmupdate harness accepted failed updater\n' >&2
    exit 1
}
grep -F 'qubes-vm-update failed with status 24' \
    "$workdir/update-failure.out" >/dev/null || {
        printf 'missing useful update failure:\n' >&2
        cat "$workdir/update-failure.out" >&2
        exit 1
    }
grep -F 'fake Guix backend failure detail' \
    "$workdir/update-failure.out" >/dev/null || {
        printf 'missing vmupdate failure detail:\n' >&2
        cat "$workdir/update-failure.out" >&2
        exit 1
    }
if grep -F 'qubes-guix-central-vmupdate-dump-logs.sh' \
    "$state_dir/qvm-run.args" >/dev/null; then
        printf 'guest failure collector should not write a helper script\n' >&2
        cat "$state_dir/qvm-run.args" >&2
        exit 1
fi
grep -F 'guest disk space' "$state_dir/qvm-run.args" >/dev/null || {
    printf 'guest failure collector should run diagnostics inline\n' >&2
    cat "$state_dir/qvm-run.args" >&2
    exit 1
}
grep -F 'guest updater log detail' \
    "$workdir/update-failure.out" >/dev/null || {
        printf 'missing guest failure log detail:\n' >&2
        cat "$workdir/update-failure.out" >&2
        exit 1
    }

printf 'central vmupdate harness check passed\n'
