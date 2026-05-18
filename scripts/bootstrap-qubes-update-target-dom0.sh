#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

target_name="${QUBES_UPDATE_TARGET_NAME:-sys-net}"
template_name="${QUBES_UPDATE_TARGET_TEMPLATE:-}"
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

template_from_rpm() {
    local rpm_file="$1"
    local rpm_name

    rpm_name="$(rpm -qp --qf '%{NAME}' "$rpm_file")"
    case "$rpm_name" in
        qubes-template-*) printf '%s\n' "${rpm_name#qubes-template-}" ;;
        *) die "not a qvm-template RPM: $rpm_file" ;;
    esac
}

find_network_pci_device() {
    local pci_id

    pci_id="$(lspci -Dn | awk '$2 == "0200:" || $2 == "0280:" { print $1; exit }')"
    [ -n "$pci_id" ] || return 1
    printf 'dom0:%s\n' "$(printf '%s\n' "$pci_id" | sed 's/^0000://; s/:/_/g')"
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

dom0_network_interface() {
    find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' |
        awk '$1 != "lo" && $1 != "xenbr0" && $1 !~ /^vif/ && $1 !~ /^tap/ { print; exit }'
}

configure_bridge_network() {
    local iface

    iface="$(dom0_network_interface)"
    [ -n "$iface" ] || die "could not find a dom0 network interface"

    ip link show xenbr0 >/dev/null 2>&1 ||
        ip link add name xenbr0 type bridge
    ip link set dev "$iface" master xenbr0
    ip link set dev "$iface" up
    ip link set dev xenbr0 up
}

wait_for_target() {
    local deadline

    printf 'waiting for %s qrexec\n' "$target_name"
    deadline=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if qvm-run --pass-io --no-gui "$target_name" true >/dev/null 2>&1; then
            return
        fi
        sleep 5
    done
    die "$target_name did not become qrexec-ready"
}

run_target_root() {
    qvm-run --pass-io --no-gui --user root "$target_name" "$1" >/dev/null 2>&1
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
    die "$target_name did not get a default route"
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
qvm-prefs "$target_name" virt_mode hvm
qvm-prefs "$target_name" kernelopts 'nopat i8042.nokbd i8042.noaux'
# Nested PCI passthrough can make first boot slower than the dom0 default.
qvm-prefs "$target_name" qrexec_timeout 600
qvm-prefs "$target_name" provides_network True
qvm-prefs "$target_name" netvm ''
qvm-service --enable "$target_name" qubes-updates-proxy
qubes-prefs updatevm "$target_name"
if has_iommu_passthrough; then
    attach_network_device
else
    detach_network_device
    configure_bridge_network
fi

if ! qvm-check --running "$target_name" >/dev/null 2>&1; then
    qvm-start "$target_name"
fi
if ! has_iommu_passthrough; then
    xl network-attach "$target_name" bridge=xenbr0
fi
wait_for_target
wait_for_target_network
wait_for_updates_proxy_service

printf 'standard Qubes update target ready: %s using %s\n' \
    "$target_name" "$template_name"
