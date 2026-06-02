#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="$repo_root/root.img"
variant=""
fs_label="guix-root"
expected_commands=()
expected_desktops=()
mount_dir=""
profile=""
PATH="/usr/sbin:/sbin:$PATH"
export PATH

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: inspect-native-rootfs.sh [options]

Mount a native Guix Qubes root image read-only and verify expected Qubes VM
agent payload paths inside the image's Guix system profile.

Options:
  --image FILE          Root image to inspect. Default: root.img
  --variant NAME        Load normal/minimal command and appmenu expectations.
  --fs-label NAME       Expected ext4 filesystem label. Default: guix-root
  -h, --help            Show this help.
EOF
}

desktop_entry_value() {
    local desktop_file="$1"
    local key="$2"

    awk -F= -v key="$key" \
        '$1 == key { value = substr($0, index($0, "=") + 1); print value; exit }' \
        "$desktop_file"
}

icon_file_exists() {
    local icon_name="$1"
    local root name found
    local names=()
    local roots=(
        "$profile/share/icons"
        "$profile/share/pixmaps"
    )

    if [[ "$icon_name" = /* ]]; then
        [ -e "$mount_dir$icon_name" ]
        return
    fi

    case "$icon_name" in
        *.png|*.svg|*.xpm|*.jpg|*.jpeg|*.ico)
            names=("$icon_name")
            ;;
        *)
            names=(
                "$icon_name.png"
                "$icon_name.svg"
                "$icon_name-symbolic.svg"
                "$icon_name.xpm"
                "$icon_name.jpg"
                "$icon_name.jpeg"
            )
            ;;
    esac

    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        for name in "${names[@]}"; do
            found="$(find -L "$root" -type f -name "$name" -print -quit)"
            [ -n "$found" ] && return 0
        done
    done

    return 1
}

cleanup() {
    if [ -n "$mount_dir" ] && mountpoint -q "$mount_dir"; then
        as_root umount "$mount_dir"
    fi
    if [ -n "$mount_dir" ] && [ -d "$mount_dir" ]; then
        rmdir "$mount_dir"
    fi
}
trap cleanup EXIT

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --image)
                require_arg "$@"
                image="$2"
                shift 2
                ;;
            --variant)
                require_arg "$@"
                variant="$2"
                shift 2
                ;;
            --fs-label)
                require_arg "$@"
                fs_label="$2"
                shift 2
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

load_variant_expectations() {
    [ -n "$variant" ] || return 0

    variant="$("$repo_root/scripts/template-variant.sh" "$variant" variant)"
    mapfile -t expected_commands < \
        <("$repo_root/scripts/template-variant.sh" "$variant" commands)
    mapfile -t expected_desktops < \
        <("$repo_root/scripts/template-appmenus.sh" "$variant")
}

check_requirements() {
    need awk
    need blkid
    need chroot
    need find
    need head
    need mount
    need mountpoint
    need readlink
    if [ "$(id -u)" -ne 0 ]; then
        need sudo
    fi

    [ -r "$image" ] || die "missing readable image: $image"
}

verify_filesystem_label() {
    local actual_label

    actual_label="$(as_root blkid -s LABEL -o value "$image")"
    [ "$actual_label" = "$fs_label" ] ||
        die "expected filesystem label '$fs_label', got '$actual_label'"
}

mount_image() {
    mount_dir="$(mktemp -d "$repo_root/inspect.XXXXXX")"
    as_root mount -o loop,ro "$image" "$mount_dir"
}

resolve_system_profile() {
    local system_link system_profile system_dir

    system_profile="$mount_dir/var/guix/profiles/system"
    [ -e "$system_profile" ] ||
        die "missing /var/guix/profiles/system inside image; the root image is not a completed Guix System"

    if [ -L "$system_profile" ]; then
        system_link="$(readlink "$system_profile")"
        case "$system_link" in
            /*) system_dir="$mount_dir$system_link" ;;
            *) system_dir="$mount_dir/var/guix/profiles/$system_link" ;;
        esac
    else
        system_dir="$system_profile"
    fi

    profile="$system_dir/profile"
    [ -d "$profile" ] || die "missing system profile inside image: $profile"
}

verify_boot_compatibility() {
    [ -x "$mount_dir/sbin/init" ] ||
        die "missing executable /sbin/init compatibility wrapper"
    [ "$(head -n 1 "$mount_dir/sbin/init")" = "#!/var/guix/profiles/system/profile/bin/sh" ] ||
        die "/sbin/init wrapper does not use the Guix profile shell"
    as_root chroot "$mount_dir" /bin/sh -c 'test -x /var/guix/profiles/system/profile/bin/guile' ||
        die "missing or unusable /bin/sh compatibility symlink"
    as_root chroot "$mount_dir" /bin/sh -c 'PATH=/var/guix/profiles/system/profile/bin:/var/guix/profiles/system/profile/sbin qvm-features-request --help' >/dev/null ||
        die "qvm-features-request cannot import its Python dependencies inside the guest root"
    [ -d "$mount_dir/lib/modules" ] ||
        die "missing /lib/modules mount point for Qubes initramfs"
    as_root chroot "$mount_dir" /bin/sh -c 'test -x /sbin/poweroff' ||
        die "missing /sbin/poweroff compatibility command for Qubes shutdown"
}

verify_profile_payload() {
    local pattern
    local required_patterns=(
        bin/qubesdb-daemon
        bin/qrexec-client-vm
        bin/qvm-features-request
        bin/python3
        sbin/acpid
        sbin/blockdev
        bin/qubes-gui
        bin/qubes-gui-runuser
        lib/qubes/qrexec-agent
        lib/qubes/qubes-trigger-sync-appmenus.sh
        lib/qubes/qubes-gui-agent-pre.sh
        lib/qubes/qfile-agent
        lib/qubes/qfile-unpacker
        etc/qubes/post-install.d/10-qubes-core-agent-features.sh
        etc/qubes/post-install.d/10-qubes-core-agent-appmenus.sh
        etc/qubes/post-install.d/90-qubes-core-agent.sh
        etc/qubes-rpc/qubes.VMExec
        etc/qubes-rpc/qubes.Filecopy
        etc/qubes-rpc/qubes.WaitForSession
        bin/qubes-vmexec
        'lib/python*/site-packages/qubesagent/vmexec.py'
        'lib/python*/site-packages/qrexec/client.py'
        share/qubes/marker-vm
    )

    for pattern in "${required_patterns[@]}"; do
        compgen -G "$profile/$pattern" >/dev/null ||
            die "missing expected profile path: $pattern"
    done

    [ ! -e "$profile/usr/bin/qrexec-client-vm" ] ||
        die "qrexec-client-vm is still under profile/usr/bin"
    [ ! -d "$profile/gnu/store" ] ||
        die "nested gnu/store exists under the profile output"
}

verify_installed_channel_sources() {
    [ -r "$mount_dir/etc/qubes-guix-channel/.guix-channel" ] ||
        die "missing installed Qubes Guix channel metadata"
    [ -r "$mount_dir/etc/qubes-guix-channel/modules/qubes/packages.scm" ] ||
        die "missing installed Qubes Guix channel module"
    [ -r "$mount_dir/etc/qubes-guix-channel/modules/qubes/files/qvm-template-repo-query-guix.py" ] ||
        die "missing installed Qubes Guix channel files asset"
    [ -d "$mount_dir/etc/qubes-guix-channel/modules/qubes/patches" ] ||
        die "missing installed Qubes Guix channel patches"
}

verify_expected_commands() {
    local command_name

    for command_name in "${expected_commands[@]}"; do
        as_root chroot "$mount_dir" /bin/sh -c 'PATH=/var/guix/profiles/system/profile/bin:/var/guix/profiles/system/profile/sbin command -v "$1"' sh "$command_name" >/dev/null ||
            die "missing expected guest command: $command_name"
    done
}

verify_expected_desktops() {
    local desktop_file desktop_path icon_name

    for desktop_file in "${expected_desktops[@]}"; do
        desktop_path="$profile/share/applications/$desktop_file"
        as_root chroot "$mount_dir" /bin/sh -c 'test -f "/var/guix/profiles/system/profile/share/applications/$1"' sh "$desktop_file" ||
            die "missing expected desktop file: $desktop_file"
        icon_name="$(desktop_entry_value "$desktop_path" Icon)"
        [ -n "$icon_name" ] ||
            die "desktop file has no icon: $desktop_file"
        icon_file_exists "$icon_name" ||
            die "desktop icon is not present in the guest profile: $desktop_file Icon=$icon_name"
    done
}

check_ext4_cleanly() {
    command -v e2fsck >/dev/null 2>&1 || return 0

    as_root umount "$mount_dir"
    e2fsck -fn "$image" >/dev/null
    as_root mount -o loop,ro "$image" "$mount_dir"
}

main() {
    parse_args "$@"
    load_variant_expectations
    check_requirements
    verify_filesystem_label
    mount_image
    resolve_system_profile
    verify_boot_compatibility
    verify_profile_payload
    verify_installed_channel_sources
    verify_expected_commands
    verify_expected_desktops
    check_ext4_cleanly
    printf 'native root image inspection passed: %s\n' "$image"
}

main "$@"
