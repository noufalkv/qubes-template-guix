#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

target_name="${QUBES_UPDATE_TARGET_NAME:-sys-net}"
template_name="${QUBES_UPDATE_TARGET_TEMPLATE:-}"
network_mode="${QUBES_UPDATE_TARGET_NETWORK_MODE:-auto}"
resolved_network_mode=""
template_rpm=""

usage() {
    cat <<'EOF'
Usage: bootstrap-qubes-update-target-dom0.sh [options]

Install a standard template RPM if needed, create/start a sys-net style update
target, and make it dom0's update VM for nested openQA update-path tests.

Options:
  -r, --template-rpm FILE  qvm-template RPM to install if the template is absent.
  -T, --target NAME        Update target VM name. Default: sys-net.
  -t, --template NAME      Template name to use. Default: derived from RPM.
  -n, --network-mode MODE  Network backend: auto, pci, bridge, or nat. Default: auto.
  -h, --help               Show this help.
EOF
}

die() {
    printf 'bootstrap update target failed: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

validate_qube_name() {
    local label="$1"
    local value="$2"

    case "$value" in
        ''|*[!A-Za-z0-9_.-]*)
            die "invalid $label name: $value"
            ;;
    esac
}

validate_network_mode() {
    case "$network_mode" in
        auto|pci|bridge|nat) ;;
        *) die "invalid network mode: $network_mode" ;;
    esac
}

template_from_rpm() {
    local rpm_file="$1"
    local rpm_name

    rpm_name="$(rpm -qp --qf '%{NAME}' "$rpm_file")"
    case "$rpm_name" in
        qubes-template-*) printf '%s\n' "${rpm_name#qubes-template-}" ;;
        *) die "not a qvm-template RPM: $rpm_file" ;;
    esac
}

selected_network_mode() {
    case "$network_mode" in
        auto)
            if has_iommu_passthrough; then
                printf 'pci\n'
            else
                printf 'nat\n'
            fi
            ;;
        *)
            printf '%s\n' "$network_mode"
            ;;
    esac
}

find_network_pci_device() {
    local pci_id

    pci_id="$(network_pci_bdf)" || return 1
    printf 'dom0:%s\n' "$(printf '%s\n' "$pci_id" | sed 's/^0000://; s/:/_/g')"
}

network_pci_bdf() {
    local pci_id

    pci_id="$(lspci -Dn | awk '$2 == "0200:" || $2 == "0280:" { print $1; exit }')"
    [ -n "$pci_id" ] || return 1
    case "$pci_id" in
        0000:*) printf '%s\n' "$pci_id" ;;
        *) printf '0000:%s\n' "$pci_id" ;;
    esac
}

attach_network_device() {
    local pci_dev

    pci_dev="$(find_network_pci_device)" ||
        die "could not find a dom0 network PCI device for $target_name"

    qvm-pci detach "$target_name" "$pci_dev" >/dev/null 2>&1 ||
        qvm-pci dt "$target_name" "$pci_dev" >/dev/null 2>&1 ||
        true
    # Nested openQA passes through a QEMU NIC; pciback reports filtered config
    # writes for it unless permissive PCI config-space access is enabled.
    qvm-pci attach --persistent --option no-strict-reset=True --option permissive=True \
        "$target_name" "$pci_dev" >/dev/null 2>&1 ||
        qvm-pci at "$target_name" "$pci_dev" -p -o no-strict-reset=True -o permissive=True
}

detach_network_device() {
    local pci_dev

    pci_dev="$(find_network_pci_device)" || return 0
    qvm-pci detach "$target_name" "$pci_dev" >/dev/null 2>&1 ||
        qvm-pci dt "$target_name" "$pci_dev" >/dev/null 2>&1 ||
        true
}

has_iommu_passthrough() {
    xl info 2>/dev/null | awk -F: '/virt_caps/ { print $2 }' |
        grep -qw hvm_directio
}

pci_driver() {
    local bdf="$1"

    basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || printf none)"
}

pci_is_pciback_driver() {
    local driver="$1"

    [ "$driver" = pciback ] || [ "$driver" = xen-pciback ]
}

pci_assignable_contains() {
    local bdf="$1"
    local short_bdf="${bdf#0000:}"

    xl pci-assignable-list 2>/dev/null |
        awk -v bdf="$bdf" -v short_bdf="$short_bdf" \
            '$1 == bdf || $1 == short_bdf { found = 1 } END { exit !found }'
}

remove_pciback_slot() {
    local bdf="$1"
    local short_bdf="${bdf#0000:}"
    local driver

    for driver in pciback xen-pciback; do
        [ -w "/sys/bus/pci/drivers/$driver/remove_slot" ] || continue
        printf '%s' "$bdf" >"/sys/bus/pci/drivers/$driver/remove_slot" 2>/dev/null ||
            printf '%s' "$short_bdf" >"/sys/bus/pci/drivers/$driver/remove_slot" 2>/dev/null ||
            true
    done
}

remove_pci_from_assignable() {
    local bdf="$1"
    local tmp
    local rc

    pci_assignable_contains "$bdf" || return 0

    printf 'removing %s from Xen assignable PCI devices\n' "$bdf"
    tmp="$(mktemp /tmp/qubes-pci-assignable-remove.XXXXXX)"
    if xl pci-assignable-remove -r "$bdf" >"$tmp" 2>&1; then
        :
    else
        rc=$?
        printf 'xl pci-assignable-remove -r %s failed with rc=%s:\n' "$bdf" "$rc" >&2
        sed 's/^/  /' "$tmp" >&2
    fi

    if pci_assignable_contains "$bdf"; then
        if xl pci-assignable-remove "$bdf" >"$tmp" 2>&1; then
            :
        else
            rc=$?
            printf 'xl pci-assignable-remove %s failed with rc=%s:\n' "$bdf" "$rc" >&2
            sed 's/^/  /' "$tmp" >&2
        fi
    fi
    rm -f "$tmp"

    if pci_assignable_contains "$bdf"; then
        remove_pciback_slot "$bdf"
    fi
    if pci_assignable_contains "$bdf"; then
        printf 'Xen assignable PCI devices after removal attempt:\n' >&2
        xl pci-assignable-list >&2 || true
        die "could not remove $bdf from Xen assignable PCI devices"
    fi
}

load_network_drivers() {
    modprobe e1000e >/dev/null 2>&1 || true
    modprobe e1000 >/dev/null 2>&1 || true
    modprobe igb >/dev/null 2>&1 || true
    modprobe virtio_net >/dev/null 2>&1 || true
}

dom0_network_interface() {
    local bdf

    bdf="$(network_pci_bdf)" || return 1
    find "/sys/bus/pci/devices/$bdf/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null |
        awk '$1 != "lo" && $1 != "xenbr0" && $1 !~ /^vif/ && $1 !~ /^tap/ { print; exit }'
}

bind_network_device_to_dom0() {
    local bdf
    local driver
    local deadline

    bdf="$(network_pci_bdf)" ||
        die "could not find a dom0 network PCI device for bridge mode"
    driver="$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || printf '')")"

    if pci_is_pciback_driver "$driver"; then
        printf 'rebinding %s from %s to native dom0 driver for bridge mode\n' "$bdf" "$driver"
        remove_pci_from_assignable "$bdf"
        if [ -w "/sys/bus/pci/devices/$bdf/driver_override" ]; then
            printf '\n' >"/sys/bus/pci/devices/$bdf/driver_override" || true
        fi
        driver="$(pci_driver "$bdf")"
        if pci_is_pciback_driver "$driver"; then
            printf '%s' "$bdf" >"/sys/bus/pci/devices/$bdf/driver/unbind" || true
        fi
        load_network_drivers
        printf '%s' "$bdf" >/sys/bus/pci/drivers_probe || true
    fi

    deadline=$((SECONDS + 60))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if dom0_network_interface >/dev/null; then
            return
        fi
        sleep 1
        printf '%s' "$bdf" >/sys/bus/pci/drivers_probe || true
    done

    printf 'network PCI device %s driver after reprobe: %s\n' \
        "$bdf" "$(pci_driver "$bdf")" >&2
    printf 'Xen assignable PCI devices after reprobe:\n' >&2
    xl pci-assignable-list >&2 || true
    find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' >&2 || true
    die "could not bind dom0 network PCI device for bridge mode"
}

network_interface_candidates() {
    find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' |
        awk '$1 != "lo" && $1 != "xenbr0" && $1 !~ /^vif/ && $1 !~ /^tap/'
}

fallback_dom0_network_interface() {
    network_interface_candidates | awk 'NR == 1 { print; exit }'
}

dom0_nat_uplink_interface() {
    local iface
    local device
    local deadline

    deadline=$((SECONDS + 60))
    while [ "$SECONDS" -lt "$deadline" ]; do
        while IFS= read -r iface; do
            device="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
            case "$device" in
                *usb*)
                    printf '%s\n' "$iface"
                    return
                    ;;
            esac
        done < <(network_interface_candidates)

        iface="$(fallback_dom0_network_interface || true)"
        if [ -n "$iface" ]; then
            printf '%s\n' "$iface"
            return
        fi
        sleep 1
    done
    return 1
}

configure_nat_network() {
    local iface

    iface="$(dom0_nat_uplink_interface || true)"
    [ -n "$iface" ] || die "could not find a dom0 network interface for nat mode"

    ip link show xenbr0 >/dev/null 2>&1 ||
        ip link add name xenbr0 type bridge
    ip addr flush dev "$iface" || true
    ip link set dev "$iface" master xenbr0
    ip link set dev "$iface" up
    ip link set dev xenbr0 up
}

configure_bridge_network() {
    local iface

    bind_network_device_to_dom0
    iface="$(dom0_network_interface || true)"
    if [ -z "$iface" ]; then
        iface="$(fallback_dom0_network_interface || true)"
    fi
    [ -n "$iface" ] || die "could not find a dom0 network interface"

    ip link show xenbr0 >/dev/null 2>&1 ||
        ip link add name xenbr0 type bridge
    ip addr flush dev "$iface" || true
    ip link set dev "$iface" master xenbr0
    ip link set dev "$iface" up
    ip link set dev xenbr0 up
}

wait_for_target() {
    local deadline

    printf 'waiting for %s root qrexec\n' "$target_name"
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if run_target_root true; then
            return
        fi
        sleep 5
    done
    diagnose_target_startup
    die "$target_name did not become root qrexec-ready"
}

read_root_file() {
    local path="$1"

    [ -e "$path" ] || return
    tail -240 "$path" || true
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

stat_dev_path() {
    stat --printf '%D:%i' -- "$1" 2>/dev/null
}

file_pool_snapshot_device() {
    local origin="$1"
    local source_cow="$2"
    local target_cow="$3"
    local device

    [ -e "$origin" ] && [ -e "$source_cow" ] && [ -e "$target_cow" ] ||
        return 1

    device="/dev/mapper/snapshot-$(stat_dev_path "$origin")"
    device="${device}-$(stat_dev_path "$source_cow")"
    device="${device}-$(stat_dev_path "$target_cow")"
    [ -b "$device" ] || return 1
    printf '%s\n' "$device"
}

file_pool_origin_device() {
    local image="$1"
    local device

    [ -e "$image" ] || return 1
    device="/dev/mapper/origin-$(stat_dev_path "$image")"
    [ -b "$device" ] || return 1
    printf '%s\n' "$device"
}

resolve_target_root_volume_path() {
    local info
    local path
    local pool
    local vid
    local source
    local pool_info
    local driver
    local dir_path
    local candidate
    local origin
    local source_cow
    local target_cow

    info="$(qvm-volume info "$target_name:root" 2>/dev/null || true)"
    path="$(printf '%s\n' "$info" | volume_info_field path)"
    if [ -n "$path" ] && [ -e "$path" ]; then
        printf '%s\n' "$path"
        return 0
    fi

    pool="$(printf '%s\n' "$info" | volume_info_field pool)"
    vid="$(printf '%s\n' "$info" | volume_info_field vid)"
    source="$(printf '%s\n' "$info" | volume_info_field source)"
    [ -n "$pool" ] && [ -n "$vid" ] || return 1

    pool_info="$(qvm-pool info "$pool" 2>/dev/null || true)"
    driver="$(printf '%s\n' "$pool_info" | volume_info_field driver)"
    dir_path="$(printf '%s\n' "$pool_info" | volume_info_field dir_path)"

    case "$driver" in
        file|file-reflink) ;;
        *) return 1 ;;
    esac
    [ -n "$dir_path" ] || return 1

    if [ "$driver" = file ]; then
        if [ -n "$source" ]; then
            origin="$dir_path/$source.img"
            source_cow="$dir_path/$source-cow.img"
            target_cow="$dir_path/$vid-cow.img"
            if path="$(file_pool_snapshot_device \
                    "$origin" "$source_cow" "$target_cow")"; then
                printf '%s\n' "$path"
                return 0
            fi
            printf 'No active Qubes file-pool root snapshot found for %s\n' \
                "$target_name" >&2
            printf '  origin: %s\n  source COW: %s\n  target COW: %s\n' \
                "$origin" "$source_cow" "$target_cow" >&2
        else
            origin="$dir_path/$vid.img"
            if path="$(file_pool_origin_device "$origin")"; then
                printf '%s\n' "$path"
                return 0
            fi
        fi
    fi

    for candidate in \
        "$dir_path/$vid-dirty.img" \
        "$dir_path/$vid-dirty" \
        "$dir_path/$vid.img" \
        "$dir_path/$vid" \
        "$dir_path/$vid-precache.img" \
        "$dir_path/$vid-precache" \
        ${source:+"$dir_path/$source.img"} \
        ${source:+"$dir_path/$source"}
    do
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

debugfs_cat() {
    local image="$1"
    local path="$2"

    printf -- '-- guest root %s --\n' "$path" >&2
    debugfs -R "cat $path" "$image" 2>/dev/null | tail -240 >&2 || true
}

mount_root_logs() {
    local image="$1"
    shift
    local mount_dir
    local log

    command -v mount >/dev/null 2>&1 || {
        printf 'Skipping guest root diagnostics: mount is unavailable\n' >&2
        return
    }

    mount_dir="$(mktemp -d /tmp/qubes-root-diagnostics.XXXXXX)" || return
    if ! mount -o ro,noload,loop "$image" "$mount_dir" 2>/dev/null; then
        printf 'Skipping guest root diagnostics: could not mount %s read-only\n' \
            "$image" >&2
        rmdir "$mount_dir" 2>/dev/null || true
        return
    fi

    for log in "$@"; do
        printf -- '-- guest root %s --\n' "$log" >&2
        read_root_file "$mount_dir/$log" >&2 || true
    done

    umount "$mount_dir" 2>/dev/null || true
    rmdir "$mount_dir" 2>/dev/null || true
}

collect_target_root_diagnostics() {
    local root_path
    local log
    local logs

    root_path="$(resolve_target_root_volume_path)" || {
        printf 'Skipping guest root diagnostics: could not resolve %s root volume path\n' \
            "$target_name" >&2
        return
    }

    printf 'Collecting %s guest root diagnostics from %s\n' \
        "$target_name" "$root_path" >&2
    qvm-volume info "$target_name:root" >&2 || true
    logs='
/var/log/qubes-db.log
/var/log/qubes-sysinit.log
/var/log/qubes-mount-dirs.log
/var/log/qubes-bind-dirs.log
/var/log/qubes-misc-post.log
/var/log/qubes-qrexec-agent.log
/var/log/qubes-qrexec-fork-server.log
/var/log/qubes-network-sysctl.log
/var/log/qubes-network-uplink.log
/var/log/qubes-network.log
/var/log/qubes-feature-advertisement.log
/var/log/qubes-acpid.log
/var/log/shepherd.log
        /var/log/messages'

    if command -v debugfs >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        for log in $logs; do
            debugfs_cat "$root_path" "$log"
        done
    else
        printf 'debugfs unavailable; using read-only loop mount for guest root diagnostics\n' >&2
        # shellcheck disable=SC2086
        mount_root_logs "$root_path" $logs
    fi
}

diagnose_target_startup() {
    local log

    printf '== %s startup diagnostics ==\n' "$target_name" >&2
    qvm-check --running "$target_name" >&2 || true
    qvm-prefs "$target_name" >&2 || true
    qvm-ls --fields name,state,klass,template,netvm,ip,mem --raw-data "$target_name" >&2 || true
    qvm-volume info "$target_name:root" >&2 || true
    qvm-volume info "$target_name:private" >&2 || true
    qvm-volume info "$target_name:volatile" >&2 || true
    if command -v xl >/dev/null 2>&1; then
        xl list >&2 || true
        xl block-list "$target_name" >&2 || true
    fi
    if command -v dmsetup >/dev/null 2>&1; then
        dmsetup ls --tree 2>/dev/null | sed -n '1,120p' >&2 || true
    fi
    ls -l "/var/run/qubes/qrexec.${target_name}" \
        "/var/run/qubes/qubesdb.${target_name}" >&2 || true
    for log in \
        "/var/log/xen/console/guest-${target_name}.log" \
        "/var/log/qubes/qrexec.${target_name}.log" \
        "/var/log/qubes/qubesdb.${target_name}.log"
    do
        if [ -e "$log" ]; then
            printf -- '-- %s --\n' "$log" >&2
            read_root_file "$log" >&2
        fi
    done
    collect_target_root_diagnostics
}

run_target_root() {
    qvm-run --pass-io --no-gui --user root "$target_name" "$1" >/dev/null 2>&1
}

run_target_root_checked() {
    local description="$1"
    local command="$2"
    local output
    local rc

    output="$(mktemp /tmp/qubes-update-target-root.XXXXXX)"
    if qvm-run --pass-io --no-gui --user root "$target_name" "$command" >"$output" 2>&1; then
        rm -f "$output"
        return
    fi
    rc=$?
    printf 'root qrexec command failed for %s (rc=%s):\n' "$description" "$rc" >&2
    sed 's/^/  /' "$output" >&2 || true
    rm -f "$output"
    diagnose_target_startup
    die "$target_name root qrexec command failed: $description"
}

wait_for_target_network() {
    local deadline

    printf 'waiting for %s default route\n' "$target_name"
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if run_target_root 'ip route show default | grep -q .'; then
            return
        fi
        sleep 5
    done
    diagnose_target_startup
    die "$target_name did not get a default route"
}

configure_target_nat_network() {
    run_target_root_checked "configure NAT networking" \
        'set -eu
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}
if command -v modprobe >/dev/null 2>&1; then
    modprobe xen-netfront || true
fi
deadline=$((SECONDS + 120))
iface=
while [ "$SECONDS" -lt "$deadline" ]; do
    iface="$(find /sys/class/net -mindepth 1 -maxdepth 1 -printf "%f\n" |
        awk '"'"'$1 != "lo" { print; exit }'"'"')"
    [ -n "$iface" ] && break
    sleep 1
done
if [ -z "$iface" ]; then
    echo "no non-loopback network interface appeared" >&2
    ls -la /sys/class/net >&2 || true
    exit 1
fi
ip addr flush dev "$iface" || true
ip addr add 10.0.2.15/24 dev "$iface"
ip link set dev "$iface" up
ip route replace default via 10.0.2.2 dev "$iface"
printf "nameserver 10.0.2.3\nnameserver 1.1.1.1\n" >/etc/resolv.conf'
}

wait_for_updates_proxy_service() {
    local deadline

    printf 'waiting for %s qubes.UpdatesProxy service\n' "$target_name"
    deadline=$((SECONDS + 300))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if run_target_root \
            'test -e /etc/qubes-rpc/qubes.UpdatesProxy || test -L /etc/qubes-rpc/qubes.UpdatesProxy'; then
            return
        fi
        sleep 5
    done
    diagnose_target_startup
    die "$target_name does not expose a qubes.UpdatesProxy qrexec service entry"
}

stop_target_if_running() {
    if qvm-check --running "$target_name" >/dev/null 2>&1; then
        qvm-shutdown --wait "$target_name" >/dev/null 2>&1 ||
            qvm-kill "$target_name" >/dev/null 2>&1 ||
            die "could not stop $target_name before reconfiguring it"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -r|--template-rpm)
            require_arg "$@"
            template_rpm=$2
            shift 2
            ;;
        -T|--target)
            require_arg "$@"
            target_name=$2
            shift 2
            ;;
        -t|--template)
            require_arg "$@"
            template_name=$2
            shift 2
            ;;
        -n|--network-mode)
            require_arg "$@"
            network_mode=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

validate_qube_name target "$target_name"
validate_network_mode
if [ -n "$template_name" ]; then
    validate_qube_name template "$template_name"
fi
if [ -n "$template_rpm" ]; then
    [ -r "$template_rpm" ] || die "missing template RPM: $template_rpm"
fi

need lspci
need ip
need qvm-check
need qvm-create
need qvm-pci
need qvm-prefs
need qvm-run
need qvm-service
need qvm-shutdown
need qvm-start
need qvm-template
need qvm-kill
need qubes-prefs
need rpm
need xl

if [ -z "$template_name" ]; then
    [ -n "$template_rpm" ] ||
        die "provide --template or --template-rpm"
    template_name="$(template_from_rpm "$template_rpm")"
fi

if ! qvm-check "$template_name" >/dev/null 2>&1; then
    [ -n "$template_rpm" ] ||
        die "template is absent and no RPM was provided: $template_name"
    qvm-template --yes install --nogpgcheck "$template_rpm"
fi

qvm-check "$template_name" >/dev/null 2>&1 ||
    die "template does not exist after install: $template_name"
[ "$(qvm-prefs "$template_name" klass 2>/dev/null || true)" = "TemplateVM" ] ||
    die "update target base is not a TemplateVM: $template_name"

if ! qvm-check "$target_name" >/dev/null 2>&1; then
    qvm-create --class AppVM --template "$template_name" \
        --label red "$target_name"
fi

stop_target_if_running
qvm-prefs "$target_name" kernelopts 'nopat i8042.nokbd i8042.noaux'
# Nested PCI passthrough can make first boot slower than the dom0 default.
qvm-prefs "$target_name" qrexec_timeout 600
qvm-prefs "$target_name" provides_network True
qvm-prefs "$target_name" netvm ''
qvm-service --enable "$target_name" qubes-network
qvm-service --enable "$target_name" qubes-updates-proxy
qubes-prefs updatevm "$target_name"
resolved_network_mode="$(selected_network_mode)"
printf 'configuring %s update target networking with %s mode\n' \
    "$target_name" "$resolved_network_mode"
case "$resolved_network_mode" in
    pci)
        qvm-prefs "$target_name" virt_mode hvm
        attach_network_device
        ;;
    bridge)
        qvm-prefs "$target_name" virt_mode pvh
        detach_network_device
        configure_bridge_network
        ;;
    nat)
        qvm-prefs "$target_name" virt_mode pvh
        detach_network_device
        configure_nat_network
        ;;
esac

if ! qvm-check --running "$target_name" >/dev/null 2>&1; then
    qvm-start "$target_name"
fi
if [ "$resolved_network_mode" = bridge ] || [ "$resolved_network_mode" = nat ]; then
    xl network-attach "$target_name" bridge=xenbr0
fi
wait_for_target
if [ "$resolved_network_mode" = nat ]; then
    configure_target_nat_network
fi
wait_for_target_network
wait_for_updates_proxy_service

printf 'standard Qubes update target ready: %s using %s (%s networking)\n' \
    "$target_name" "$template_name" "$resolved_network_mode"
