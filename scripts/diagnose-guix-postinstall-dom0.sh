#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

template="${1:-guix}"

PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
TERM="${TERM:-xterm}"
export PATH TERM

log() {
    printf '%s\n' "$*"
}

run() {
    log "POSTINSTALL_CMD $*"
    "$@"
    local status=$?
    log "POSTINSTALL_STATUS $status $*"
    return "$status"
}

debugfs_cat() {
    local root_path="$1"
    local log_path="$2"

    log "POSTINSTALL_DEBUGFS_LOG $log_path"
    debugfs -R "cat $log_path" "$root_path" 2>/dev/null | tail -240 || true
}

debugfs_cmd() {
    local root_path="$1"
    local command="$2"

    log "POSTINSTALL_DEBUGFS_CMD $command"
    debugfs -R "$command" "$root_path" 2>&1 | sed -n '1,160p' || true
}

root_volume_path() {
    qvm-volume info "$template:root" 2>/dev/null |
        awk '
            {
                if (index($0, ":") > 0) {
                    key = $1
                    sub(/:.*/, "", key)
                    value = $0
                    sub(/^[^:]*:[[:space:]]*/, "", value)
                } else {
                    key = $1
                    value = $0
                    sub(/^[^[:space:]]+[[:space:]]*/, "", value)
                }
                sub(/^[[:space:]]+/, "", key)
                sub(/[[:space:]]+$/, "", key)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
            }
            key == "path" {
                path = value
            }
            key == "pool" {
                pool = value
            }
            key == "vid" {
                vid = value
            }
            END {
                if (path != "") {
                    print path
                } else if (pool == "varlibqubes" && vid != "") {
                    print "/var/lib/qubes/" vid ".img"
                }
            }'
}

log "POSTINSTALL_DOM0_DIAG_BEGIN"

run qvm-ls --fields NAME,STATE,CLASS,TEMPLATE,KERNEL,VIRT_MODE,NETVM "$template" || true
run qvm-prefs "$template" || true
run qvm-features "$template" || true

for log_path in \
    "/var/log/xen/console/guest-$template.log" \
    "/var/log/qubes/qrexec.$template.log" \
    "/var/log/qubes/qubesdb.$template.log"
do
    [ -e "$log_path" ] || continue
    log "POSTINSTALL_DOM0_LOG $log_path"
    tail -240 "$log_path" || true
done

log "POSTINSTALL_QVM_START_BEGIN"
timeout 180 qvm-start "$template"
start_status=$?
log "POSTINSTALL_QVM_START_STATUS $start_status"
sleep 5

guest_diag='
set +e +u
exec 2>&1
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin${PATH:+:$PATH}
echo POSTINSTALL_DIAG_BEGIN
id
printf "vm-type=%s\n" "$(qubesdb-read /qubes-vm-type 2>&1)"
printf "persistence=%s\n" "$(qubesdb-read /qubes-vm-persistence 2>&1)"
printf "updateable=%s\n" "$(qubesdb-read /qubes-vm-updateable 2>&1)"
printf "default-user=%s\n" "$(qubesdb-read /default-user 2>&1)"
printf "path=%s\n" "$PATH"
ls -ld /etc/qubes /etc/qubes/post-install.d /etc/qubes-rpc /usr/lib/qubes 2>&1
for script in /etc/qubes/post-install.d/*.sh; do
    [ -e "$script" ] || continue
    echo POSTINSTALL_SCRIPT_BEGIN "$script"
    "$script"
    status=$?
    echo POSTINSTALL_SCRIPT_STATUS "$status" "$script"
done
echo POSTINSTALL_GUEST_LOGS_BEGIN
for log in /var/log/qubes-db.log /var/log/qubes-sysinit.log /var/log/qubes-mount-dirs.log /var/log/qubes-bind-dirs.log /var/log/qubes-misc-post.log /var/log/qubes-postinstall.log /var/log/qubes-qrexec-agent.log /var/log/qubes-qrexec-fork-server.log /var/log/qubes-gui-agent.log /var/log/shepherd.log; do
    [ -e "$log" ] || continue
    echo POSTINSTALL_GUEST_LOG "$log"
    tail -240 "$log"
done
echo POSTINSTALL_DIAG_END
'

log "POSTINSTALL_QVM_RUN_BEGIN"
timeout 120 qvm-run --no-gui --pass-io --user root "$template" "$guest_diag"
run_status=$?
log "POSTINSTALL_QVM_RUN_STATUS $run_status"

qvm-shutdown --wait "$template" >/dev/null 2>&1 ||
    qvm-kill "$template" >/dev/null 2>&1 ||
    true

log "POSTINSTALL_GUEST_ROOT_LOGS_BEGIN"
log "POSTINSTALL_QVM_VOLUME_INFO_BEGIN"
qvm-volume info "$template:root" || true
log "POSTINSTALL_QVM_VOLUME_INFO_END"
root_path="$(root_volume_path)"

if [ -n "$root_path" ] && command -v debugfs >/dev/null 2>&1; then
    for command in \
        "stat /etc" \
        "stat /etc/qubes" \
        "ls -l /etc/qubes" \
        "stat /etc/qubes/rpc-config" \
        "ls -l /etc/qubes/rpc-config" \
        "cat /etc/qubes/rpc-config/qubes.PostInstall" \
        "stat /etc/qubes-rpc" \
        "ls -l /etc/qubes-rpc" \
        "stat /etc/qubes-rpc/qubes.PostInstall" \
        "cat /etc/qubes-rpc/qubes.PostInstall" \
        "stat /etc/qubes-rpc/qubes.VMShell" \
        "cat /etc/qubes-rpc/qubes.VMShell" \
        "stat /etc/pam.d" \
        "ls -l /etc/pam.d" \
        "cat /etc/pam.d/qrexec" \
        "stat /bin/sh" \
        "stat /bin/bash" \
        "stat /run/current-system/profile/bin/sh" \
        "stat /run/current-system/profile/bin/bash" \
        "stat /run/current-system/profile/bin/logger"
    do
        debugfs_cmd "$root_path" "$command"
    done

    for log_path in \
        /var/log/qubes-db.log \
        /var/log/qubes-sysinit.log \
        /var/log/qubes-mount-dirs.log \
        /var/log/qubes-bind-dirs.log \
        /var/log/qubes-misc-post.log \
        /var/log/qubes-postinstall.log \
        /var/log/qubes-qrexec-agent.log \
        /var/log/qubes-qrexec-fork-server.log \
        /var/log/qubes-gui-agent.log \
        /var/log/shepherd.log \
        /var/log/messages
    do
        debugfs_cat "$root_path" "$log_path"
    done
elif [ -z "$root_path" ]; then
    log "POSTINSTALL_NO_ROOT_VOLUME_PATH"
else
    log "POSTINSTALL_NO_DEBUGFS"
fi

log "POSTINSTALL_DOM0_DIAG_END"
