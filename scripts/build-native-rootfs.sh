#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
variant="normal"
config=""
output=""
size="20G"
fs_label="guix-root"
mount_dir=""
install_dir=""
build_image=""
build_succeeded=0
external_mount=0
channels_file="$repo_root/config/channels.scm"
guix_bin="${GUIX:-guix}"
pull_work_dir=""
rendered_config=""
PATH="$PATH:/usr/sbin:/sbin"
export PATH

usage() {
    cat <<'EOF'
Usage: build-native-rootfs.sh [options]

Builds a native Guix System root image for Qubes.

Options:
  --variant NAME    Template variant: normal or minimal. Default: normal
  --config FILE     Guix operating-system file. Default: rendered from
                    config/qubes-os-normal.scm or config/qubes-os-minimal.scm.
  --output FILE     Output ext4 image. Default: root.img or root-minimal.img
  --size SIZE       Image size passed to truncate. Default: 20G, matching the
                    current Qubes builder template-root-size default.
  --fs-label LABEL  ext4 filesystem label. Default: guix-root
  --install-dir DIR Install into an already-mounted root filesystem instead of
                    creating an image. Used by Builder v2 content scripts.
  -h, --help        Show this help.

Environment:
  GUIX              Guix command to refresh/use. Default: guix.
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

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_pull_work_dir() {
    if [ -z "$pull_work_dir" ]; then
        pull_work_dir="$(mktemp -d "$repo_root/work.guix-pull.XXXXXX")"
    fi
}

refresh_builder_guix() {
    local current_guix current_guix_dir pull_profile

    [ -r "$channels_file" ] ||
        die "missing pinned Guix channels file: $channels_file"

    ensure_pull_work_dir
    pull_profile="$pull_work_dir/current"

    printf 'refreshing builder Guix with: %s pull -p %s --allow-downgrades -C %s\n' \
        "$guix_bin" "$pull_profile" "$channels_file" >&2
    "$guix_bin" pull -p "$pull_profile" --allow-downgrades \
        -C "$channels_file"

    current_guix="$pull_profile/bin/guix"
    [ -x "$current_guix" ] ||
        die "guix pull did not produce an executable Guix command: $current_guix"

    current_guix_dir="$(dirname -- "$current_guix")"
    PATH="$current_guix_dir:$PATH"
    export PATH
    hash -r
    guix_bin="$current_guix"
    printf 'using refreshed Guix command: %s\n' "$guix_bin" >&2
}

write_installed_config() {
    as_root install -m 0644 "$config" "$mount_dir/etc/config.scm"
    write_guix_channels
}

write_guix_channels() {
    as_root mkdir -p "$mount_dir/etc/guix"
    as_root install -m 0644 "$repo_root/config/guix-channels.scm" \
        "$mount_dir/etc/guix/channels.scm"
}

install_channel_sources() {
    local channel_dir="$mount_dir/etc/qubes-guix-channel"

    as_root rm -rf "$channel_dir"
    as_root mkdir -p "$channel_dir"
    as_root install -m 0644 "$repo_root/.guix-channel" "$channel_dir/.guix-channel"
    # The channel keeps its non-Scheme assets (patches/, files/) inside the
    # module tree (modules/qubes/{patches,files}), so copying modules/ ships
    # them too.  This keeps every local-file reference inside the channel root
    # so it resolves identically under "guix build -L", "guix pull", and an
    # offline "guix system reconfigure" in the installed image.
    as_root cp -a "$repo_root/modules" "$channel_dir/modules"
    as_root chmod -R u+rwX,go+rX "$channel_dir/modules"
}

remove_runtime_guix_state() {
    as_root rm -f "$mount_dir/root/.config/guix/current"
    as_root rm -f "$mount_dir/home/user/.config/guix/current"
    as_root find "$mount_dir/var/guix/profiles/per-user" \
        -mindepth 2 -maxdepth 2 \
        \( -name 'current-guix' -o -name 'current-guix-*-link' \) \
        -exec rm -f {} + 2>/dev/null || true
}

own_mount_dir() {
    [ "$external_mount" -eq 0 ] && [ -n "$mount_dir" ]
}

cleanup() {
    if own_mount_dir && mountpoint -q "$mount_dir"; then
        as_root umount "$mount_dir"
    fi
    if own_mount_dir && [ -d "$mount_dir" ]; then
        rmdir "$mount_dir"
    fi
    if [ "$build_succeeded" -eq 0 ] && [ -n "$build_image" ] && [ -e "$build_image" ]; then
        rm -f "$build_image"
    fi
    if [ -n "$pull_work_dir" ] && [ -d "$pull_work_dir" ]; then
        rm -rf "$pull_work_dir"
    fi
    if [ -n "$rendered_config" ] && [ -e "$rendered_config" ]; then
        rm -f "$rendered_config"
    fi
}
trap cleanup EXIT

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --variant)
                require_arg "$@"
                variant="$2"
                shift 2
                ;;
            --config)
                require_arg "$@"
                config="$2"
                shift 2
                ;;
            --output)
                require_arg "$@"
                output="$2"
                shift 2
                ;;
            --size)
                require_arg "$@"
                size="$2"
                shift 2
                ;;
            --fs-label)
                require_arg "$@"
                fs_label="$2"
                shift 2
                ;;
            --install-dir)
                require_arg "$@"
                install_dir="$2"
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

resolve_defaults() {
    variant="$("$repo_root/scripts/template-variant.sh" "$variant" variant)"

    if [ -z "$config" ]; then
        case "$variant" in
            normal) config="$repo_root/config/qubes-os-normal.scm" ;;
            minimal) config="$repo_root/config/qubes-os-minimal.scm" ;;
            *) die "unsupported variant: $variant" ;;
        esac
    fi

    case "$variant" in
        normal) : "${output:=$repo_root/root.img}" ;;
        minimal) : "${output:=$repo_root/root-minimal.img}" ;;
    esac
}

check_requirements() {
    need "$guix_bin"
    if [ "$(id -u)" -ne 0 ]; then
        need sudo
    fi
    need mountpoint
    if [ -z "$install_dir" ]; then
        need mkfs.ext4
    fi
    [ -r "$config" ] || die "missing Guix system config: $config"
    [ -r "$repo_root/.guix-channel" ] ||
        die "missing Guix channel metadata: $repo_root/.guix-channel"
    [ -r "$repo_root/modules/qubes/packages.scm" ] ||
        die "missing Qubes Guix channel module: $repo_root/modules/qubes/packages.scm"
    [ -r "$repo_root/config/guix-channels.scm" ] ||
        die "missing installed channels file: $repo_root/config/guix-channels.scm"
}

validate_install_dir() {
    [ -n "$install_dir" ] || return 0

    [ -d "$install_dir" ] || die "install dir is not a directory: $install_dir"
    mountpoint -q "$install_dir" ||
        die "install dir is not a mount point: $install_dir"
}

prepare_target_root() {
    if [ -n "$install_dir" ]; then
        mount_dir="$install_dir"
        external_mount=1
        return 0
    fi

    mkdir -p "$(dirname -- "$output")"
    build_image="$(mktemp "$(dirname -- "$output")/.build-native-rootfs.XXXXXX.img")"
    truncate -s "$size" "$build_image"
    mkfs.ext4 -F -L "$fs_label" "$build_image"

    mount_dir="$(mktemp -d "$repo_root/mnt.XXXXXX")"
    as_root mount -o loop "$build_image" "$mount_dir"
}

initialize_guix_system() {
    as_root "$guix_bin" system -L "$repo_root/modules" init --no-bootloader \
        "$config" "$mount_dir"
    as_root test -x "$mount_dir/var/guix/profiles/system/profile/bin/sh" ||
        die "Guix system profile does not provide bin/sh"
    as_root test -x "$mount_dir/var/guix/profiles/system/profile/bin/guile" ||
        die "Guix system profile does not provide bin/guile"
    remove_runtime_guix_state
    install_channel_sources
    write_installed_config
}

write_init_wrapper() {
    as_root tee "$mount_dir/sbin/init" >/dev/null <<'EOF'
#!/var/guix/profiles/system/profile/bin/sh
profile=/var/guix/profiles/system/profile
PATH="$profile/bin:$profile/sbin${PATH:+:$PATH}"
GUIX_NEW_SYSTEM=/var/guix/profiles/system
export PATH
export GUIX_NEW_SYSTEM

"$profile/bin/mkdir" -p /proc /sys /dev /run/qubes /run/qubes-service /var/run
[ -e /proc/cmdline ] || "$profile/bin/mount" -n -t proc proc /proc || true
[ -e /sys/kernel ] || "$profile/bin/mount" -n -t sysfs sysfs /sys || true
[ -e /dev/null ] || "$profile/bin/mount" -n -t devtmpfs devtmpfs /dev || true
if ! "$profile/bin/test" /var/run -ef /run 2>/dev/null; then
    "$profile/bin/rm" -rf /var/run/qubes /var/run/qubes-service
    "$profile/bin/rm" -f /var/run/qubes-service-environment
    "$profile/bin/ln" -s /run/qubes /var/run/qubes
    "$profile/bin/ln" -s /run/qubes-service /var/run/qubes-service
    "$profile/bin/ln" -s /run/qubes-service-environment /var/run/qubes-service-environment
fi

exec "$profile/bin/guile" --no-auto-compile /var/guix/profiles/system/boot "$@"
EOF
    as_root chmod 0755 "$mount_dir/sbin/init"
}

install_compatibility_paths() {
    as_root mkdir -p \
        "$mount_dir/bin" \
        "$mount_dir/lib/modules" \
        "$mount_dir/run/qubes" \
        "$mount_dir/run/qubes-service" \
        "$mount_dir/sbin" \
        "$mount_dir/var/run"
    if ! as_root test "$mount_dir/var/run" -ef "$mount_dir/run" 2>/dev/null; then
        as_root rm -rf "$mount_dir/var/run/qubes" "$mount_dir/var/run/qubes-service"
        as_root rm -f "$mount_dir/var/run/qubes-service-environment"
        as_root ln -sfn /run/qubes "$mount_dir/var/run/qubes"
        as_root ln -sfn /run/qubes-service "$mount_dir/var/run/qubes-service"
        as_root ln -sfn /run/qubes-service-environment "$mount_dir/var/run/qubes-service-environment"
    fi
    as_root ln -sfn /var/guix/profiles/system/profile/bin/sh "$mount_dir/bin/sh"
    as_root ln -sfn /var/guix/profiles/system/profile/bin/bash "$mount_dir/bin/bash"
    as_root ln -sfn /var/guix/profiles/system/profile/sbin/halt "$mount_dir/sbin/poweroff"
    write_init_wrapper
}

finish_build() {
    if [ "$external_mount" -eq 0 ]; then
        as_root umount "$mount_dir"
        rmdir "$mount_dir"
        mount_dir=""
        mv -f "$build_image" "$output"
        build_succeeded=1
        printf 'native Guix root image written to %s\n' "$output"
    else
        build_succeeded=1
        printf 'native Guix system installed into %s\n' "$mount_dir"
    fi
}

main() {
    parse_args "$@"
    resolve_defaults
    check_requirements
    validate_install_dir
    refresh_builder_guix
    prepare_target_root
    initialize_guix_system
    install_compatibility_paths
    finish_build
}

main "$@"
