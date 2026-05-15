#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail

template_name="${TEMPLATE_NAME:-guix-native-test}"
appvm_name="${APPVM_NAME:-guix-native-test-app}"
root_size="${ROOT_SIZE:-20G}"
root_device="${ROOT_DEVICE:-}"
log_file="${LOG_FILE:-/root/guix-template-test.log}"
status_file="${STATUS_FILE:-/root/guix-template-test.status}"
fallback_image="${FALLBACK_IMAGE:-/var/tmp/guix-native-root.img}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec > >(tee -a "$log_file") 2>&1

find_root_device() {
    if [ -n "$root_device" ] && [ -e "$root_device" ]; then
        printf '%s\n' "$root_device"
        return 0
    fi

    local dev
    for dev in /dev/disk/by-id/*guixroot*; do
        if [ -e "$dev" ]; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 1
}

wait_for_root_device() {
    local attempt
    for attempt in $(seq 1 60); do
        if find_root_device; then
            return 0
        fi
        printf 'waiting for attached Guix root device (%s/60)\n' "$attempt"
        lsblk || true
        ls -l /dev/disk/by-id || true
        sleep 2
    done
    return 1
}

wait_for_qubesd() {
    local attempt
    for attempt in $(seq 1 120); do
        if qvm-ls --raw-list >/dev/null 2>&1; then
            return 0
        fi
        printf 'waiting for qubesd/qvm-ls (%s/120)\n' "$attempt"
        systemctl is-active qubesd.service qubes-core.service || true
        sleep 5
    done
    return 1
}

vm_exists() {
    qvm-ls --raw-list | grep -Fxq "$1"
}

remove_vm_if_exists() {
    local name="$1"
    if vm_exists "$name"; then
        qvm-shutdown --wait "$name" >/dev/null 2>&1 || true
        qvm-remove --force "$name" || true
    else
        case "$name" in
            "$template_name")
                rm -rf -- "/var/lib/qubes/vm-templates/$name"
                ;;
            "$appvm_name")
                rm -rf -- "/var/lib/qubes/appvms/$name"
                ;;
        esac
    fi
}

ensure_qubes_defaults() {
    if command -v qubes-prefs >/dev/null 2>&1 && [ -z "$(qubes-prefs default_kernel 2>/dev/null || true)" ]; then
        local default_kernel
        default_kernel="$(find /var/lib/qubes/vm-kernels -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
        [ -n "$default_kernel" ]
        qubes-prefs default_kernel "$default_kernel"
    fi
}

import_template() {
    local image="$1"
    if "$script_dir/import-native-rootfs-dom0.sh" \
        --image "$image" \
        --name "$template_name" \
        --root-size "$root_size"; then
        return 0
    fi

    printf 'direct qvm-volume import from %s failed; retrying with a dom0 copy\n' "$image"
    remove_vm_if_exists "$template_name"
    rm -f "$fallback_image"
    dd if="$image" of="$fallback_image" bs=16M status=progress conv=fsync
    "$script_dir/import-native-rootfs-dom0.sh" \
        --image "$fallback_image" \
        --name "$template_name" \
        --root-size "$root_size"
}

run_test() {
    set -euo pipefail

    systemctl disable guix-template-test.service >/dev/null 2>&1 || true
    date -Is
    uname -a

    local image
    image="$(wait_for_root_device)"
    printf 'using Guix root device: %s\n' "$image"

    wait_for_qubesd
    ensure_qubes_defaults
    qvm-ls

    remove_vm_if_exists "$appvm_name"
    remove_vm_if_exists "$template_name"

    import_template "$image"
    "$script_dir/test-native-guix-template-dom0.sh" \
        --template "$template_name" \
        --appvm "$appvm_name" \
        --keep-appvm
}

rc=0
run_test || rc=$?

if [ "$rc" -eq 0 ]; then
    printf 'PASS native Guix TemplateVM smoke test\n'
else
    printf 'FAIL native Guix TemplateVM smoke test: rc=%s\n' "$rc"
fi
printf '%s\n' "$rc" > "$status_file"
sync
sleep 10
systemctl poweroff || true
exit "$rc"
