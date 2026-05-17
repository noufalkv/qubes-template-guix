#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"
install_rpm=""
upgrade_rpm=""
downgrade_rpm=""
expect_template=""
replace_existing=0
keep_template=0
run_smoke=0
metadata_only=0
appvm_name=""
log_dir=""
rpmdb=""

usage() {
    cat <<'EOF'
Usage: test-template-rpm-lifecycle-dom0.sh --rpm FILE [options]

Run qvm-template lifecycle checks for a local template RPM in dom0.

Options:
  -r, --rpm FILE          RPM to install and reinstall. Required.
  -u, --upgrade-rpm FILE  Optional newer RPM for qvm-template upgrade.
  -d, --downgrade-rpm FILE
                          Optional older RPM for qvm-template downgrade.
  -e, --expect-template NAME
                          Require the RPM package to map to template NAME.
  -m, --metadata-only     Validate RPM metadata and exit before dom0 commands.
  -R, --replace-existing  Remove an existing TemplateVM with the same name first.
  -k, --keep-template     Leave the installed TemplateVM after the test.
  -s, --run-smoke         Run the existing TemplateVM/AppVM smoke test after
                          install and after reinstall.
  -a, --appvm NAME        AppVM name for --run-smoke. Default:
                          TEMPLATE-lifecycle-app.
  -l, --log-dir DIR       Directory for qvm-template logs. Default:
                          /tmp/qubes-template-lifecycle-TEMPLATE.PID.
  -h, --help              Show this help.

This script is intended for a clean nested dom0 or a disposable review system.
It can remove the tested template when --replace-existing or the default final
cleanup is used.
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

while [ "$#" -gt 0 ]; do
    case "$1" in
        -r|--rpm)
            require_arg "$@"
            install_rpm="$2"
            shift 2
            ;;
        -u|--upgrade-rpm)
            require_arg "$@"
            upgrade_rpm="$2"
            shift 2
            ;;
        -d|--downgrade-rpm)
            require_arg "$@"
            downgrade_rpm="$2"
            shift 2
            ;;
        -e|--expect-template)
            require_arg "$@"
            expect_template="$2"
            shift 2
            ;;
        -m|--metadata-only)
            metadata_only=1
            shift
            ;;
        -R|--replace-existing)
            replace_existing=1
            shift
            ;;
        -k|--keep-template)
            keep_template=1
            shift
            ;;
        -s|--run-smoke)
            run_smoke=1
            shift
            ;;
        -a|--appvm)
            require_arg "$@"
            appvm_name="$2"
            shift 2
            ;;
        -l|--log-dir)
            require_arg "$@"
            log_dir="$2"
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

[ -n "$install_rpm" ] || die "missing --rpm"
[ -r "$install_rpm" ] || die "missing RPM: $install_rpm"
[ -z "$upgrade_rpm" ] || [ -r "$upgrade_rpm" ] || die "missing upgrade RPM: $upgrade_rpm"
[ -z "$downgrade_rpm" ] || [ -r "$downgrade_rpm" ] || die "missing downgrade RPM: $downgrade_rpm"

need rpm

cleanup() {
    if [ -n "$rpmdb" ] && [ -d "$rpmdb" ]; then
        rm -rf "$rpmdb"
    fi
}
trap cleanup EXIT

rpmdb="$(mktemp -d /tmp/qubes-template-lifecycle-rpmdb.XXXXXX)"

rpm_package_name() {
    rpm --dbpath "$rpmdb" -qp --qf '%{NAME}' "$1"
}

rpm_version_release() {
    rpm --dbpath "$rpmdb" -qp --qf '%{VERSION}-%{RELEASE}' "$1"
}

template_from_rpm() {
    local rpm_file="$1"
    local package
    package="$(rpm_package_name "$rpm_file")"
    case "$package" in
        qubes-template-*) printf '%s\n' "${package#qubes-template-}" ;;
        *) die "RPM package is not a Qubes template package: $package" ;;
    esac
}

template_name="$(template_from_rpm "$install_rpm")"
install_evr="$(rpm_version_release "$install_rpm")"
[ -z "$expect_template" ] || [ "$template_name" = "$expect_template" ] ||
    die "expected template '$expect_template', got '$template_name'"
appvm_name="${appvm_name:-$template_name-lifecycle-app}"
log_dir="${log_dir:-/tmp/qubes-template-lifecycle-$template_name.$$}"
mkdir -p "$log_dir"

check_same_template() {
    local rpm_file="$1"
    local label="$2"
    local other
    [ -n "$rpm_file" ] || return 0
    other="$(template_from_rpm "$rpm_file")"
    [ "$other" = "$template_name" ] ||
        die "$label RPM template '$other' does not match '$template_name'"
}

check_same_template "$upgrade_rpm" "upgrade"
check_same_template "$downgrade_rpm" "downgrade"

template_exists() {
    qvm-ls --raw-list 2>/dev/null | grep -Fxq "$1"
}

remove_template() {
    local name="$1"
    template_exists "$name" || return 0
    qvm-shutdown --wait "$name" >/dev/null 2>&1 || true
    qvm-template --yes remove "$name"
}

run_template_command() {
    local label="$1"
    shift
    local log="$log_dir/qvm-template-$label.log"
    printf 'running qvm-template %s for %s\n' "$label" "$template_name"
    qvm-template --yes "$@" 2>&1 | tee "$log"
    if grep -Eq 'PermissionError|Failed to set default application list|qubes[.]PostInstall service failed' "$log"; then
        if [ -x "$repo_root/scripts/diagnose-guix-postinstall-dom0.sh" ]; then
            "$repo_root/scripts/diagnose-guix-postinstall-dom0.sh" "$template_name" \
                2>&1 | tee "$log_dir/postinstall-diagnostics-$label.log" || true
        fi
        die "qvm-template $label logged a post-install failure"
    fi
}

assert_template_metadata() {
    local rpm_file="$1"
    local value
    local feature_name
    local feature_version
    local feature_release
    local expected_evr

    template_exists "$template_name" || die "template was not created: $template_name"
    value="$(qvm-prefs "$template_name" klass 2>/dev/null || true)"
    [ "$value" = "TemplateVM" ] ||
        die "expected klass=TemplateVM for $template_name, got '$value'"

    # qvm-template intentionally calls qvm-template-postprocess with
    # --no-installed-by-rpm and records template package identity in features.
    feature_name="$(qvm-features "$template_name" template-name 2>/dev/null || true)"
    [ "$feature_name" = "$template_name" ] ||
        die "expected template-name feature '$template_name', got '$feature_name'"
    feature_version="$(qvm-features "$template_name" template-version 2>/dev/null || true)"
    feature_release="$(qvm-features "$template_name" template-release 2>/dev/null || true)"
    expected_evr="$(rpm_version_release "$rpm_file")"
    [ "$feature_version-$feature_release" = "$expected_evr" ] ||
        die "expected template metadata $expected_evr for $template_name, got '$feature_version-$feature_release'"
}

run_smoke_test() {
    local args=()
    [ "$run_smoke" -eq 1 ] || return 0
    [ -x "$repo_root/scripts/test-native-guix-template-dom0.sh" ] ||
        die "missing smoke test script"

    case "$template_name" in
        *-minimal)
            args+=(--expect-command xterm --expect-command Xorg --expect-desktop xterm.desktop)
            ;;
        *)
            args+=(--expect-command xfce4-terminal --expect-command Xorg --expect-desktop xfce4-terminal.desktop)
            ;;
    esac

    "$repo_root/scripts/test-native-guix-template-dom0.sh" \
        --template "$template_name" \
        --appvm "$appvm_name" \
        "${args[@]}"
}

printf 'template: %s\n' "$template_name"
printf 'install RPM: %s (%s)\n' "$install_rpm" "$install_evr"
[ -z "$upgrade_rpm" ] || printf 'upgrade RPM: %s (%s)\n' "$upgrade_rpm" "$(rpm_version_release "$upgrade_rpm")"
[ -z "$downgrade_rpm" ] || printf 'downgrade RPM: %s (%s)\n' "$downgrade_rpm" "$(rpm_version_release "$downgrade_rpm")"
printf 'logs: %s\n' "$log_dir"

if [ "$metadata_only" -eq 1 ]; then
    printf 'metadata check passed for %s\n' "$template_name"
    exit 0
fi

need qvm-ls
need qvm-features
need qvm-prefs
need qvm-shutdown
need qvm-template

if template_exists "$template_name"; then
    [ "$replace_existing" -eq 1 ] ||
        die "template already exists: $template_name; pass --replace-existing"
    remove_template "$template_name"
fi

run_template_command install install --nogpgcheck "$install_rpm"
assert_template_metadata "$install_rpm"
run_smoke_test

run_template_command reinstall reinstall --nogpgcheck "$install_rpm"
assert_template_metadata "$install_rpm"
run_smoke_test

if [ -n "$upgrade_rpm" ]; then
    run_template_command upgrade upgrade --nogpgcheck "$upgrade_rpm"
    assert_template_metadata "$upgrade_rpm"
fi

if [ -n "$downgrade_rpm" ]; then
    run_template_command downgrade downgrade --nogpgcheck "$downgrade_rpm"
    assert_template_metadata "$downgrade_rpm"
fi

if [ "$keep_template" -eq 0 ]; then
    remove_template "$template_name"
    ! template_exists "$template_name" ||
        die "template still exists after remove: $template_name"
fi

printf 'qvm-template lifecycle check passed for %s\n' "$template_name"
