#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

template_name="${1:-guix}"

usage() {
    cat <<'EOF'
Usage: diagnose-update-proxy-dom0.sh [TEMPLATE]

Print dom0 and guest-side state relevant to the native Guix updates-proxy
forwarder.  Run this from dom0 or nested dom0.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: missing required command: %s\n' "$1" >&2
        exit 1
    }
}

need qvm-features
need qvm-prefs
need qvm-run

printf 'template: %s\n' "$template_name"
printf 'klass: %s\n' "$(qvm-prefs "$template_name" klass 2>/dev/null || true)"
printf 'template-version: %s\n' \
    "$(qvm-features "$template_name" template-version 2>/dev/null || true)"
printf 'template-release: %s\n' \
    "$(qvm-features "$template_name" template-release 2>/dev/null || true)"

qvm-run --pass-io --no-gui --user root "$template_name" "cat >/tmp/guix-updates-diag.sh <<'__GUEST_DIAG__'
#!/bin/sh
set -ux
. /usr/lib/qubes/init/functions
echo QUBESDB
qubesdb-read /qubes-vm-type || true
echo SERVICES
ls -la /run/qubes-service || true
echo COMMANDS
command -v qrexec-client-vm || true
command -v socat || true
echo QSVCS
qsvc updates-proxy-setup
echo qsvc_updates_status=\$?
qsvc qubes-updates-proxy
echo qsvc_local_status=\$?
echo LINKS
ip link show lo || true
echo SOCKETS
ss -ltnp || true
echo PROCS
ps -ef | grep -E 'socat|guix-updates|qrexec|shepherd' | grep -v grep || true
echo HERD
herd status qubes-updates-proxy-forwarder || true
herd status qubes-guix-update-proxy || true
herd status guix-daemon || true
herd status qubes-network-uplink || true
echo GUIX_PROXY_CONFIG
ls -l /run/qubes/bin/guix /etc/profile.d/qubes-guix-update-proxy.sh || true
sed -n '1,80p' /run/qubes/bin/guix 2>/dev/null || true
sed -n '1,80p' /etc/profile.d/qubes-guix-update-proxy.sh 2>/dev/null || true
pid=\$(pgrep -x guix-daemon | head -n 1 || true)
if [ -n "\$pid" ]; then
    tr '\\0' '\\n' <"/proc/\$pid/environ" | grep -E '^(http|https)_proxy=' || true
fi
echo LOG_UPDATES
cat /var/log/qubes-updates-proxy-forwarder.log || true
echo LOG_GUIX_PROXY
cat /var/log/qubes-guix-update-proxy.log || true
echo LOG_NET
cat /var/log/qubes-network-uplink.log || true
__GUEST_DIAG__
chmod +x /tmp/guix-updates-diag.sh
/tmp/guix-updates-diag.sh"
