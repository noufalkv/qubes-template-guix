#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

template_name="guix-native-test"
appvm_name="guix-native-test-app"
appvm_netvm="${QUBES_GUIX_APPVM_NETVM:-}"
qrexec_socket_dir="${QUBES_QREXEC_SOCKET_DIR:-/var/run/qubes}"
run_system_tests=0
keep_appvm=0
system_tests="qubes.tests.integ.qrexec:14400 qubes.tests.integ.vm_qrexec_gui:14400"
dom0_test_user="${QUBES_DOM0_TEST_USER:-user}"
system_test_netvm="${QUBES_SYSTEM_TEST_NETVM:-guix-system-test-netvm}"
system_test_pythonpath=""
force_system_test_vm_netvm_none=0
expected_commands=()
expected_desktops=()

usage() {
    cat <<'EOF'
Usage: test-native-guix-template-dom0.sh [options]

Runs dom0-side smoke tests against a native GNU Guix System TemplateVM.

Options:
  --template NAME       TemplateVM to test. Default: guix-native-test
  --appvm NAME          Temporary AppVM name. Default: guix-native-test-app
  --appvm-netvm NAME    Attach the temporary AppVM to this NetVM for uplink
                        checks. Default: keep dom0's default netvm behavior.
  --run-system-tests    Also run selected Qubes dom0 integration tests.
  --system-tests LIST   Space-separated Qubes test modules. Each module may
                        be suffixed with :TIMEOUT. Default:
                        qubes.tests.integ.qrexec:14400 qubes.tests.integ.vm_qrexec_gui:14400
  --expect-command CMD  Require CMD to resolve inside TemplateVM and AppVM.
  --expect-desktop ID   Require a desktop-file ID inside TemplateVM and AppVM.
  --keep-appvm          Do not remove the temporary AppVM after tests.
  -h, --help            Show this help.

The optional system-test mode is intentionally off by default. It sets the test
template as dom0's default template, stops qubesd while running, and uses Qubes'
own openQA nose2/load_tests runner command with root privileges, while keeping
the normal dom0 user's home/runtime/display environment.  The default module set
uses Qubes' qrexec and vm_qrexec_gui suites because they exercise the tested
template directly; pass --system-tests explicitly to run broader dom0 host
scenarios such as qubes.tests.integ.basic.  This serial-console harness does not
wrap nose2 in script(1), because script(1) can stop itself under the
non-interactive openQA serial pipeline before nose2 starts.
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

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_nose2_runner() {
    if command -v nose2 >/dev/null 2>&1; then
        return
    fi

    if [ -n "${GUIX_NOSE2_RPM:-}" ] && [ -r "$GUIX_NOSE2_RPM" ]; then
        printf 'nose2 not found; installing %s\n' "$GUIX_NOSE2_RPM"
        if command -v dnf >/dev/null 2>&1; then
            run_as_root dnf -y install "$GUIX_NOSE2_RPM" || true
        fi
        if ! command -v nose2 >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
            run_as_root rpm -Uvh --replacepkgs "$GUIX_NOSE2_RPM" || true
        fi
        if command -v nose2 >/dev/null 2>&1; then
            return
        fi
    fi

    printf 'nose2 not found; installing python3-nose2 for Qubes system tests\n'
    if command -v qubes-dom0-update >/dev/null 2>&1; then
        run_as_root qubes-dom0-update -y python3-nose2 || true
    fi
    if ! command -v nose2 >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
        run_as_root dnf -y install python3-nose2 || true
    fi

    command -v nose2 >/dev/null 2>&1 ||
        die "nose2 is required for Qubes openQA-compatible system tests"
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
            'set +e; echo "== qrexec runtime =="; id; ps -efww | grep -E "qrexec|qubes|shepherd" | grep -v grep; ls -la /run/qubes /var/run/qubes 2>/dev/null; echo "== guest logs =="; for log in /var/log/qubes-qrexec-agent.log /var/log/qubes-qrexec-fork-server.log /var/log/qubes-gui-agent.log /var/log/Xorg.0.log /home/user/.xsession-errors /home/user/.xorg-errors /var/log/shepherd.log; do [ -e "$log" ] || continue; echo "-- $log --"; tail -240 "$log"; done' \
            >&2 || true
        if vm_provides_network "$vm"; then
            timeout 45 qvm-run --no-gui --pass-io --user root "$vm" '
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
            ' >&2 || true
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
        printf 'command -v %q >/dev/null; ' "$command_name"
    done
}

guest_desktop_checks() {
    local desktop_file

    for desktop_file in "${expected_desktops[@]}"; do
        printf 'test -f /usr/share/applications/%q; ' "$desktop_file"
    done
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
    qvm-run --no-gui --pass-io --user root "$appvm_name" '
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
        echo "== Qubes logs =="
        for log in /var/log/qubes-*.log /var/log/qubes/* \
            /var/log/Xorg.0.log \
            /home/user/.xsession-errors /home/user/.xorg-errors; do
            [ -e "$log" ] || continue
            echo "-- $log --"
            tail -200 "$log"
        done
    ' >&2 || true
}

collect_system_test_diagnostics() {
    local test_spec="$1"
    local log_file="$2"
    local vm

    printf 'Collecting Qubes system-test diagnostics after failure: %s\n' "$test_spec" >&2
    ps -efww | grep -E 'nose2|qubes.tests|qvm-|qubesd|qrexec|script|timeout' >&2 || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status qubesd virtxend libvirtd virtqemud xenstored xenconsoled \
            --no-pager -l >&2 || true
    fi
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -b \
            -u qubesd \
            -u virtxend \
            -u libvirtd \
            -u virtqemud \
            -u xenstored \
            -u xenconsoled \
            -n 500 --no-pager >&2 || true
    fi

    free -h >&2 || true
    df -hT / /var/lib/qubes /var/tmp /tmp >&2 || true
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS >&2 || true
    qvm-ls --fields NAME,STATE,CLASS,TEMPLATE,KERNEL,VIRT_MODE >&2 || true
    qvm-pool list >&2 || true
    qvm-pool info varlibqubes >&2 || true

    for vm in "$template_name" "$appvm_name" "$system_test_netvm" \
        test-inst-vm1 test-inst-vm2; do
        vm_exists "$vm" || continue
        printf -- '-- qvm-prefs %s --\n' "$vm" >&2
        qvm-prefs "$vm" >&2 || true
        printf -- '-- qvm-volume info %s:* --\n' "$vm" >&2
        qvm-volume info "$vm:root" >&2 || true
        qvm-volume info "$vm:private" >&2 || true
        qvm-volume info "$vm:volatile" >&2 || true
        if qvm-check --running "$vm" >/dev/null 2>&1; then
            printf -- '-- guest GUI diagnostics %s --\n' "$vm" >&2
            timeout 45 qvm-run --no-gui --pass-io --user root "$vm" '
                set +e
                echo "== processes =="
                ps -efww | grep -E "qubes|qrexec|Xorg|xinit|xterm" | grep -v grep
                echo "== display state =="
                env | sort | grep -E "^(DISPLAY|XDG_|DBUS_|QUBES_)=" || true
                ls -la /tmp/.X11-unix /run/user/* 2>/dev/null || true
                echo "== PAM snippets =="
                ls -la /etc/pam.d 2>/dev/null || true
                for pam in /etc/pam.d/qubes-gui-agent /etc/pam.d/su; do
                    [ -e "$pam" ] || continue
                    echo "-- $pam --"
                    cat "$pam"
                done
                echo "== Qubes and X logs =="
                for log in \
                    /var/log/qubes-gui-agent.log \
                    /var/log/qubes-qrexec-agent.log \
                    /var/log/qubes-qrexec-fork-server.log \
                    /home/user/.xsession-errors \
                    /home/user/.xorg-errors
                do
                    [ -e "$log" ] || continue
                    echo "-- $log --"
                    tail -240 "$log"
                done
            ' >&2 || true
        fi
    done

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

    for log in /var/log/xen/*.log /var/log/libvirt/libxl/*.log; do
        [ -e "$log" ] || continue
        printf -- '-- %s --\n' "$log" >&2
        read_root_file "$log" >&2
    done
    printf -- '-- /var/lib/qubes layout --\n' >&2
    find /var/lib/qubes -maxdepth 3 \
        \( -name '*test*' -o -name "$template_name" -o -name "$system_test_netvm" \) \
        -printf '%M %u %g %s %p\n' >&2 || true

    if [ -e "$log_file" ]; then
        printf -- '-- %s --\n' "$log_file" >&2
        tail -240 "$log_file" >&2 || true
    fi
}

prepare_system_test_user() {
    local uid
    local gid
    local runtime_dir

    id "$dom0_test_user" >/dev/null 2>&1 ||
        die "dom0 system-test user does not exist: $dom0_test_user"

    uid="$(id -u "$dom0_test_user")"
    gid="$(id -g "$dom0_test_user")"
    runtime_dir="/run/user/$uid"
    run_as_root install -d -m 0700 -o "$uid" -g "$gid" "$runtime_dir"
    printf '%s\n' "$runtime_dir"
}

prepare_system_test_pythonpath() {
    local support_dir="/tmp/qubes-guix-system-test-python"

    [ "$force_system_test_vm_netvm_none" -eq 1 ] || return 0

    run_as_root install -d -m 0755 "$support_dir"
    run_as_root tee "$support_dir/sitecustomize.py" >/dev/null <<'PY'
"""Qubes system-test compatibility hooks for the Guix template harness.

This file is injected only when the nested dom0 has no real default NetVM and
the harness had to create a synthetic one to satisfy Qubes' test-suite cleanup
assumptions.  Non-network vm_qrexec_gui tests should not depend on that
synthetic NetVM, so force their generated test VMs to have no netvm.
"""

import os
import sys


def _patch_vm_qrexec_gui_netvm():
    if os.environ.get("QUBES_GUIX_FORCE_TESTVM_NETVM_NONE") != "1":
        return

    try:
        import qubes.tests.integ.vm_qrexec_gui as vm_qrexec_gui
    except Exception as exc:  # pragma: no cover - best-effort test harness hook
        print(
            "qubes-guix: failed to import vm_qrexec_gui for netvm hook: {}".format(
                exc
            ),
            file=sys.stderr,
        )
        return

    original_setup = vm_qrexec_gui.TC_00_AppVMMixin.setUp

    def setUp(self):
        original_setup(self)
        if getattr(self, "_testMethodName", "") == "test_210_time_sync":
            return
        changed = False
        for attr in ("testvm1", "testvm2"):
            vm = getattr(self, attr, None)
            if vm is None:
                continue
            vm.netvm = None
            changed = True
        if changed:
            self.app.save()

    vm_qrexec_gui.TC_00_AppVMMixin.setUp = setUp
    print(
        "qubes-guix: forcing vm_qrexec_gui non-network test VMs to netvm=None",
        file=sys.stderr,
    )


_patch_vm_qrexec_gui_netvm()
PY
    printf '%s\n' "$support_dir"
}

ensure_system_test_default_netvm() {
    local current_netvm

    current_netvm="$(qubes-prefs default_netvm 2>/dev/null || true)"
    case "$current_netvm" in
        ""|None) ;;
        *) return 0 ;;
    esac

    printf 'Nested dom0 has no default_netvm; creating %s for Qubes system-test cleanup compatibility\n' \
        "$system_test_netvm"
    force_system_test_vm_netvm_none=1
    if ! vm_exists "$system_test_netvm"; then
        qvm-create --class AppVM --template "$template_name" --label red "$system_test_netvm"
        qvm-prefs "$system_test_netvm" virt_mode pvh
        qvm-prefs "$system_test_netvm" kernel "$kernel"
    fi

    # Qubes' integration-test cleanup code assumes default_netvm is an object
    # with a name, as it is in the official openQA environment.  The synthetic
    # NetVM is not expected to provide real external networking for these GUI
    # and qrexec tests; it only satisfies that dom0-wide test-suite invariant.
    qvm-prefs "$system_test_netvm" netvm "" >/dev/null 2>&1 || true
    qvm-prefs "$system_test_netvm" vcpus 1 >/dev/null 2>&1 || true
    qvm-prefs "$system_test_netvm" memory 300 >/dev/null 2>&1 || true
    qvm-prefs "$system_test_netvm" maxmem 600 >/dev/null 2>&1 || true
    qvm-prefs "$system_test_netvm" provides_network true
    qubes-prefs default_netvm "$system_test_netvm"
}

run_nose2_system_test() {
    local test_timeout="$1"
    local runtime_dir="$2"
    local test_home="$3"
    local display
    local env_args
    local xauthority
    shift 3

    display="${QUBES_DOM0_DISPLAY:-${DISPLAY:-:0}}"
    xauthority="${QUBES_DOM0_XAUTHORITY:-$test_home/.Xauthority}"

    env_args=(
        QUBES_TEST_TEMPLATES="$template_name" \
        QUBES_TEST_SKIP_KERNEL_INSTALL=1 \
        PYTHONUNBUFFERED=1 \
        XDG_RUNTIME_DIR="$runtime_dir" \
        HOME="$test_home" \
        USER="$dom0_test_user" \
        LOGNAME="$dom0_test_user" \
        SUDO_USER="$dom0_test_user" \
        DISPLAY="$display" \
        XAUTHORITY="$xauthority"
    )
    if [ -n "$system_test_pythonpath" ]; then
        env_args+=(
            PYTHONPATH="$system_test_pythonpath${PYTHONPATH:+:$PYTHONPATH}"
            QUBES_GUIX_FORCE_TESTVM_NETVM_NONE=1
        )
    fi

    run_as_root env "${env_args[@]}" \
        timeout --foreground "$test_timeout" \
        bash -lc 'cd "$1"; shift; exec "$@"' bash "$test_home" \
        "$@"
}

cleanup() {
    if [ "$keep_appvm" -eq 0 ] && vm_exists "$appvm_name"; then
        qvm-shutdown --wait "$appvm_name" >/dev/null 2>&1 || true
        qvm-remove --force "$appvm_name" >/dev/null 2>&1 || true
    fi
}

on_exit() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        collect_appvm_diagnostics
    fi
    cleanup
    exit "$status"
}
trap on_exit EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --template)
            require_arg "$@"
            template_name="$2"
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
        --run-system-tests)
            run_system_tests=1
            shift
            ;;
        --system-tests)
            require_arg "$@"
            system_tests="$2"
            shift 2
            ;;
        --expect-command)
            require_arg "$@"
            expected_commands+=("$2")
            shift 2
            ;;
        --expect-desktop)
            require_arg "$@"
            expected_desktops+=("$2")
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

need qvm-ls
need qvm-create
need qvm-run
need qvm-start
need qvm-shutdown
need qvm-kill
need qvm-remove
need qvm-prefs
need qvm-check

ensure_qubesd_available
ensure_qvm_start_daemon
kernel="$(resolve_kernel)"
vm_exists "$template_name" || die "template does not exist: $template_name"
if vm_exists "$appvm_name"; then
    die "temporary AppVM already exists: $appvm_name"
fi

stop_stale_vm_or_die "$template_name"

printf 'Testing TemplateVM boot and qrexec: %s\n' "$template_name"
qvm-start "$template_name" >/dev/null 2>&1 || true
wait_for_qrexec "$template_name"
run_qubes_cmd qvm-run --no-gui --pass-io "$template_name" \
    'set -e; qubesdb-read /name; /usr/bin/qubesdb-read /qubes-vm-type; test -x /usr/bin/python3; test -x /sbin/blockdev; test -x /sbin/poweroff; '"$(guest_command_checks)$(guest_desktop_checks)"'true'
run_qubes_cmd qvm-run --no-gui --pass-io "$template_name" 'id && uname -a'
run_qubes_cmd qvm-run --no-gui --pass-io "$template_name" \
    'test -e /usr/lib/qubes/qrexec-agent || test -e /run/current-system/profile/lib/qubes/qrexec-agent'
run_qubes_cmd qvm-run --no-gui --pass-io --user root "$template_name" \
    'set -eux; test -f /etc/fstab; test ! -L /etc/fstab; test -L /usr/lib/qubes; test -L /usr/lib/qubes-bind-dirs.d; test -d /etc/qubes-rpc; test ! -L /etc/qubes-rpc; test -d /etc/qubes/post-install.d; test ! -L /etc/qubes/post-install.d; printf "#!/bin/sh\nexit 0\n" > /etc/qubes-rpc/test.GuixWritable; chmod 755 /etc/qubes-rpc/test.GuixWritable; test -x /etc/qubes-rpc/test.GuixWritable; printf "#!/bin/sh\nexit 0\n" > /etc/qubes/post-install.d/50-test.sh; chmod 755 /etc/qubes/post-install.d/50-test.sh; test -x /etc/qubes/post-install.d/50-test.sh; test -x /etc/qubes-rpc/qubes.WaitForSession; test -x /etc/qubes-rpc/qubes.VMShell; grep -F "exec /bin/bash" /etc/qubes-rpc/qubes.VMShell'
shutdown_vm_or_die "$template_name"

printf 'Creating temporary AppVM: %s\n' "$appvm_name"
qvm-create --class AppVM --template "$template_name" --label gray "$appvm_name"
qvm-prefs "$appvm_name" virt_mode pvh
qvm-prefs "$appvm_name" kernel "$kernel"
if [ -n "$appvm_netvm" ]; then
    qvm-check "$appvm_netvm" >/dev/null 2>&1 ||
        die "requested AppVM NetVM does not exist: $appvm_netvm"
    qvm-prefs "$appvm_name" netvm "$appvm_netvm"
fi

qvm-start "$appvm_name" >/dev/null
wait_for_qrexec "$appvm_name"
run_qubes_cmd qvm-run --no-gui --pass-io "$appvm_name" \
    'set -eux; name="$(qubesdb-read /name)"; type="$(qubesdb-read /qubes-vm-type)"; persistence="$(qubesdb-read /qubes-vm-persistence)"; printf "name=%s type=%s persistence=%s\n" "$name" "$type" "$persistence"; test "$name" = "'"$appvm_name"'"; test "$type" = AppVM; test "$persistence" = rw-only; mountpoint -q /rw; mountpoint -q /home; mountpoint -q /usr/local; test -b /dev/xvdb; '"$(guest_command_checks)$(guest_desktop_checks)"'true'
run_qubes_cmd qvm-run --no-gui --pass-io --user root "$appvm_name" \
    'set -eux; /sbin/blockdev --getsz /dev/xvdb >/dev/null; test -b /dev/xvdc1; grep -q "^/dev/xvdc1[[:space:]]" /proc/swaps; test -e /run/qubes-service/meminfo-writer; pidfile=/var/run/meminfo-writer.pid; test -s "$pidfile"; pid="$(cat "$pidfile")"; kill -0 "$pid"; pgrep -x meminfo-writer >/dev/null'
run_qubes_cmd qvm-run --no-gui --pass-io --user root "$appvm_name" \
    'set -eux; test -f /etc/fstab; test ! -L /etc/fstab; awk '\''NF >= 2 && $1 !~ /^#/ && $2 == "/rw" { found = 1 } END { exit found ? 0 : 1 }'\'' /etc/fstab; test -L /usr/lib/qubes; test -L /usr/lib/qubes-bind-dirs.d; test -d /etc/qubes-rpc; test ! -L /etc/qubes-rpc; test -d /etc/qubes/post-install.d; test ! -L /etc/qubes/post-install.d; test -x /etc/qubes-rpc/qubes.WaitForSession; test -x /etc/qubes-rpc/qubes.VMShell'
run_qubes_cmd qvm-run --no-gui --pass-io "$appvm_name" 'echo qrexec-ok && id && uname -a'
run_qubes_cmd qvm-run --no-gui --pass-io "$appvm_name" \
    'set -eux; test -w "$HOME"; mkdir -p "$HOME/.config/guix" "$HOME/.cache/guix"; guix --version >/dev/null; rw_dev="$(stat -c %d /rw)"; for path in /home "$HOME" /usr/local; do path_dev="$(stat -c %d "$path")"; printf "%s dev=%s rw_dev=%s private\n" "$path" "$path_dev" "$rw_dev"; test "$path_dev" = "$rw_dev"; done; for path in /gnu/store /var/guix/db /var/guix/profiles; do test -e "$path"; path_dev="$(stat -c %d "$path")"; printf "%s dev=%s rw_dev=%s\n" "$path" "$path_dev" "$rw_dev"; test "$path_dev" != "$rw_dev"; done; per_user_profile="/var/guix/profiles/per-user/$(id -un)"; if [ -e "$per_user_profile" ]; then profile_dev="$(stat -c %d "$per_user_profile")"; printf "%s dev=%s rw_dev=%s\n" "$per_user_profile" "$profile_dev" "$rw_dev"; test "$profile_dev" != "$rw_dev"; fi'
current_netvm="$(qvm-prefs "$appvm_name" netvm 2>/dev/null || true)"
case "$current_netvm" in
    ""|None) printf 'Skipping AppVM uplink route check: %s has no NetVM\n' "$appvm_name" ;;
    *)
        run_qubes_cmd qvm-run --no-gui --pass-io --user root "$appvm_name" \
            'set -eu; . /usr/lib/qubes/init/functions; if qsvc disable-default-route; then exit 0; fi; ip route show default | grep -q .; test -s /etc/resolv.conf; grep -q "^nameserver[[:space:]]" /etc/resolv.conf'
        ;;
esac
check_wait_for_session_rpc "$appvm_name"
run_qubes_cmd qvm-run --no-gui --pass-io "$appvm_name" \
    'set -eu; expected_user="$(qubesdb-read /default-user 2>/dev/null || echo user)"; test "$(id -un)" = "$expected_user"; test "${HOME:-}" = "/home/$expected_user"; test "${USER:-}" = "$expected_user"; test "${LOGNAME:-}" = "$expected_user"'
run_qubes_cmd qvm-run --no-gui --pass-io "$appvm_name" \
    'set -eu; test_path="$HOME/.guix-native-template-test"; case "$test_path" in /home/*/.guix-native-template-test) ;; *) echo "unexpected HOME for persistent AppVM test: $HOME" >&2; exit 1;; esac; printf "%s\n" guix-native-template > "$test_path"'
run_qubes_cmd qvm-run --no-gui --pass-io --user root "$appvm_name" \
    'set -eu; printf "%s\n" guix-rw > /rw/.guix-native-template-rw-test; mkdir -p /usr/local/share; printf "%s\n" guix-usrlocal > /usr/local/share/.guix-native-template-usrlocal-test'
run_qubes_cmd qvm-run --no-gui --pass-io --user root "$appvm_name" \
    'set -eu; touch /var/guix/.qubes-appvm-volatile-test'
shutdown_vm_or_die "$appvm_name"
qvm-start "$appvm_name" >/dev/null
wait_for_qrexec "$appvm_name"
run_qubes_cmd qvm-run --no-gui --pass-io "$appvm_name" \
    'set -eu; rw_dev="$(stat -c %d /rw)"; home_dev="$(stat -c %d "$HOME")"; printf "%s dev=%s rw_dev=%s after restart\n" "$HOME" "$home_dev" "$rw_dev"; test "$home_dev" = "$rw_dev"; test "$(cat "$HOME/.guix-native-template-test")" = guix-native-template'
run_qubes_cmd qvm-run --no-gui --pass-io --user root "$appvm_name" \
    'set -eu; test "$(cat /rw/.guix-native-template-rw-test)" = guix-rw; test "$(cat /usr/local/share/.guix-native-template-usrlocal-test)" = guix-usrlocal; rw_dev="$(stat -c %d /rw)"; for path in /home /usr/local; do path_dev="$(stat -c %d "$path")"; printf "%s dev=%s rw_dev=%s private after restart\n" "$path" "$path_dev" "$rw_dev"; test "$path_dev" = "$rw_dev"; done; for path in /gnu/store /var/guix/db /var/guix/profiles; do test -e "$path"; path_dev="$(stat -c %d "$path")"; printf "%s dev=%s rw_dev=%s after restart\n" "$path" "$path_dev" "$rw_dev"; test "$path_dev" != "$rw_dev"; done; test ! -e /var/guix/.qubes-appvm-volatile-test'
check_wait_for_session_rpc "$appvm_name"

if [ "$run_system_tests" -eq 1 ]; then
    need qubes-prefs
    previous_default_template="$(qubes-prefs default_template 2>/dev/null || true)"
    if [ "$previous_default_template" != "$template_name" ]; then
        qvm-prefs "$template_name" template_for_dispvms true >/dev/null 2>&1 || true
        qubes-prefs default_template "$template_name"
    fi
    ensure_nose2_runner
    need systemctl
    need timeout
    dom0_test_home="$(getent passwd "$dom0_test_user" | cut -d: -f6)"
    [ -n "$dom0_test_home" ] && [ -d "$dom0_test_home" ] ||
        die "dom0 system-test user has no home directory: $dom0_test_user"
    runtime_dir="$(prepare_system_test_user)"
    if [ "$keep_appvm" -eq 0 ]; then
        cleanup
    fi
    ensure_system_test_default_netvm
    system_test_pythonpath="$(prepare_system_test_pythonpath)"
    printf 'Running Qubes system tests for template %s with dom0 user environment %s: %s\n' \
        "$template_name" "$dom0_test_user" "$system_tests"
    for test_spec in $system_tests; do
        test_module="${test_spec%%:*}"
        if [ "$test_module" != "$test_spec" ]; then
            test_timeout="${test_spec##*:}"
        else
            test_timeout=3600
        fi
        case "$test_timeout" in
            ''|*[!0-9]*)
                die "invalid Qubes system test timeout in: $test_spec"
                ;;
        esac
        log_file="tests-$test_module.log"
        test_runner=(nose2 -v --plugin nose2.plugins.loader.loadtests)
        # The Qubes openQA runner passes -X, but the nose2 builds available in
        # some dom0 test images do not expose that option.  Use it when present
        # without making the template validation depend on a runner-version
        # detail unrelated to the guest image.
        if nose2 -h 2>&1 | grep -Eq '(^|[[:space:]])-X([,[:space:]]|$)'; then
            test_runner+=(-X)
        fi
        test_runner+=("$test_module")
        printf 'Running Qubes system test module with official nose2 loader: %s\n' "$test_module"
        sudo systemctl stop qubesd
        set +e
        run_nose2_system_test "$test_timeout" "$runtime_dir" "$dom0_test_home" \
            "${test_runner[@]}" 2>&1 | tee "$log_file"
        status=${PIPESTATUS[0]}
        set -e
        sudo systemctl start qubesd || true
        ensure_qubesd_available || true
        if [ "$status" -ne 0 ]; then
            collect_system_test_diagnostics "$test_spec" "$log_file"
            die "Qubes system test failed: $test_spec"
        fi
    done
fi

printf 'native Guix TemplateVM smoke tests passed for %s\n' "$template_name"
