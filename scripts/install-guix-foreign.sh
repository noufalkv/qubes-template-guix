#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

installer_url="${GUIX_INSTALLER_URL:-https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh}"
stamp_file="/etc/qubes-guix-template.env"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "this script must run as root inside the template"
}

install_deps_debian() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget gnupg dirmngr xz-utils gzip tar \
        grep sed coreutils findutils gawk uidmap passwd sudo procps apparmor
}

install_deps_fedora() {
    dnf install -y \
        bash ca-certificates curl wget gnupg2 xz gzip tar \
        grep sed coreutils findutils gawk shadow-utils sudo procps-ng uidmap
}

install_deps_arch() {
    pacman -Sy --noconfirm --needed \
        bash ca-certificates curl wget gnupg xz gzip tar \
        grep sed coreutils findutils gawk shadow sudo procps-ng
}

install_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        install_deps_debian
    elif command -v dnf >/dev/null 2>&1; then
        install_deps_fedora
    elif command -v pacman >/dev/null 2>&1; then
        install_deps_arch
    else
        die "unsupported template package manager; expected apt-get, dnf, or pacman"
    fi
}

install_guix() {
    local installer="/tmp/guix-install.sh"

    if command -v guix >/dev/null 2>&1 && systemctl is-active --quiet guix-daemon 2>/dev/null; then
        printf 'Guix already installed and guix-daemon is active.\n'
        return 0
    fi

    # Keep dom0-driven template creation unattended when the current Guix
    # installer requires the extra release-signing key.
    curl -fsSL https://codeberg.org/efraim.gpg | gpg --batch --import

    curl -fsSL "$installer_url" -o "$installer"
    chmod 0755 "$installer"
    perl -0pi -e 's/sys_maybe_setup_apparmor\(\)\n\{.*?\n\}\n\nsys_delete_apparmor_profiles/sys_maybe_setup_apparmor()\n{\n    return 0\n}\n\nsys_delete_apparmor_profiles/s' "$installer"

    # guix-install.sh is intentionally interactive. In a cloned disposable
    # template build we answer yes to release-key and daemon integration prompts.
    # continue, authorize substitutes, do not customize bash prompt,
    # do not install AppArmor profile. The generated Guix 1.5 AppArmor profile
    # can require abi/4.0, which is absent on some Qubes/Debian templates.
    printf '\ny\nn\nn\n' | GUIX_ALLOW_OVERWRITE=1 bash "$installer"
}

ensure_profile_hook() {
    cat > /etc/profile.d/guix-template.sh <<'EOF'
# Added by qubes-guix-template.
if [ -n "${USER:-}" ]; then
    GUIX_PROFILE="/var/guix/profiles/per-user/$USER/current-guix"
    [ -f "$GUIX_PROFILE/etc/profile" ] && . "$GUIX_PROFILE/etc/profile"
fi

GUIX_PROFILE="$HOME/.guix-profile"
[ -f "$GUIX_PROFILE/etc/profile" ] && . "$GUIX_PROFILE/etc/profile"
EOF
}

restart_daemon() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl enable --now guix-daemon
    elif command -v service >/dev/null 2>&1; then
        service guix-daemon restart
    fi
}

smoke_test() {
    command -v guix >/dev/null 2>&1 || die "guix command not found after install"
    guix --version
    guix package -A hello >/dev/null
}

write_stamp() {
    {
        printf 'GUIX_TEMPLATE_INSTALLED=1\n'
        printf 'GUIX_TEMPLATE_INSTALLED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'GUIX_TEMPLATE_INSTALLER_URL=%s\n' "$installer_url"
    } > "$stamp_file"
}

need_root
install_deps
install_guix
ensure_profile_hook
restart_daemon
smoke_test
write_stamp

printf 'Guix foreign-package-manager template setup complete.\n'
