#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
variant="normal"
config=""
config_repo_relative=""
output=""
size="20G"
fs_label="guix-root"
mount_dir=""
install_dir=""
build_image=""
build_succeeded=0
external_mount=0
channels_file=""
guix_bin="${GUIX:-guix}"
python_bin="${PYTHON:-python3}"
pull_work_dir=""
source_archive=""
source_commit=""
source_tree=""
source_paths=(
    .guix-channel
    config/channels.scm
    config/guix-channels.scm
    config/substitute-cache/signing-key.pub
    modules
)
PATH="$PATH:/usr/sbin:/sbin"
export PATH

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"
# shellcheck source=scripts/git-tracked-tree.sh
. "$repo_root/scripts/git-tracked-tree.sh"

usage() {
    cat <<'EOF'
Usage: build-native-rootfs.sh [options]

Builds a native Guix System root image for Qubes.

Options:
  --variant NAME    Template variant: normal or minimal. Default: normal
  --config FILE     Guix operating-system file. Default:
                    config/qubes-os-normal.scm or config/qubes-os-minimal.scm.
                    Repository files must be committed; external regular files
                    are copied to a private snapshot before the build.
  --output FILE     Output ext4 image. Default: root.img or root-minimal.img
  --size SIZE       Image size passed to truncate. Default: 20G, matching the
                    current Qubes builder template-root-size default.
  --fs-label LABEL  ext4 filesystem label. Default: guix-root
  --install-dir DIR Install into an already-mounted root filesystem instead of
                    creating an image. Used by Builder v2 content scripts.
  -h, --help        Show this help.

Environment:
  GUIX              Guix command to refresh/use. Default: guix.
  PYTHON            Python command used for secure config snapshots.
                    Default: python3.
EOF
}

ensure_pull_work_dir() {
    if [ -z "$pull_work_dir" ]; then
        pull_work_dir="$(mktemp -d "$repo_root/work.guix-pull.XXXXXX")"
    fi
}

refresh_builder_guix() {
    local current_guix current_guix_dir pull_profile

    [ -r "$channels_file" ] ||
        die "missing build Guix channels file: $channels_file"

    ensure_pull_work_dir
    pull_profile="$pull_work_dir/current"

    printf 'refreshing builder Guix with: %s pull -p %s --allow-downgrades -C %s\n' \
        "$guix_bin" "$pull_profile" "$channels_file" >&2
    "$guix_bin" pull -p "$pull_profile" --allow-downgrades --fallback \
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
    as_root install -m 0644 "$source_tree/config/guix-channels.scm" \
        "$mount_dir/etc/guix/channels.scm"
}

install_channel_sources() {
    local channel_dir="$mount_dir/etc/qubes-guix-channel"
    local channel_commit_file

    [ -r "$source_archive" ] || die "missing immutable Qubes channel archive"

    as_root rm -rf "$channel_dir"
    as_root mkdir -p "$channel_dir"
    # The channel keeps its non-Scheme assets (patches/, files/) inside the
    # module tree (modules/qubes/{patches,files}).  Extract the same immutable
    # commit archive used for the -L build, so the installed fallback can never
    # drift from the source named by its revision marker.
    as_root tar --extract \
        --file "$source_archive" \
        --directory "$channel_dir" \
        --no-same-owner \
        --same-permissions
    channel_commit_file="$pull_work_dir/qubes-channel-commit"
    printf '%s\n' "$source_commit" > "$channel_commit_file"
    as_root install -m 0644 "$channel_commit_file" \
        "$channel_dir/modules/qubes/.qubes-channel-commit"
    rm -f -- "$channel_commit_file"
    as_root find "$channel_dir/modules" -type d -exec chmod 0755 {} +
}

prepare_channel_source_snapshot() {
    ensure_pull_work_dir
    source_archive="$pull_work_dir/qubes-channel-source.tar"
    source_tree="$pull_work_dir/qubes-channel-source"

    # Archive every repository-owned input used below.  All later reads use
    # this tree, so a checkout change during guix pull or system init cannot
    # make the artifact diverge from SOURCE_COMMIT.
    archive_git_commit_tree \
        "$repo_root" "$source_commit" "$source_archive" \
        "${source_paths[@]}"
    mkdir "$source_tree"
    tar --extract \
        --file "$source_archive" \
        --directory "$source_tree" \
        --no-same-owner \
        --same-permissions
    [ -r "$source_tree/.guix-channel" ] ||
        die "immutable Qubes channel snapshot lacks .guix-channel"
    [ -r "$source_tree/config/substitute-cache/signing-key.pub" ] ||
        die "immutable Qubes channel snapshot lacks substitute signing key"
    [ -r "$source_tree/config/channels.scm" ] ||
        die "immutable Qubes channel snapshot lacks build channels"
    [ -r "$source_tree/config/guix-channels.scm" ] ||
        die "immutable Qubes channel snapshot lacks installed channels"
    [ -r "$source_tree/modules/qubes/packages.scm" ] ||
        die "immutable Qubes channel snapshot lacks package definitions"
    [ ! -e "$source_tree/modules/qubes/.qubes-channel-commit" ] ||
        die "Qubes channel revision marker is reserved for the installed snapshot"

    channels_file="$source_tree/config/channels.scm"
    if [ -n "$config_repo_relative" ]; then
        config="$source_tree/$config_repo_relative"
        [ -r "$config" ] ||
            die "immutable Qubes channel snapshot lacks system config: $config_repo_relative"
    fi
}

add_source_path() {
    local existing
    local path="$1"

    for existing in "${source_paths[@]}"; do
        case "$path" in
            "$existing"|"$existing"/*) return 0 ;;
        esac
    done
    source_paths+=("$path")
}

snapshot_external_config() {
    local source="$1"
    local destination="$2"

    "$python_bin" - "$source" "$destination" <<'PY'
import os
import stat
import sys

source, destination = sys.argv[1:]
no_follow = getattr(os, "O_NOFOLLOW", None)
if no_follow is None:
    raise SystemExit("O_NOFOLLOW is unavailable on this platform")

source_fd = -1
destination_fd = -1
try:
    source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | no_follow)
    before = os.fstat(source_fd)
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError("source is not a regular file")

    destination_fd = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | no_follow,
        0o600,
    )
    copied = 0
    while True:
        data = os.read(source_fd, 1024 * 1024)
        if not data:
            break
        view = memoryview(data)
        while view:
            written = os.write(destination_fd, view)
            if written == 0:
                raise RuntimeError("short write while copying config")
            copied += written
            view = view[written:]
    os.fsync(destination_fd)

    after = os.fstat(source_fd)
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_uid",
        "st_gid",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field)
           for field in stable_fields) or copied != before.st_size:
        raise RuntimeError("source changed while it was being copied")
except (OSError, RuntimeError) as error:
    try:
        os.unlink(destination)
    except FileNotFoundError:
        pass
    raise SystemExit(f"cannot snapshot external config: {error}")
finally:
    if destination_fd >= 0:
        os.close(destination_fd)
    if source_fd >= 0:
        os.close(source_fd)
PY
}

prepare_config_input() {
    local config_absolute
    local config_directory

    config_directory="$(cd -- "$(dirname -- "$config")" && pwd -P)" ||
        die "cannot resolve Guix system config directory: $config"
    config_absolute="$config_directory/$(basename -- "$config")"
    [ -f "$config_absolute" ] && [ ! -L "$config_absolute" ] ||
        die "Guix system config must be a regular, non-symlink file: $config"

    case "$config_absolute" in
        "$repo_root"/*)
            config_repo_relative="${config_absolute#"$repo_root"/}"
            git -C "$repo_root" ls-files --error-unmatch -- \
                "$config_repo_relative" >/dev/null 2>&1 ||
                die "repository system config must be tracked by Git: $config_repo_relative"
            add_source_path "$config_repo_relative"
            ;;
        *)
            # An explicit config outside the repository has no channel-commit
            # provenance.  Copy it once before the long-running build and use
            # only that copy for both evaluation and /etc/config.scm.
            ensure_pull_work_dir
            config="$pull_work_dir/external-system-config.scm"
            snapshot_external_config "$config_absolute" "$config" ||
                die "cannot snapshot external Guix system config: $config_absolute"
            printf '%s\n' \
                "using external system config snapshot (outside Qubes channel commit): $config_absolute" >&2
            ;;
    esac
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
    need env
    need git
    need install
    need "$python_bin"
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

    prepare_config_input

    source_commit="$(
        clean_git_commit \
            "$repo_root" \
            "${source_paths[@]}"
    )"
    prepare_channel_source_snapshot
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
    as_root env "QUBES_TEMPLATE_CHANNEL_COMMIT=$source_commit" \
        "$guix_bin" system -L "$source_tree/modules" init --no-bootloader \
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
