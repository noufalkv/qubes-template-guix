#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

qubes_source_root="${QUBES_SOURCE_ROOT:-/opt/qubes-src}"
workdir="${WORKDIR:-$HOME/guix}"
guix_installer_url="${GUIX_INSTALLER_URL:-https://guix.gnu.org/guix-install.sh}"
guix_installer_fallback_url="${GUIX_INSTALLER_FALLBACK_URL:-https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh}"

repos=(
    qubes-core-vchan-xen
    qubes-linux-utils
    qubes-core-qubesdb
    qubes-core-qrexec
    qubes-core-agent-linux
    qubes-gui-common
    qubes-gui-agent-linux
)

run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_apt_deps() {
    run_sudo apt-get update
    run_sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apparmor autoconf automake bash build-essential ca-certificates curl file git gnupg \
        e2fsprogs genisoimage libarchive-tools lvm2 \
        guile-3.0 gzip jq libglib2.0-dev libpam0g-dev libsystemd-dev libtool \
        libx11-dev libxcomposite-dev libxdamage-dev libxext-dev libxt-dev \
        lsb-release make pandoc parted pkg-config procps python3 python3-dev \
        python3-setuptools python3-venv qemu-system-x86 qemu-utils rsync socat sudo tar \
        uidmap wget xz-utils zlib1g-dev \
        createrepo-c debootstrap devscripts dnf podman quilt rpm rpm2cpio
}

authorize_guix_substitutes() {
    local guix_bin="/root/.config/guix/current/bin/guix"
    [ -x "$guix_bin" ] || guix_bin="$(command -v guix || true)"
    [ -n "$guix_bin" ] || return 0
    local key_dirs=()
    local substitute_key

    key_dirs+=("/root/.config/guix/current/share/guix")
    key_dirs+=("/var/guix/profiles/per-user/root/current-guix/share/guix")
    key_dirs+=("/var/guix/profiles/per-user/root/current-guix/etc/substitutes")
    while IFS= read -r substitute_key; do
        [ -r "$substitute_key" ] || continue
        case "$substitute_key" in
            */ci.guix.gnu.org.pub|*/bordeaux.guix.gnu.org.pub)
                run_sudo "$guix_bin" archive --authorize < "$substitute_key"
                ;;
        esac
    done < <(
        find "${key_dirs[@]}" -maxdepth 1 -type f -name '*.pub' -print 2>/dev/null || true
        find /gnu/store -maxdepth 3 -type f \
            \( -path '*/share/guix/*.pub' -o -path '*/etc/substitutes/*.pub' \) \
            -print 2>/dev/null || true
    )

    if [ ! -s /etc/guix/acl ]; then
        printf 'warning: Guix substitute ACL is still empty; builds may fall back to source\n' >&2
    else
        run_sudo systemctl restart guix-daemon || true
    fi
}

download_guix_installer() {
    local installer="$1"
    local url

    for url in "$guix_installer_url" "$guix_installer_fallback_url"; do
        [ -n "$url" ] || continue
        if curl -fsSL --retry 5 --retry-delay 5 --connect-timeout 30 --max-time 300 \
            "$url" -o "$installer"; then
            return 0
        fi
        printf 'warning: failed to download Guix installer from %s\n' "$url" >&2
    done

    printf 'error: failed to download Guix installer\n' >&2
    return 1
}

install_guix_if_missing() {
    if command -v guix >/dev/null 2>&1 && systemctl is-active --quiet guix-daemon 2>/dev/null; then
        guix --version
        authorize_guix_substitutes
        return 0
    fi

    # The upstream installer verifies the release tarball against the
    # maintainers' OpenPGP keys. Import the currently required extra key before
    # running it so unattended cloud bootstraps do not stop at the key hint.
    for guix_key_url in \
        https://codeberg.org/efraim.gpg \
        https://codeberg.org/apteryx.gpg \
        https://codeberg.org/civodul.gpg
    do
        curl -fsSL "$guix_key_url" | run_sudo gpg --batch --import
    done

    local installer
    installer="$(mktemp)"
    download_guix_installer "$installer"
    chmod 0755 "$installer"
    perl -0pi -e 's/sys_maybe_setup_apparmor\(\)\n\{.*?\n\}\n\nsys_delete_apparmor_profiles/sys_maybe_setup_apparmor()\n{\n    return 0\n}\n\nsys_delete_apparmor_profiles/s' "$installer"
    # Answers, in order for the current Guix installer:
    # continue, authorize substitutes, do not customize bash prompt. The
    # AppArmor setup function is patched out above because Debian 12's parser
    # lacks the abi/4.0 include used by Guix 1.5's profile on this image.
    printf '\ny\nn\n' | run_sudo env GUIX_ALLOW_OVERWRITE=1 bash "$installer"
    authorize_guix_substitutes
    run_sudo systemctl enable --now guix-daemon

    if [ -f "$HOME/.config/guix/current/etc/profile" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.config/guix/current/etc/profile"
    elif [ -f /root/.config/guix/current/etc/profile ]; then
        # shellcheck disable=SC1091
        . /root/.config/guix/current/etc/profile
    fi
}

relax_ubuntu_apparmor_for_guix() {
    if systemctl list-unit-files apparmor.service >/dev/null 2>&1; then
        # Ubuntu 24.04's default AppArmor userns mediation can deny
        # guix-daemon CAP_NET_ADMIN in the build namespace, which surfaces as
        # "initLoopback: cannot set loopback interface flags". This cloud
        # builder is disposable, so disabling AppArmor is the least surprising
        # way to keep Guix builds reproducible here.
        run_sudo systemctl disable --now apparmor || true
        run_sudo aa-teardown || true
        run_sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
        run_sudo sysctl -w kernel.apparmor_restrict_unprivileged_unconfined=0 || true
        run_sudo sysctl -w kernel.apparmor_restrict_unprivileged_io_uring=0 || true
    fi
}

clone_qubes_sources() {
    run_sudo mkdir -p "$qubes_source_root"
    run_sudo chown "$USER":"$USER" "$qubes_source_root"

    local repo
    for repo in "${repos[@]}"; do
        if [ -d "$qubes_source_root/$repo/.git" ]; then
            git -C "$qubes_source_root/$repo" fetch --depth=1 origin || true
        else
            git clone --depth=1 "https://github.com/QubesOS/$repo.git" "$qubes_source_root/$repo"
        fi
    done

    for repo in qubes-builderv2 qubes-template-configs; do
        if [ -d "$qubes_source_root/$repo/.git" ]; then
            git -C "$qubes_source_root/$repo" fetch --depth=1 origin || true
        else
            git clone --depth=1 "https://github.com/QubesOS/$repo.git" "$qubes_source_root/$repo"
        fi
    done
}

check_nested_virtualization() {
    if [ -e /dev/kvm ]; then
        ls -l /dev/kvm
    else
        printf 'warning: /dev/kvm not present; nested virtualization is not usable yet\n' >&2
    fi

    if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        grep -Eom1 '(vmx|svm)' /proc/cpuinfo
    else
        printf 'warning: CPU virtualization flag not visible in /proc/cpuinfo\n' >&2
    fi
}

run_project_checks() {
    if [ -d "$workdir" ]; then
        make -C "$workdir" check
    else
        printf 'warning: project workdir not found: %s\n' "$workdir" >&2
    fi
}

install_apt_deps
install_guix_if_missing
relax_ubuntu_apparmor_for_guix
clone_qubes_sources
check_nested_virtualization
run_project_checks

printf 'GCP nested builder setup complete.\n'
