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
default_channels_file="$repo_root/config/channels.scm"
guix_bin="${GUIX:-guix}"
pull_work_dir=""
prepared_guix_channel_args=()
git_config_file=""
PATH="$PATH:/usr/sbin:/sbin"
export PATH

usage() {
    cat <<'EOF'
Usage: build-native-rootfs.sh [options]

Builds a native Guix System root image for Qubes.

Options:
  --variant NAME    Template variant: normal or minimal. Default: normal
  --config FILE     Guix operating-system file. Default: ./config.scm.
  --output FILE     Output ext4 image. Default: root.img or root-minimal.img
  --size SIZE       Image size passed to truncate. Default: 20G, matching the
                    current Qubes builder template-root-size default.
  --fs-label LABEL  ext4 filesystem label. Default: guix-root
  --install-dir DIR Install into an already-mounted root filesystem instead of
                    creating an image. Used by Builder v2 content scripts.
  -h, --help        Show this help.

Environment:
  GUIX_TIME_MACHINE Use guix time-machine for the system build. Default: 1.
                    Set to 0/no/false/off to use the host guix command.
  GUIX_CHANNELS_FILE
                    Optional channels.scm passed to guix time-machine -C.
                    Default: config/channels.scm.
  GUIX_BRANCH       Explicit developer override used only when no channels file
                    is available. Release builds should not use this.
  GUIX_PULL_BEFORE_BUILD
                    Run guix pull on the builder and use the pulled Guix
                    for this build only.
                    Default: 1.
  GUIX_CHANNEL_AUTHENTICATION
                    Set to 0/no/false/off to disable Guix channel
                    authentication. Default: 1.
  GUIX_CHANNEL_CHECKOUT
                    Optional path for the cached Guix Git checkout.
  GUIX_PULL_PROFILE
                    Optional profile for the pulled builder Guix. Default is
                    a temporary build-scoped profile.
  GUIX              Guix command to refresh/use. Default: guix.
EOF
}

configure_guix_channel_rewrite() {
    local url="$1"
    local checkout="$2"
    local checkout_real local_url

    ensure_pull_work_dir
    checkout_real="$(cd "$checkout" && pwd -P)"
    local_url="file://$checkout_real"
    git_config_file="$pull_work_dir/gitconfig"

    git config --file "$git_config_file" \
        "url.$local_url.insteadOf" "$url"
    export GIT_CONFIG_GLOBAL="$git_config_file"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

git_fetch_channel() {
    local checkout_dir="$1"
    shift

    GIT_HTTP_VERSION=HTTP/1.1 \
        git -C "$checkout_dir" -c http.version=HTTP/1.1 fetch "$@" ||
        git -C "$checkout_dir" fetch "$@"
}

channel_authentication_enabled() {
    case "${GUIX_CHANNEL_AUTHENTICATION:-1}" in
        0|no|false|off) return 1 ;;
        *) return 0 ;;
    esac
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

guix_system_command=()
guix_channels_file=""

set_guix_system_command() {
    guix_channels_file=""
    case "${GUIX_TIME_MACHINE:-1}" in
        0|no|false|off)
            guix_system_command=("$guix_bin" system)
            ;;
        *)
            if [ "${#prepared_guix_channel_args[@]}" -gt 0 ]; then
                guix_system_command=("$guix_bin" time-machine "${prepared_guix_channel_args[@]}" -- system)
            elif [ -n "${GUIX_CHANNELS_FILE:-}" ]; then
                [ -r "$GUIX_CHANNELS_FILE" ] ||
                    die "GUIX_CHANNELS_FILE is not readable: $GUIX_CHANNELS_FILE"
                guix_channels_file="$GUIX_CHANNELS_FILE"
                guix_system_command=("$guix_bin" time-machine -C "$guix_channels_file" -- system)
            elif [ -r "$default_channels_file" ]; then
                guix_channels_file="$default_channels_file"
                guix_system_command=("$guix_bin" time-machine -C "$guix_channels_file" -- system)
            elif [ -n "${GUIX_BRANCH:-}" ]; then
                guix_system_command=("$guix_bin" time-machine "--branch=$GUIX_BRANCH" -- system)
            else
                die "missing pinned Guix channels file: $default_channels_file; set GUIX_CHANNELS_FILE or explicit developer-only GUIX_BRANCH"
            fi
            ;;
    esac
}

ensure_pull_work_dir() {
    if [ -z "$pull_work_dir" ]; then
        pull_work_dir="$(mktemp -d "$repo_root/work.guix-pull.XXXXXX")"
    fi
}

read_guix_channel_field() {
    local channels_file="$1"
    local field="$2"

    "$guix_bin" repl -q -- /dev/stdin "$channels_file" "$field" <<'GUILE'
(use-modules (guix channels) (ice-9 match) (srfi srfi-1))

(match (cdr (command-line))
  ((file field)
   (define channels
     (call-with-input-file file
       (lambda (port) (eval (read port) (current-module)))))
   (define channel
     (or (find (lambda (channel) (eq? 'guix (channel-name channel)))
               channels)
         (car channels)))
   (display
    (match field
      ("url" (channel-url channel))
      ("branch" (or (channel-branch channel) ""))
      ("commit" (or (channel-commit channel) ""))
      (_ (exit 1)))))
  (_ (exit 1)))
GUILE
}

default_guix_channel_checkout() {
    if [ -n "${GUIX_CHANNEL_CHECKOUT:-}" ]; then
        printf '%s\n' "$GUIX_CHANNEL_CHECKOUT"
    elif [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s\n' "$XDG_CACHE_HOME/qubes-template-guix/guix"
    elif [ -n "${HOME:-}" ]; then
        printf '%s\n' "$HOME/.cache/qubes-template-guix/guix"
    else
        printf '%s\n' "/tmp/qubes-template-guix/guix"
    fi
}

prepare_git_backed_channel_args() {
    local channels_file="$1"
    local url branch commit checkout_dir
    local authenticate=0

    need git
    url="$(read_guix_channel_field "$channels_file" url)"
    branch="$(read_guix_channel_field "$channels_file" branch 2>/dev/null ||
        printf '%s\n' master)"
    commit="$(read_guix_channel_field "$channels_file" commit 2>/dev/null ||
        true)"

    case "$url" in
        file://*|/*)
            if channel_authentication_enabled; then
                prepared_guix_channel_args=(-C "$channels_file")
                return 0
            fi
            prepared_guix_channel_args=(--no-channel-files "--url=$url")
            prepared_guix_channel_args+=(--disable-authentication)
            [ -z "$branch" ] ||
                prepared_guix_channel_args+=("--branch=$branch")
            [ -z "$commit" ] ||
                prepared_guix_channel_args+=("--commit=$commit")
            return 0
            ;;
    esac

    if channel_authentication_enabled; then
        authenticate=1
    fi

    checkout_dir="$(default_guix_channel_checkout)"
    mkdir -p "$(dirname -- "$checkout_dir")"

    if [ -d "$checkout_dir/.git" ] &&
        [ "$(git -C "$checkout_dir" config --get remote.origin.promisor || true)" = true ]; then
        rm -rf "$checkout_dir"
    fi

    if [ -d "$checkout_dir/.git" ]; then
        git -C "$checkout_dir" remote set-url origin "$url"
    else
        mkdir -p "$checkout_dir"
        git -C "$checkout_dir" init
        git -C "$checkout_dir" remote add origin "$url"
    fi

    if [ "$authenticate" -eq 1 ]; then
        if [ "$(git -C "$checkout_dir" rev-parse --is-shallow-repository)" = true ]; then
            git_fetch_channel "$checkout_dir" --unshallow origin "$branch"
        else
            git_fetch_channel "$checkout_dir" --tags --prune origin "$branch"
        fi
    elif [ -n "$commit" ]; then
        git_fetch_channel "$checkout_dir" --depth=1 origin "$commit"
    else
        git_fetch_channel "$checkout_dir" --depth=1 origin "$branch"
    fi

    if [ -n "$commit" ]; then
        git -C "$checkout_dir" checkout --detach "$commit"
        [ -z "$branch" ] ||
            git -C "$checkout_dir" update-ref "refs/heads/$branch" "$commit"
    elif [ "$authenticate" -eq 1 ]; then
        git -C "$checkout_dir" checkout -B "$branch" "origin/$branch"
    else
        git -C "$checkout_dir" checkout -B "$branch" FETCH_HEAD
    fi

    configure_guix_channel_rewrite "$url" "$checkout_dir"
    if [ "$authenticate" -eq 1 ]; then
        prepared_guix_channel_args=(-C "$channels_file")
        return 0
    fi

    prepared_guix_channel_args=(--no-channel-files "--url=$url")
    prepared_guix_channel_args+=(--disable-authentication)
    [ -z "$branch" ] ||
        prepared_guix_channel_args+=("--branch=$branch")
    [ -z "$commit" ] ||
        prepared_guix_channel_args+=("--commit=$commit")
}

refresh_guix_checkout() {
    local current_guix current_guix_dir pull_channels_file pull_profile
    local pull_args=()

    case "${GUIX_PULL_BEFORE_BUILD:-1}" in
        0|no|false|off)
            return 0
            ;;
    esac

    pull_channels_file="$guix_channels_file"
    if [ -n "$pull_channels_file" ]; then
        prepare_git_backed_channel_args "$pull_channels_file"
        pull_args=("${prepared_guix_channel_args[@]}")
    fi

    if [ -n "${GUIX_PULL_PROFILE:-}" ]; then
        pull_profile="$GUIX_PULL_PROFILE"
    else
        ensure_pull_work_dir
        pull_profile="$pull_work_dir/current"
    fi

    if [ "${#pull_args[@]}" -gt 0 ]; then
        printf 'refreshing builder Guix with: %s pull -p %s --allow-downgrades %s\n' \
            "$guix_bin" "$pull_profile" "${pull_args[*]}" >&2
        "$guix_bin" pull -p "$pull_profile" --allow-downgrades \
            "${pull_args[@]}"
    else
        printf 'refreshing builder Guix with: %s pull -p %s --allow-downgrades\n' \
            "$guix_bin" "$pull_profile" >&2
        "$guix_bin" pull -p "$pull_profile" --allow-downgrades
    fi

    current_guix="$pull_profile/bin/guix"
    if [ -n "$current_guix" ] && [ -x "$current_guix" ]; then
        current_guix_dir="$(dirname -- "$current_guix")"
        PATH="$current_guix_dir:$PATH"
        export PATH
        hash -r
        guix_bin="$current_guix"
        printf 'using refreshed Guix command: %s\n' "$guix_bin" >&2
    else
        printf 'warning: guix pull completed but no refreshed current profile guix was found; continuing with %s\n' "$guix_bin" >&2
    fi
}

write_installed_config() {
    sudo install -m 0644 "$config" "$mount_dir/etc/config.scm"
    printf '%s\n' "$variant" |
        sudo tee "$mount_dir/etc/qubes-guix-template-variant" >/dev/null
    sudo chmod 0644 "$mount_dir/etc/qubes-guix-template-variant"
}

remove_runtime_guix_state() {
    sudo rm -f "$mount_dir/etc/guix/channels.scm"
    sudo rm -f "$mount_dir/root/.config/guix/current"
    sudo rm -f "$mount_dir/home/user/.config/guix/current"
    sudo find "$mount_dir/var/guix/profiles/per-user" \
        -mindepth 2 -maxdepth 2 \
        \( -name 'current-guix' -o -name 'current-guix-*-link' \) \
        -exec rm -f {} + 2>/dev/null || true
}

cleanup() {
    if [ "$external_mount" -eq 0 ] && [ -n "$mount_dir" ] &&
        mountpoint -q "$mount_dir"; then
        sudo umount "$mount_dir"
    fi
    if [ "$external_mount" -eq 0 ] && [ -n "$mount_dir" ] &&
        [ -d "$mount_dir" ]; then
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

case "$variant" in
    normal)
        : "${config:=$repo_root/config.scm}"
        : "${output:=$repo_root/root.img}"
        ;;
    minimal)
        : "${config:=$repo_root/config.scm}"
        : "${output:=$repo_root/root-minimal.img}"
        ;;
    *)
        die "unsupported variant: $variant"
        ;;
esac

need guix
need sudo
need mountpoint
if [ -z "$install_dir" ]; then
    need mkfs.ext4
fi
set_guix_system_command

[ -r "$config" ] || die "missing Guix system config: $config"

if [ -n "$install_dir" ]; then
    mount_dir="$install_dir"
    external_mount=1
    [ -d "$mount_dir" ] || die "install dir is not a directory: $mount_dir"
    mountpoint -q "$mount_dir" ||
        die "install dir is not a mount point: $mount_dir"
fi

refresh_guix_checkout
set_guix_system_command

if [ -z "$install_dir" ]; then
    mkdir -p "$(dirname -- "$output")"
    build_image="$(mktemp "$(dirname -- "$output")/.build-native-rootfs.XXXXXX.img")"
    truncate -s "$size" "$build_image"
    mkfs.ext4 -F -L "$fs_label" "$build_image"

    mount_dir="$(mktemp -d "$repo_root/mnt.XXXXXX")"
    sudo mount -o loop "$build_image" "$mount_dir"
fi

sudo env "QUBES_GUIX_TEMPLATE_VARIANT=$variant" \
    "${guix_system_command[@]}" init --no-bootloader "$config" "$mount_dir"
sudo test -x "$mount_dir/var/guix/profiles/system/profile/bin/sh" ||
    die "Guix system profile does not provide bin/sh"
sudo test -x "$mount_dir/var/guix/profiles/system/profile/bin/guile" ||
    die "Guix system profile does not provide bin/guile"
remove_runtime_guix_state
write_installed_config

sudo mkdir -p "$mount_dir/sbin" "$mount_dir/bin" "$mount_dir/lib/modules" "$mount_dir/var/run" "$mount_dir/run/qubes" "$mount_dir/run/qubes-service"
if ! sudo test "$mount_dir/var/run" -ef "$mount_dir/run" 2>/dev/null; then
    sudo rm -rf "$mount_dir/var/run/qubes" "$mount_dir/var/run/qubes-service"
    sudo rm -f "$mount_dir/var/run/qubes-service-environment"
    sudo ln -sfn /run/qubes "$mount_dir/var/run/qubes"
    sudo ln -sfn /run/qubes-service "$mount_dir/var/run/qubes-service"
    sudo ln -sfn /run/qubes-service-environment "$mount_dir/var/run/qubes-service-environment"
fi
sudo ln -sfn /var/guix/profiles/system/profile/bin/sh "$mount_dir/bin/sh"
sudo ln -sfn /var/guix/profiles/system/profile/bin/bash "$mount_dir/bin/bash"
sudo ln -sfn /var/guix/profiles/system/profile/sbin/halt "$mount_dir/sbin/poweroff"
sudo tee "$mount_dir/sbin/init" >/dev/null <<'EOF'
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
sudo chmod 0755 "$mount_dir/sbin/init"
build_succeeded=1

if [ "$external_mount" -eq 0 ]; then
    sudo umount "$mount_dir"
    rmdir "$mount_dir"
    mount_dir=""
    mv -f "$build_image" "$output"
    printf 'native Guix root image written to %s\n' "$output"
else
    printf 'native Guix system installed into %s\n' "$mount_dir"
fi
