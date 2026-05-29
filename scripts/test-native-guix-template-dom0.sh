#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template_name="guix"
template_variant=""
appvm_name="guix-test-app"
appvm_netvm="${QUBES_GUIX_APPVM_NETVM:-}"
qrexec_socket_dir="${QUBES_QREXEC_SOCKET_DIR:-/var/run/qubes}"
keep_appvm=0
appvm_created=0
dom0_test_user="${QUBES_DOM0_TEST_USER:-user}"
dom0_test_home=""
diagnostics_enabled=0
kernel=""
expected_commands=()
expected_desktops=()

usage() {
    cat <<'EOF'
Usage: test-native-guix-template-dom0.sh [options]

Runs dom0-side smoke tests against a native GNU Guix System TemplateVM.

Options:
  --template NAME       TemplateVM to test. Default: guix
  --variant NAME        Template variant: normal or minimal. Default: infer
                        from the template name.
  --appvm NAME          Temporary AppVM name. Default: guix-test-app
  --appvm-netvm NAME    Attach the temporary AppVM to this NetVM for uplink
                        checks. Default: keep dom0's default netvm behavior.
  --keep-appvm          Do not remove the temporary AppVM after tests.
  -h, --help            Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

resolve_variant() {
    if [ -n "$template_variant" ]; then
        "$repo_root/scripts/template-variant.sh" "$template_variant" variant
        return
    fi

    case "$template_name" in
        minimal|guix-minimal|*minimal*) printf '%s\n' minimal ;;
        *) printf '%s\n' normal ;;
    esac
}

load_variant_expectations() {
    template_variant="$(resolve_variant)"
    mapfile -t expected_commands < \
        <("$repo_root/scripts/template-variant.sh" "$template_variant" commands)
    mapfile -t expected_desktops < \
        <("$repo_root/scripts/template-appmenus.sh" "$template_variant")

    [ "${#expected_commands[@]}" -gt 0 ] ||
        die "empty command expectation list for variant: $template_variant"
    [ "${#expected_desktops[@]}" -gt 0 ] ||
        die "empty appmenu expectation list for variant: $template_variant"
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_as_dom0_user() {
    if [ "$(id -un)" = "$dom0_test_user" ]; then
        "$@"
    else
        run_as_root runuser -u "$dom0_test_user" -- "$@"
    fi
}

vm_exists() {
    qvm-ls --raw-list 2>/dev/null | grep -Fxq "$1"
}

ensure_qubesd_available() {
    local attempt
    local stable=0

    for attempt in $(seq 1 60); do
        if qvm-ls --raw-list >/dev/null 2>&1; then
            stable=$((stable + 1))
            if [ "$stable" -ge 2 ]; then
                return 0
            fi
            sleep 1
            continue
        fi
        stable=0

        if [ "$attempt" -eq 1 ]; then
            printf 'Qubes local daemon is not reachable; starting qubesd\n' >&2
            if command -v systemctl >/dev/null 2>&1; then
                systemctl status qubesd --no-pager -l >&2 || true
                run_as_root systemctl start qubesd >&2 || true
            fi
        fi

        sleep 2
    done

    printf 'Qubes local daemon did not become reachable\n' >&2
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status qubesd --no-pager -l >&2 || true
    fi
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u qubesd -n 200 --no-pager >&2 || true
    fi
    return 1
}

ensure_qvm_start_daemon() {
    local display
    local display_number
    local xauthority=""
    local candidate
    local log_file="/tmp/qubes-guix-qvm-start-daemon.log"
    local pid_file="/tmp/qubes-guix-qvm-start-daemon.pid"

    command -v qvm-start-daemon >/dev/null 2>&1 || return 0
    pgrep -f 'qvm-start-daemon .*--watch' >/dev/null 2>&1 && return 0

    display="${QUBES_DOM0_DISPLAY:-${DISPLAY:-:0}}"
    display_number="${display#*:}"
    display_number="${display_number%%.*}"
    case "$display_number" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ -S "/tmp/.X11-unix/X$display_number" ] || return 0

    if [ -n "${QUBES_DOM0_XAUTHORITY:-}" ]; then
        xauthority="$QUBES_DOM0_XAUTHORITY"
    else
        for candidate in \
            "/home/$dom0_test_user/.Xauthority" \
            "/run/user/$(id -u "$dom0_test_user" 2>/dev/null || printf 0)/gdm/Xauthority" \
            "/run/lightdm/root/:$display_number" \
            "/var/run/lightdm/root/:$display_number"
        do
            if run_as_root test -r "$candidate"; then
                xauthority="$candidate"
                break
            fi
        done
    fi
    [ -n "$xauthority" ] || {
        printf 'warning: no readable Xauthority found for DISPLAY=%s; GUI watcher not started\n' \
            "$display" >&2
        return 0
    }
    if ! run_as_root test -r "$xauthority"; then
        printf 'warning: Xauthority is not readable: %s; GUI watcher not started\n' \
            "$xauthority" >&2
        return 0
    fi

    printf 'Starting qvm-start-daemon watcher for nested dom0 GUI tests on DISPLAY=%s\n' \
        "$display"
    run_as_root rm -f "$pid_file"
    if id "$dom0_test_user" >/dev/null 2>&1 &&
        run_as_root runuser -u "$dom0_test_user" -- test -r "$xauthority"; then
        local uid
        local gid
        local runtime_dir

        uid="$(id -u "$dom0_test_user")"
        gid="$(id -g "$dom0_test_user")"
        runtime_dir="/run/user/$uid"
        run_as_root install -d -m 0700 -o "$uid" -g "$gid" "$runtime_dir"
        run_as_root runuser -u "$dom0_test_user" -- \
            env \
                DISPLAY="$display" \
                XAUTHORITY="$xauthority" \
                XDG_RUNTIME_DIR="$runtime_dir" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
                qvm-start-daemon --all --watch --force --pidfile "$pid_file" \
                >"$log_file" 2>&1 &
    else
        run_as_root env \
            DISPLAY="$display" \
            XAUTHORITY="$xauthority" \
            qvm-start-daemon --all --watch --force --pidfile "$pid_file" \
            >"$log_file" 2>&1 &
    fi

    sleep 3
    if ! pgrep -f 'qvm-start-daemon .*--watch' >/dev/null 2>&1; then
        printf 'warning: qvm-start-daemon watcher did not stay running\n' >&2
        read_root_file "$log_file" >&2 || true
    fi
}

resolve_kernel() {
    if [ -n "${QUBES_TEMPLATE_KERNEL:-}" ]; then
        printf '%s\n' "$QUBES_TEMPLATE_KERNEL"
        return
    fi
    if command -v qubes-prefs >/dev/null 2>&1; then
        local kernel
        kernel="$(qubes-prefs default_kernel 2>/dev/null || true)"
        if [ -n "$kernel" ]; then
            printf '%s\n' "$kernel"
            return
        fi
    fi
    printf 'default\n'
}

wait_for_qrexec() {
    local vm="$1"
    local socket="$qrexec_socket_dir/qrexec.$vm"
    local attempt
    for attempt in $(seq 1 90); do
        if qvm-check --running "$vm" >/dev/null 2>&1 && [ -S "$socket" ]; then
            return 0
        fi
        printf 'waiting for qrexec in %s (%s/90)\n' "$vm" "$attempt"
        sleep 2
    done
    collect_vm_diagnostics "$vm"
    return 1
}

start_vm_or_die() {
    local vm="$1"

    if qvm-start "$vm" >/dev/null; then
        return 0
    fi

    collect_vm_diagnostics "$vm"
    die "failed to start VM: $vm"
}

shutdown_vm_or_die() {
    local vm="$1"
    local attempt

    for attempt in $(seq 1 3); do
        if ! qvm-check --running "$vm" >/dev/null 2>&1; then
            return 0
        fi
        if qvm-shutdown --wait "$vm"; then
            return 0
        fi
        if ! qvm-check --running "$vm" >/dev/null 2>&1; then
            return 0
        fi
        printf 'qvm-shutdown failed for %s; retrying (%s/3)\n' \
            "$vm" "$attempt" >&2
        sleep 5
    done

    collect_vm_diagnostics "$vm"
    die "failed to shut down $vm"
}

stop_stale_vm_or_die() {
    local vm="$1"

    if ! qvm-check --running "$vm" >/dev/null 2>&1; then
        return 0
    fi

    printf 'Stopping stale running VM before smoke test: %s\n' "$vm"
    qvm-shutdown --wait "$vm" >/dev/null 2>&1 ||
        qvm-kill "$vm" >/dev/null 2>&1 ||
        true

    if qvm-check --running "$vm" >/dev/null 2>&1; then
        collect_vm_diagnostics "$vm"
        die "failed to stop stale running VM: $vm"
    fi
}

read_root_file() {
    local path="$1"

    if [ ! -e "$path" ]; then
        return
    fi
    if [ "$(id -u)" -eq 0 ]; then
        tail -240 "$path" || true
    elif command -v sudo >/dev/null 2>&1; then
        sudo tail -240 "$path" || true
    else
        tail -240 "$path" || true
    fi
}

collect_dom0_hypervisor_diagnostics() {
    local vm="${1:-}"
    local log

    printf 'Collecting dom0 hypervisor diagnostics' >&2
    if [ -n "$vm" ]; then
        printf ' for VM: %s' "$vm" >&2
    fi
    printf '\n' >&2

    free -h >&2 || true
    df -hT / /var/lib/qubes /var/tmp /tmp >&2 || true
    qvm-ls --fields NAME,STATE,CLASS,TEMPLATE,KERNEL,VIRT_MODE,MEM >&2 || true

    if [ -n "$vm" ] && vm_exists "$vm"; then
        printf -- '-- qvm-prefs %s --\n' "$vm" >&2
        qvm-prefs "$vm" >&2 || true
        printf -- '-- qvm-volume info %s:* --\n' "$vm" >&2
        qvm-volume info "$vm:root" >&2 || true
        qvm-volume info "$vm:private" >&2 || true
        qvm-volume info "$vm:volatile" >&2 || true
    fi

    if command -v xl >/dev/null 2>&1; then
        printf -- '-- xl info --\n' >&2
        xl info >&2 || true
        printf -- '-- xl list --\n' >&2
        xl list >&2 || true
        printf -- '-- xl dmesg --\n' >&2
        xl dmesg 2>&1 | tail -500 >&2 || true
    fi
    if command -v virsh >/dev/null 2>&1; then
        printf -- '-- virsh xen domains --\n' >&2
        virsh -c xen:/// list --all >&2 || true
    fi
    if command -v journalctl >/dev/null 2>&1; then
        printf -- '-- dom0 virtualization journal --\n' >&2
        journalctl -b \
            -u qubesd \
            -u virtxend \
            -u libvirtd \
            -u virtqemud \
            -u xenstored \
            -u xenconsoled \
            -n 500 --no-pager >&2 || true
    fi

    for log in /var/log/xen/*.log /var/log/libvirt/libxl/*.log; do
        [ -e "$log" ] || continue
        printf -- '-- %s --\n' "$log" >&2
        read_root_file "$log" >&2
    done
}

volume_info_field() {
    local key="$1"
    awk -v key="$key" '
        $1 == key {
            sub("^[^:[:space:]]+[[:space:]:]*", "", $0)
            print
            exit
        }'
}

resolve_vm_root_volume_path() {
    local vm="$1"
    local info
    local path
    local pool
    local vid
    local pool_info
    local driver
    local dir_path
    local candidate

    info="$(qvm-volume info "$vm:root" 2>/dev/null || true)"
    path="$(printf '%s\n' "$info" | volume_info_field path)"
    if [ -n "$path" ] && [ -e "$path" ]; then
        printf '%s\n' "$path"
        return 0
    fi

    pool="$(printf '%s\n' "$info" | volume_info_field pool)"
    vid="$(printf '%s\n' "$info" | volume_info_field vid)"
    [ -n "$pool" ] && [ -n "$vid" ] || return 1

    pool_info="$(qvm-pool info "$pool" 2>/dev/null || true)"
    driver="$(printf '%s\n' "$pool_info" | volume_info_field driver)"
    dir_path="$(printf '%s\n' "$pool_info" | volume_info_field dir_path)"

    case "$driver" in
        file|file-reflink) ;;
        *) return 1 ;;
    esac
    [ -n "$dir_path" ] || return 1

    for candidate in "$dir_path/$vid.img" "$dir_path/$vid"; do
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

run_qubes_cmd() {
    local attempt
    local diag_vm
    local status
    local output

    for attempt in $(seq 1 5); do
        ensure_qubesd_available || true
        set +e
        output="$("$@" 2>&1)"
        status=$?
        set -e

        if [ -n "$output" ]; then
            printf '%s\n' "$output"
        fi
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        if ! printf '%s\n' "$output" | grep -q 'Failed connect to local daemon'; then
            diag_vm="$(infer_qvm_run_target "$@")"
            if [ -n "$diag_vm" ]; then
                printf 'Qubes command failed with status %s: %q\n' \
                    "$status" "$1" >&2
                collect_vm_diagnostics "$diag_vm"
            fi
            return "$status"
        fi

        printf 'Qubes local daemon disconnected during %q; retrying (%s/5)\n' \
            "$1" "$attempt" >&2
        sleep 3
    done

    return "$status"
}

run_vm_cmd() {
    local vm="$1"
    shift

    run_qubes_cmd qvm-run --no-gui --pass-io "$vm" "$@"
}

run_vm_root_cmd() {
    local vm="$1"
    shift

    run_qubes_cmd qvm-run --no-gui --pass-io --user root "$vm" "$@"
}

infer_qvm_run_target() {
    [ "${1:-}" = qvm-run ] || return 0
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user|--service|--dispvm)
                [ "$#" -ge 2 ] || return 0
                shift 2
                ;;
            --*)
                shift
                ;;
            *)
                printf '%s\n' "$1"
                return 0
                ;;
        esac
    done
}

debugfs_cat() {
    local image="$1"
    local path="$2"

    printf -- '-- guest root %s --\n' "$path" >&2
    debugfs -R "cat $path" "$image" 2>/dev/null | tail -240 >&2 || true
}

collect_vm_root_diagnostics() {
    local vm="$1"
    local root_path
    local log

    command -v debugfs >/dev/null 2>&1 || return
    root_path="$(resolve_vm_root_volume_path "$vm")" || return

    printf 'Collecting guest root diagnostics from %s\n' "$root_path" >&2
    qvm-volume info "$vm:root" >&2 || true
    for log in \
        /var/log/qubes-db.log \
        /var/log/qubes-sysinit.log \
        /var/log/qubes-mount-dirs.log \
        /var/log/qubes-bind-dirs.log \
        /var/log/qubes-misc-post.log \
        /var/log/qubes-qrexec-agent.log \
        /var/log/qubes-qrexec-fork-server.log \
        /var/log/qubes-gui-agent.log \
        /var/log/qubes-network-sysctl.log \
        /var/log/qubes-network-uplink.log \
        /var/log/qubes-network.log \
        /var/log/qubes-feature-advertisement.log \
        /var/log/qubes-acpid.log \
        /var/log/shepherd.log \
        /var/log/messages
    do
        debugfs_cat "$root_path" "$log"
    done
}

vm_provides_network() {
    local value

    value="$(qvm-prefs "$1" provides_network 2>/dev/null || true)"
    case "$value" in
        1|[Tt]rue|yes|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

guest_runtime_diagnostics() {
    cat <<'EOF'
set +e
echo "== qrexec runtime =="
id
ps -efww | grep -E "qrexec|qubes|shepherd" | grep -v grep
ls -la /run/qubes /var/run/qubes 2>/dev/null
echo "== guest logs =="
for log in \
    /var/log/qubes-qrexec-agent.log \
    /var/log/qubes-qrexec-fork-server.log \
    /var/log/qubes-gui-agent.log \
    /var/log/Xorg.0.log \
    /home/user/.xsession-errors \
    /home/user/.xorg-errors \
    /tmp/qubes-guix-*.log \
    /var/log/shepherd.log
do
    [ -e "$log" ] || continue
    echo "-- $log --"
    tail -240 "$log"
done
EOF
}

guest_netvm_diagnostics() {
    cat <<'EOF'
set +e
echo "== NetVM service state =="
herd status qubes-network qubes-network-uplink qubes-network-sysctl 2>&1
echo "== NetVM qubesdb =="
for key in \
    /qubes-netvm-network \
    /qubes-netvm-gateway \
    /qubes-netvm-gateway6 \
    /qubes-netvm-primary-dns \
    /qubes-netvm-secondary-dns \
    /qubes-service/qubes-network \
    /qubes-service/qubes-updates-proxy
do
    printf "%s=" "$key"
    qubesdb-read "$key" 2>/dev/null || true
    printf "\n"
done
echo "== NetVM modules =="
lsmod | grep -E "xen.*net|netback|netfront" || true
modprobe -v xen-netback 2>&1 || modprobe -v netbk 2>&1 || true
echo "== NetVM hotplug tools =="
command -v xenstore-read xenstore-write nft conntrack ip modprobe qubesdb-read || true
find /etc/xen/scripts /run/current-system/profile/etc/xen/scripts \
    -maxdepth 1 -type f -printf "%p\n" 2>/dev/null | sort
for path in \
    /etc/xen/scripts/vif-route-qubes \
    /etc/xen/scripts/vif-common.sh \
    /etc/xen/scripts/xen-hotplug-common.sh \
    /etc/xen/scripts/hotplugpath.sh
do
    if [ -e "$path" ]; then
        ls -l "$path"
    else
        echo "missing $path"
    fi
done
echo "== NetVM logs =="
for log in \
    /var/log/qubes-network.log \
    /var/log/qubes-network-uplink.log \
    /var/log/qubes-network-sysctl.log \
    /var/log/qubes-feature-advertisement.log \
    /var/log/shepherd.log
do
    [ -e "$log" ] || continue
    echo "-- $log --"
    tail -240 "$log"
done
EOF
}

collect_vm_diagnostics() {
    local vm="$1"
    local log

    printf 'Collecting dom0 diagnostics for VM: %s\n' "$vm" >&2
    qvm-ls --fields NAME,STATE,CLASS,TEMPLATE,KERNEL,VIRT_MODE "$vm" >&2 || true
    qvm-prefs "$vm" >&2 || true
    if command -v xl >/dev/null 2>&1; then
        xl list >&2 || true
    fi
    ls -l "$qrexec_socket_dir/qrexec.$vm" "/var/run/qubes/qubesdb.$vm" >&2 || true
    qvm-volume info "$vm:root" >&2 || true
    qvm-volume info "$vm:private" >&2 || true
    qvm-volume info "$vm:volatile" >&2 || true

    for log in \
        "/var/log/xen/console/guest-$vm.log" \
        "/var/log/qubes/qrexec.$vm.log" \
        "/var/log/qubes/qubesdb.$vm.log"
    do
        if [ -e "$log" ]; then
            printf -- '-- %s --\n' "$log" >&2
            read_root_file "$log" >&2
        fi
    done
    if qvm-check --running "$vm" >/dev/null 2>&1; then
        timeout 30 qvm-run --no-gui --pass-io --user root "$vm" \
            "$(guest_runtime_diagnostics)" \
            >&2 || true
        if vm_provides_network "$vm"; then
            timeout 45 qvm-run --no-gui --pass-io --user root "$vm" \
                "$(guest_netvm_diagnostics)" >&2 || true
        fi
    else
        printf 'Skipping guest qrexec diagnostics: %s is not running\n' "$vm" >&2
    fi
    collect_dom0_hypervisor_diagnostics "$vm"
    collect_vm_root_diagnostics "$vm"
}

check_wait_for_session_rpc() {
    local vm="$1"
    local vm_user

    need qrexec-client
    vm_user="$(qvm-prefs "$vm" default_user 2>/dev/null || true)"
    [ -n "$vm_user" ] || vm_user="user"

    printf 'Testing qubes.WaitForSession qrexec service as %s in %s\n' \
        "$vm_user" "$vm"
    if ! printf '%s' "$vm_user" |
        timeout 90 qrexec-client -d "$vm" \
            "$vm_user:QUBESRPC qubes.WaitForSession dom0"; then
        collect_vm_diagnostics "$vm"
        die "qubes.WaitForSession did not complete for $vm"
    fi
}

guest_command_checks() {
    local command_name

    for command_name in "${expected_commands[@]}"; do
        printf 'command -v %q >/dev/null\n' "$command_name"
    done
}

guest_desktop_checks() {
    local desktop_file

    for desktop_file in "${expected_desktops[@]}"; do
        printf 'desktop=/usr/share/applications/%q\n' "$desktop_file"
        printf 'test -f "$desktop"\n'
        printf 'grep -Eq "^Icon=.+" "$desktop"\n'
    done
}

guest_tls_checks() {
    printf 'test -s /etc/ssl/certs/ca-certificates.crt\n'
}

guest_profile_checks() {
    guest_command_checks
    guest_desktop_checks
    guest_tls_checks
}

guest_template_boot_checks() {
    {
        cat <<'EOF'
set -e
qubesdb-read /name
/usr/bin/qubesdb-read /qubes-vm-type
test -x /usr/bin/python3
test -x /sbin/blockdev
test -x /sbin/poweroff
EOF
        guest_profile_checks
    }
}

guest_qrexec_agent_checks() {
    cat <<'EOF'
set -e
test -e /usr/lib/qubes/qrexec-agent ||
    test -e /run/current-system/profile/lib/qubes/qrexec-agent
EOF
}

guest_qubes_path_checks() {
    cat <<'EOF'
test -f /etc/fstab
test ! -L /etc/fstab
test -L /usr/lib/qubes
test -L /usr/lib/qubes-bind-dirs.d
test -d /etc/qubes-rpc
test ! -L /etc/qubes-rpc
	test -d /etc/qubes/post-install.d
	test ! -L /etc/qubes/post-install.d
	test -r /etc/qubes-guix-channel/.guix-channel
	test -r /etc/qubes-guix-channel/modules/qubes/packages.scm
	test -x /etc/qubes-rpc/qubes.WaitForSession
test -x /etc/qubes-rpc/qubes.VMShell
EOF
}

guest_template_writable_path_checks() {
    {
        printf 'set -eux\n'
        guest_qubes_path_checks
        cat <<'EOF'
printf "#!/bin/sh\nexit 0\n" > /etc/qubes-rpc/test.GuixWritable
chmod 755 /etc/qubes-rpc/test.GuixWritable
test -x /etc/qubes-rpc/test.GuixWritable
printf "#!/bin/sh\nexit 0\n" > /etc/qubes/post-install.d/50-test.sh
chmod 755 /etc/qubes/post-install.d/50-test.sh
test -x /etc/qubes/post-install.d/50-test.sh
EOF
    }
}

guest_appvm_qubes_path_checks() {
    {
        printf 'set -eux\n'
        guest_qubes_path_checks
        cat <<'EOF'
awk 'NF >= 2 && $1 !~ /^#/ && $2 == "/rw" { found = 1 } END { exit found ? 0 : 1 }' /etc/fstab
EOF
    }
}

guest_appvm_identity_checks() {
    local expected_name="$1"

    printf 'expected_name=%q\n' "$expected_name"
    cat <<'EOF'
set -eux
name="$(qubesdb-read /name)"
type="$(qubesdb-read /qubes-vm-type)"
persistence="$(qubesdb-read /qubes-vm-persistence)"
printf "name=%s type=%s persistence=%s\n" "$name" "$type" "$persistence"
test "$name" = "$expected_name"
test "$type" = AppVM
test "$persistence" = rw-only
mountpoint -q /rw
mountpoint -q /home
mountpoint -q /usr/local
test -b /dev/xvdb
EOF
    guest_profile_checks
}

guest_appvm_swap_and_meminfo_checks() {
    cat <<'EOF'
set -eux
/sbin/blockdev --getsz /dev/xvdb >/dev/null
test -b /dev/xvdc1
grep -q "^/dev/xvdc1[[:space:]]" /proc/swaps
test -e /run/qubes-service/meminfo-writer
pidfile=/var/run/meminfo-writer.pid
test -s "$pidfile"
pid="$(cat "$pidfile")"
kill -0 "$pid"
pgrep -x meminfo-writer >/dev/null
EOF
}

guest_appvm_guix_storage_checks() {
    cat <<'EOF'
set -eux
test -w "$HOME"
mkdir -p "$HOME/.config/guix" "$HOME/.cache/guix"
guix --version >/dev/null
rw_dev="$(stat -c %d /rw)"
for path in /home "$HOME" /usr/local; do
    path_dev="$(stat -c %d "$path")"
    printf "%s dev=%s rw_dev=%s private\n" "$path" "$path_dev" "$rw_dev"
    test "$path_dev" = "$rw_dev"
done
for path in /gnu/store /var/guix/db /var/guix/profiles; do
    test -e "$path"
    path_dev="$(stat -c %d "$path")"
    printf "%s dev=%s rw_dev=%s\n" "$path" "$path_dev" "$rw_dev"
    test "$path_dev" != "$rw_dev"
done
per_user_profile="/var/guix/profiles/per-user/$(id -un)"
if [ -e "$per_user_profile" ]; then
    profile_dev="$(stat -c %d "$per_user_profile")"
    printf "%s dev=%s rw_dev=%s\n" "$per_user_profile" "$profile_dev" "$rw_dev"
    test "$profile_dev" != "$rw_dev"
fi
EOF
}

guest_default_route_checks() {
    cat <<'EOF'
set -eu
. /usr/lib/qubes/init/functions
if qsvc disable-default-route; then
    exit 0
fi
ip route show default | grep -q .
test -s /etc/resolv.conf
grep -q "^nameserver[[:space:]]" /etc/resolv.conf
EOF
}

guest_https_probe_checks() {
    cat <<'EOF'
set -eux
. /usr/lib/qubes/init/functions
if qsvc disable-default-route; then
    exit 0
fi
ip route show default | grep -q .
test -s /etc/ssl/certs/ca-certificates.crt
command -v curl >/dev/null
rm -f /tmp/qubes-guix-https-probe
timeout 90 curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto =https \
    --max-time 60 \
    https://guix.gnu.org/ \
    -o /tmp/qubes-guix-https-probe
test -s /tmp/qubes-guix-https-probe
rm -f /tmp/qubes-guix-download.payload \
    /tmp/qubes-guix-download.out \
    /tmp/qubes-guix-download.err
timeout 180 guix download \
    --output=/tmp/qubes-guix-download.payload \
    https://guix.gnu.org/ \
    >/tmp/qubes-guix-download.out \
    2>/tmp/qubes-guix-download.err
test -s /tmp/qubes-guix-download.payload
EOF
}

guest_default_user_checks() {
    cat <<'EOF'
set -eu
expected_user="$(qubesdb-read /default-user 2>/dev/null || echo user)"
test "$(id -un)" = "$expected_user"
test "${HOME:-}" = "/home/$expected_user"
test "${USER:-}" = "$expected_user"
test "${LOGNAME:-}" = "$expected_user"
EOF
}

guest_write_persistence_sentinels() {
    cat <<'EOF'
set -eu
test_path="$HOME/.guix-native-template-test"
case "$test_path" in
    /home/*/.guix-native-template-test) ;;
    *)
        echo "unexpected HOME for persistent AppVM test: $HOME" >&2
        exit 1
        ;;
esac
printf "%s\n" guix-native-template > "$test_path"
EOF
}

guest_root_write_persistence_sentinels() {
    cat <<'EOF'
set -eu
printf "%s\n" guix-rw > /rw/.guix-native-template-rw-test
mkdir -p /usr/local/share
printf "%s\n" guix-usrlocal > /usr/local/share/.guix-native-template-usrlocal-test
touch /var/guix/.qubes-appvm-volatile-test
EOF
}

guest_user_persistence_after_restart_checks() {
    cat <<'EOF'
set -eu
rw_dev="$(stat -c %d /rw)"
home_dev="$(stat -c %d "$HOME")"
printf "%s dev=%s rw_dev=%s after restart\n" "$HOME" "$home_dev" "$rw_dev"
test "$home_dev" = "$rw_dev"
test "$(cat "$HOME/.guix-native-template-test")" = guix-native-template
EOF
}

guest_root_persistence_after_restart_checks() {
    cat <<'EOF'
set -eu
test "$(cat /rw/.guix-native-template-rw-test)" = guix-rw
test "$(cat /usr/local/share/.guix-native-template-usrlocal-test)" = guix-usrlocal
rw_dev="$(stat -c %d /rw)"
for path in /home /usr/local; do
    path_dev="$(stat -c %d "$path")"
    printf "%s dev=%s rw_dev=%s private after restart\n" "$path" "$path_dev" "$rw_dev"
    test "$path_dev" = "$rw_dev"
done
for path in /gnu/store /var/guix/db /var/guix/profiles; do
    test -e "$path"
    path_dev="$(stat -c %d "$path")"
    printf "%s dev=%s rw_dev=%s after restart\n" "$path" "$path_dev" "$rw_dev"
    test "$path_dev" != "$rw_dev"
done
test ! -e /var/guix/.qubes-appvm-volatile-test
EOF
}

find_dom0_appmenu_launcher() {
    local vm="$1"
    local app_id="$2"
    local appmenus_dir="$dom0_test_home/.local/share/qubes-appmenus/$vm/apps"
    local applications_dir="$dom0_test_home/.local/share/applications"
    local file

    if [ -d "$appmenus_dir" ]; then
        while IFS= read -r -d '' file; do
            case "$(basename -- "$file")" in
                *"$app_id"*.desktop) ;;
                *) continue ;;
            esac
            printf '%s\n' "$file"
            return 0
        done < <(find "$appmenus_dir" -type f -name '*.desktop' -print0 2>/dev/null)
    fi

    if [ -d "$applications_dir" ]; then
        while IFS= read -r -d '' file; do
            grep -Fq -- '%VMNAME%' "$file" && continue
            case "$(basename -- "$file")" in
                *"$vm"*"${app_id}"*.desktop) ;;
                *) continue ;;
            esac
            grep -Fq -- "$vm" "$file" || continue
            printf '%s\n' "$file"
            return 0
        done < <(find "$applications_dir" -type f -name '*.desktop' -print0 2>/dev/null)
    fi

    return 1
}

wait_for_guest_process() {
    local vm="$1"
    local process="$2"
    local log_file="${3:-}"
    local attempt
    local stable=0
    local quoted_log

    for attempt in $(seq 1 45); do
        if qvm-run --no-gui --pass-io --user root "$vm" \
            "pgrep -x '$process' >/dev/null" >/dev/null 2>&1; then
            stable=$((stable + 1))
            [ "$stable" -ge 3 ] && return 0
        else
            stable=0
        fi
        sleep 1
    done

    if [ -n "$log_file" ]; then
        printf -v quoted_log '%q' "$log_file"
        qvm-run --no-gui --pass-io --user root "$vm" \
            "if [ -e $quoted_log ]; then echo '-- $log_file --'; tail -200 $quoted_log; fi" \
            >&2 || true
    fi
    collect_vm_diagnostics "$vm"
    die "process did not stay running after GUI launch in $vm: $process"
}

guest_terminal_process_for_desktop() {
    local vm="$1"
    local desktop_path="$2"
    local quoted_desktop_path

    printf -v quoted_desktop_path '%q' "$desktop_path"
    run_vm_cmd "$vm" "
set -eu
desktop_file=$quoted_desktop_path
command -v qubes-desktop-run >/dev/null
test -f \"\$desktop_file\"
desktop_key() {
    awk -F= -v key=\"\$1\" '\$1 == key { print substr(\$0, index(\$0, \"=\") + 1); exit }' \"\$desktop_file\"
}
categories=\"\$(desktop_key Categories)\"
case \";\$categories;\" in
    *';TerminalEmulator;'*) ;;
    *) exit 0 ;;
esac
exec_line=\"\$(desktop_key Exec)\"
[ -n \"\$exec_line\" ]
set -- \$exec_line
process=\"\${1##*/}\"
command -v \"\$process\" >/dev/null
printf '%s\n' \"\$process\"
"
}

dom0_icon_exists() {
    local icon="$1"
    local root name found
    local names=()
    local roots=(
        "$dom0_test_home/.local/share/icons"
        "$dom0_test_home/.local/share/pixmaps"
        /usr/share/icons
        /usr/share/pixmaps
    )

    if [[ "$icon" = /* ]]; then
        [ -e "$icon" ]
        return
    fi

    case "$icon" in
        *.*)
            names=("$icon")
            ;;
        *)
            names=(
                "$icon"
                "$icon.png"
                "$icon.svg"
                "$icon-symbolic.svg"
                "$icon.xpm"
                "$icon.jpg"
                "$icon.jpeg"
                "$icon.ico"
            )
            ;;
    esac

    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        for name in "${names[@]}"; do
            found="$(find -L "$root" -type f -name "$name" -print -quit 2>/dev/null || true)"
            [ -n "$found" ] && return 0
        done
    done

    return 1
}

check_dom0_launcher_icon() {
    local launcher="$1"
    local icon

    icon="$(
        awk -F= '
            tolower($1) == "icon" {
                value = substr($0, index($0, "=") + 1)
                sub(/\r$/, "", value)
                print value
                exit
            }
        ' "$launcher"
    )"
    [ -n "$icon" ] || die "dom0 appmenu launcher has no Icon field: $launcher"
    dom0_icon_exists "$icon" ||
        die "dom0 appmenu icon is not present: $launcher Icon=$icon"
}

run_appmenu_command() {
    local vm="$1"
    local action="$2"
    shift 2
    local output

    output="$(run_as_dom0_user "$@" 2>&1)" || {
        printf '%s\n' "$output" >&2
        return 1
    }
    printf '%s\n' "$output"
    if printf '%s\n' "$output" | grep -Fq "Failed to get icon"; then
        printf '%s\n' "$output" >&2
        die "Qubes appmenu icon retrieval failed while $action $vm"
    fi
}

sync_vm_appmenus() {
    local vm="$1"

    need qvm-sync-appmenus
    need qvm-appmenus
    run_appmenu_command "$vm" syncing qvm-sync-appmenus "$vm"
    run_appmenu_command "$vm" updating qvm-appmenus --update --force "$vm"
}

dump_appmenu_diagnostics() {
    local vm="$1"
    local dir

    printf -- '-- qvm-features %s appmenus --\n' "$vm" >&2
    if command -v qvm-features >/dev/null 2>&1; then
        qvm-features "$vm" 2>&1 |
            grep -E '(^|[[:space:]])(menu-items|default-menu-items|netvm-menu-items|servicevm-menu-items)([[:space:]]|$)' >&2 ||
            true
    fi

    for dir in \
        "$dom0_test_home/.local/share/applications" \
        "$dom0_test_home/.local/share/qubes-appmenus/$vm" \
        "$dom0_test_home/.local/share/qubes-appmenus/$vm/apps"
    do
        [ -e "$dir" ] || continue
        printf -- '-- %s --\n' "$dir" >&2
        find "$dir" -maxdepth 2 -type f -name '*.desktop' -printf '%P\n' 2>/dev/null |
            sort >&2 || true
    done
}

check_appmenu_and_launch_terminals() {
    local vm="$1"
    local desktop
    local app_id
    local desktop_path
    local process
    local quoted_desktop
    local quoted_log
    local log_file
    local launcher

    [ "${#expected_desktops[@]}" -gt 0 ] || return 0
    dom0_test_home="$(getent passwd "$dom0_test_user" | cut -d: -f6)"
    [ -n "$dom0_test_home" ] && [ -d "$dom0_test_home" ] ||
        die "dom0 appmenu test user has no home directory: $dom0_test_user"

    sync_vm_appmenus "$vm"

    for desktop in "${expected_desktops[@]}"; do
        app_id="${desktop%.desktop}"
        desktop_path="/usr/share/applications/$desktop"
        printf 'Checking Qubes appmenu entry for %s in %s\n' "$desktop" "$vm"
        if ! launcher="$(find_dom0_appmenu_launcher "$vm" "$app_id")"; then
            dump_appmenu_diagnostics "$vm"
            die "missing dom0 appmenu launcher for $desktop in $vm"
        fi
        check_dom0_launcher_icon "$launcher"

        process="$(guest_terminal_process_for_desktop "$vm" "$desktop_path")"
        [ -n "$process" ] || continue
        printf 'Launching %s through qubes-desktop-run in %s\n' "$desktop" "$vm"
        printf -v quoted_desktop '%q' "$desktop_path"
        log_file="/tmp/qubes-guix-${app_id}.log"
        printf -v quoted_log '%q' "$log_file"
        run_as_dom0_user qvm-run --no-gui --pass-io "$vm" \
            "sh -lc 'rm -f $quoted_log; setsid qubes-desktop-run $quoted_desktop >$quoted_log 2>&1 </dev/null &'" \
            >/dev/null
        wait_for_guest_process "$vm" "$process" "$log_file"
        qvm-run --no-gui --pass-io --user root "$vm" \
            "pkill -x '$process' || true" >/dev/null 2>&1 || true
    done
}

guest_appvm_failure_diagnostics() {
    cat <<'EOF'
set +e
echo "== qubesdb =="
qubesdb-read /name
qubesdb-read /qubes-vm-type
qubesdb-read /qubes-vm-persistence
echo "== block devices =="
ls -l /dev/xvd* /dev/disk/by-id 2>/dev/null
echo "== mounts =="
findmnt 2>/dev/null || mount
echo "== fstab =="
cat /etc/fstab 2>/dev/null
EOF
}

collect_appvm_diagnostics() {
    local netvm=""

    if ! vm_exists "$appvm_name"; then
        printf 'Skipping AppVM diagnostics: %s does not exist\n' "$appvm_name" >&2
        if [ -n "$appvm_netvm" ] && vm_exists "$appvm_netvm"; then
            collect_vm_diagnostics "$appvm_netvm"
        fi
        collect_dom0_hypervisor_diagnostics
        return
    fi

    netvm="$(qvm-prefs "$appvm_name" netvm 2>/dev/null || true)"
    collect_vm_diagnostics "$appvm_name"
    case "$netvm" in
        ""|None) ;;
        *)
            if vm_exists "$netvm"; then
                collect_vm_diagnostics "$netvm"
            fi
            ;;
    esac
    if ! qvm-check --running "$appvm_name" >/dev/null 2>&1; then
        return
    fi

    printf 'Collecting AppVM diagnostics after smoke-test failure: %s\n' "$appvm_name" >&2
    qvm-run --no-gui --pass-io --user root "$appvm_name" \
        "$(guest_appvm_failure_diagnostics)" >&2 || true
}

cleanup() {
    if [ "$keep_appvm" -eq 0 ] && [ "$appvm_created" -eq 1 ] &&
        vm_exists "$appvm_name"; then
        qvm-shutdown --wait "$appvm_name" >/dev/null 2>&1 || true
        qvm-remove --force "$appvm_name" >/dev/null 2>&1 || true
    fi
}

on_exit() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$diagnostics_enabled" -eq 1 ]; then
        collect_appvm_diagnostics
    fi
    cleanup
    exit "$status"
}
trap on_exit EXIT

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --template)
                require_arg "$@"
                template_name="$2"
                shift 2
                ;;
            --variant)
                require_arg "$@"
                template_variant="$2"
                shift 2
                ;;
            --appvm)
                require_arg "$@"
                appvm_name="$2"
                shift 2
                ;;
            --appvm-netvm)
                require_arg "$@"
                appvm_netvm="$2"
                shift 2
                ;;
            --keep-appvm)
                keep_appvm=1
                shift
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
}

check_required_commands() {
    need qvm-ls
    need qvm-create
    need qvm-run
    need qvm-start
    need qvm-shutdown
    need qvm-kill
    need qvm-remove
    need qvm-prefs
    need qvm-check
    need qvm-sync-appmenus
    need qvm-appmenus
}

prepare_smoke_test() {
    load_variant_expectations
    check_required_commands
    ensure_qubesd_available
    ensure_qvm_start_daemon
    kernel="$(resolve_kernel)"

    vm_exists "$template_name" ||
        die "template does not exist: $template_name"
    if vm_exists "$appvm_name"; then
        die "temporary AppVM already exists: $appvm_name"
    fi

    diagnostics_enabled=1
    stop_stale_vm_or_die "$template_name"
}

test_template_vm() {
    printf 'Testing TemplateVM boot and qrexec: %s\n' "$template_name"
    start_vm_or_die "$template_name"
    wait_for_qrexec "$template_name"
    run_vm_cmd "$template_name" "$(guest_template_boot_checks)"
    run_vm_cmd "$template_name" 'id && uname -a'
    run_vm_cmd "$template_name" "$(guest_qrexec_agent_checks)"
    run_vm_root_cmd "$template_name" "$(guest_template_writable_path_checks)"
    sync_vm_appmenus "$template_name"
    shutdown_vm_or_die "$template_name"
}

create_test_appvm() {
    printf 'Creating temporary AppVM: %s\n' "$appvm_name"
    qvm-create --class AppVM --template "$template_name" --label gray "$appvm_name"
    appvm_created=1
    qvm-prefs "$appvm_name" virt_mode pvh
    qvm-prefs "$appvm_name" kernel "$kernel"
    if [ -n "$appvm_netvm" ]; then
        qvm-check "$appvm_netvm" >/dev/null 2>&1 ||
            die "requested AppVM NetVM does not exist: $appvm_netvm"
        qvm-prefs "$appvm_name" netvm "$appvm_netvm"
    fi
}

test_appvm_uplink() {
    local current_netvm

    current_netvm="$(qvm-prefs "$appvm_name" netvm 2>/dev/null || true)"
    case "$current_netvm" in
        ""|None)
            printf 'Skipping AppVM uplink route check: %s has no NetVM\n' \
                "$appvm_name"
            ;;
        *)
            run_vm_root_cmd "$appvm_name" "$(guest_default_route_checks)"
            run_vm_cmd "$appvm_name" "$(guest_https_probe_checks)"
            ;;
    esac
}

test_appvm_first_boot() {
    start_vm_or_die "$appvm_name"
    wait_for_qrexec "$appvm_name"
    run_vm_cmd "$appvm_name" "$(guest_appvm_identity_checks "$appvm_name")"
    run_vm_root_cmd "$appvm_name" "$(guest_appvm_swap_and_meminfo_checks)"
    run_vm_root_cmd "$appvm_name" "$(guest_appvm_qubes_path_checks)"
    run_vm_cmd "$appvm_name" 'echo qrexec-ok && id && uname -a'
    run_vm_cmd "$appvm_name" "$(guest_appvm_guix_storage_checks)"
    test_appvm_uplink
    check_wait_for_session_rpc "$appvm_name"
    check_appmenu_and_launch_terminals "$appvm_name"
    run_vm_cmd "$appvm_name" "$(guest_default_user_checks)"
    run_vm_cmd "$appvm_name" "$(guest_write_persistence_sentinels)"
    run_vm_root_cmd "$appvm_name" "$(guest_root_write_persistence_sentinels)"
}

test_appvm_after_restart() {
    shutdown_vm_or_die "$appvm_name"
    start_vm_or_die "$appvm_name"
    wait_for_qrexec "$appvm_name"
    run_vm_cmd "$appvm_name" "$(guest_user_persistence_after_restart_checks)"
    run_vm_root_cmd "$appvm_name" "$(guest_root_persistence_after_restart_checks)"
    check_wait_for_session_rpc "$appvm_name"
}

main() {
    parse_args "$@"
    prepare_smoke_test
    test_template_vm
    create_test_appvm
    test_appvm_first_boot
    test_appvm_after_restart

    printf 'native Guix TemplateVM smoke tests passed for %s\n' "$template_name"
}

main "$@"
