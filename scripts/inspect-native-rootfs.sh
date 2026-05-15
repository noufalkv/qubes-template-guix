#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="$repo_root/root.img"
fs_label="guix-root"
expected_commands=()
expected_desktops=()
PATH="/usr/sbin:/sbin:$PATH"
export PATH

usage() {
    cat <<'EOF'
Usage: inspect-native-rootfs.sh [options]

Mount a native Guix Qubes root image read-only and verify expected Qubes VM
agent payload paths inside the image's Guix system profile.

Options:
  --image FILE          Root image to inspect. Default: root.img
  --fs-label NAME       Expected ext4 filesystem label. Default: guix-root
  --expect-command CMD  Require CMD to resolve in the guest profile.
  --expect-desktop ID   Require a desktop-file ID under /usr/share/applications.
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

run_blkid() {
    if command -v blkid >/dev/null 2>&1; then
        blkid "$@"
    else
        sudo blkid "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --image)
            image="${2:-}"
            shift 2
            ;;
        --fs-label)
            fs_label="${2:-}"
            shift 2
            ;;
        --expect-command)
            expected_commands+=("${2:-}")
            shift 2
            ;;
        --expect-desktop)
            expected_desktops+=("${2:-}")
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

need mountpoint
need sudo

[ -r "$image" ] || die "missing readable image: $image"

actual_label="$(run_blkid -s LABEL -o value "$image")"
[ "$actual_label" = "$fs_label" ] ||
    die "expected filesystem label '$fs_label', got '$actual_label'"

mount_dir="$(mktemp -d "$repo_root/inspect.XXXXXX")"
cleanup() {
    if mountpoint -q "$mount_dir"; then
        sudo umount "$mount_dir"
    fi
    rmdir "$mount_dir"
}
trap cleanup EXIT

sudo mount -o loop,ro "$image" "$mount_dir"

system_profile="$mount_dir/var/guix/profiles/system"
[ -e "$system_profile" ] ||
    die "missing /var/guix/profiles/system inside image; the root image is not a completed Guix System"

if [ -L "$system_profile" ]; then
    system_link="$(readlink "$system_profile")"
    case "$system_link" in
        /*)
            system_dir="$mount_dir$system_link"
            ;;
        *)
            system_dir="$mount_dir/var/guix/profiles/$system_link"
            ;;
    esac
else
    system_dir="$system_profile"
fi
profile="$system_dir/profile"

[ -d "$profile" ] || die "missing system profile inside image: $profile"
[ -x "$mount_dir/sbin/init" ] || die "missing executable /sbin/init compatibility wrapper"
[ "$(head -n 1 "$mount_dir/sbin/init")" = "#!/var/guix/profiles/system/profile/bin/sh" ] ||
    die "/sbin/init wrapper does not use the Guix profile shell"
grep -Fq 'mount" -n -t proc proc /proc' "$mount_dir/sbin/init" ||
    die "/sbin/init wrapper does not mount /proc before Guix boot"
grep -Fq 'GUIX_NEW_SYSTEM=/var/guix/profiles/system' "$mount_dir/sbin/init" ||
    die "/sbin/init wrapper does not set GUIX_NEW_SYSTEM"
sudo chroot "$mount_dir" /bin/sh -c 'test -x /var/guix/profiles/system/profile/bin/guile' ||
    die "missing or unusable /bin/sh compatibility symlink"
sudo chroot "$mount_dir" /bin/sh -c 'PATH=/var/guix/profiles/system/profile/bin:/var/guix/profiles/system/profile/sbin qvm-features-request --help' >/dev/null ||
    die "qvm-features-request cannot import its Python dependencies inside the guest root"
[ -d "$mount_dir/lib/modules" ] || die "missing /lib/modules mount point for Qubes initramfs"
sudo chroot "$mount_dir" /bin/sh -c 'test -x /sbin/poweroff' ||
    die "missing /sbin/poweroff compatibility command for Qubes shutdown"

required_patterns=(
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

for command_name in "${expected_commands[@]}"; do
    sudo chroot "$mount_dir" /bin/sh -c 'PATH=/var/guix/profiles/system/profile/bin:/var/guix/profiles/system/profile/sbin command -v "$1"' sh "$command_name" >/dev/null ||
        die "missing expected guest command: $command_name"
done

for desktop_file in "${expected_desktops[@]}"; do
    sudo chroot "$mount_dir" /bin/sh -c 'test -f "/var/guix/profiles/system/profile/share/applications/$1"' sh "$desktop_file" ||
        die "missing expected desktop file: $desktop_file"
done

if command -v e2fsck >/dev/null 2>&1; then
    sudo umount "$mount_dir"
    e2fsck -fn "$image" >/dev/null
    sudo mount -o loop,ro "$image" "$mount_dir"
fi

printf 'native root image inspection passed: %s\n' "$image"
