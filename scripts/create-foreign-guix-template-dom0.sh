#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

base_template="${BASE_TEMPLATE:-}"
template_name="${TEMPLATE_NAME:-guix-debian-13}"
netvm="${NETVM:-}"
reuse=0
run_tests=1
dry_run=0

usage() {
    cat <<'EOF'
Usage: create-foreign-guix-template-dom0.sh [options]

Creates a Qubes TemplateVM by cloning an existing Debian/Fedora template and
installing GNU Guix inside it as a foreign package manager.

Options:
  --base NAME       Base template to clone. If omitted, auto-detect one.
  --name NAME       Target template name. Default: guix-debian-13
  --netvm NAME      Set target template NetVM before installing Guix.
  --reuse           Reuse an existing target template.
  --no-tests        Skip post-install smoke tests.
  --dry-run         Print commands without executing them.
  -h, --help        Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if [ "$dry_run" -eq 0 ]; then
        "$@"
    fi
}

vm_exists() {
    qvm-ls --raw-list | grep -Fxq "$1"
}

auto_base_template() {
    local candidate
    for candidate in \
        debian-13-minimal debian-13-xfce debian-12-minimal debian-12-xfce \
        fedora-42-minimal fedora-42-xfce fedora-41-minimal fedora-41-xfce
    do
        if vm_exists "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

remote_root() {
    local vm="$1"
    local command="$2"
    run qvm-run --no-gui --pass-io --user root "$vm" "$command"
}

copy_installer_to_vm() {
    local vm="$1"
    local installer="$script_dir/install-guix-foreign.sh"

    [ -r "$installer" ] || die "missing installer payload: $installer"
    printf '+ qvm-run --no-gui --pass-io --user root %q %q < %q\n' \
        "$vm" 'cat > /tmp/install-guix-foreign.sh && chmod 0755 /tmp/install-guix-foreign.sh' "$installer"
    if [ "$dry_run" -eq 0 ]; then
        qvm-run --no-gui --pass-io --user root "$vm" \
            'cat > /tmp/install-guix-foreign.sh && chmod 0755 /tmp/install-guix-foreign.sh' \
            < "$installer"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base)
            base_template="${2:-}"
            shift 2
            ;;
        --name)
            template_name="${2:-}"
            shift 2
            ;;
        --netvm)
            netvm="${2:-}"
            shift 2
            ;;
        --reuse)
            reuse=1
            shift
            ;;
        --no-tests)
            run_tests=0
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
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

need qvm-ls
need qvm-clone
need qvm-run
need qvm-start
need qvm-shutdown
need qvm-prefs

if [ -z "$base_template" ]; then
    base_template="$(auto_base_template)" || die "could not auto-detect a Debian/Fedora base template"
fi

vm_exists "$base_template" || die "base template does not exist: $base_template"

if vm_exists "$template_name"; then
    [ "$reuse" -eq 1 ] || die "target template already exists: $template_name; use --reuse to install/test in place"
else
    run qvm-clone "$base_template" "$template_name"
fi

if [ -n "$netvm" ]; then
    vm_exists "$netvm" || die "requested NetVM does not exist: $netvm"
    run qvm-prefs "$template_name" netvm "$netvm"
fi

run qvm-start "$template_name"
copy_installer_to_vm "$template_name"
remote_root "$template_name" /tmp/install-guix-foreign.sh

if [ "$run_tests" -eq 1 ]; then
    "$script_dir/test-foreign-guix-template-dom0.sh" "$template_name"
fi

run qvm-shutdown --wait "$template_name"
printf 'created Guix-enabled Qubes template: %s\n' "$template_name"
