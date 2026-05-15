#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
variant="normal"
version="$(date -u +%Y%m%d)"
release="1"
watch=0
run_system_tests=0

usage() {
    cat <<'EOF'
Usage: run-openqa-template-rpm.sh [options]

Build a native Guix TemplateVM root image, package it as a Qubes template RPM,
schedule the RPM-mode openQA job, and optionally watch the job logs.

Options:
  --variant normal|minimal  Template variant to build. Default: normal.
  --version VERSION         RPM version. Default: current UTC YYYYMMDD.
  --release RELEASE         RPM release. Default: 1.
  --run-system-tests        Run Qubes dom0 integration tests after smoke tests.
  --watch                   Stream the scheduled job with watch-openqa-guix-job.
  -h, --help                Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant)
            variant="${2:-}"
            shift 2
            ;;
        --version)
            version="${2:-}"
            shift 2
            ;;
        --release)
            release="${2:-}"
            shift 2
            ;;
        --run-system-tests)
            run_system_tests=1
            shift
            ;;
        --watch)
            watch=1
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

case "$variant" in
    normal)
        template_name="guix"
        appvm_name="guix-openqa-test-app"
        image="root-gui-r${release}.img"
        asset="guix-root-r${release}.img"
        expect_commands="xfce4-terminal xterm Xorg su"
        expect_desktops="xfce4-terminal.desktop"
        ;;
    minimal)
        template_name="guix-minimal"
        appvm_name="guix-minimal-openqa-test-app"
        image="root-minimal-r${release}.img"
        asset="guix-minimal-root-r${release}.img"
        expect_commands="xterm Xorg su"
        expect_desktops="xterm.desktop"
        ;;
    *)
        die "unsupported variant: $variant"
        ;;
esac

rpm="$repo_root/dist/qubes-template-${template_name}-${version}-${release}.noarch.rpm"
build="guix-${variant}-rpm-r${release}-$(date -u +%Y%m%d%H%M)"

cd "$repo_root"
mkdir -p dist logs

./scripts/build-native-rootfs.sh --variant "$variant" --output "$image"

inspect_args=(--image "$image")
for command in $expect_commands; do
    inspect_args+=(--expect-command "$command")
done
for desktop in $expect_desktops; do
    inspect_args+=(--expect-desktop "$desktop")
done
./scripts/inspect-native-rootfs.sh "${inspect_args[@]}"
./scripts/test-native-rootfs-activation.sh --image "$image"

./scripts/package-native-template-rpm.sh \
    --root-image "$image" \
    --name "$template_name" \
    --version "$version" \
    --release "$release"
sha256sum "$rpm"

GUIX_INSTALL_MODE=rpm \
QUBES_OPENQA_GUIX_ROOT_IMAGE="$repo_root/$image" \
QUBES_OPENQA_GUIX_ASSET="$asset" \
QUBES_OPENQA_GUIX_TEMPLATE_RPM="$rpm" \
QUBES_OPENQA_BUILD="$build" \
QUBES_OPENQA_TEMPLATE_NAME="$template_name" \
QUBES_OPENQA_APPVM_NAME="$appvm_name" \
GUIX_EXPECT_COMMANDS="$expect_commands" \
GUIX_EXPECT_DESKTOPS="$expect_desktops" \
GUIX_RUN_QUBES_SYSTEM_TESTS="$run_system_tests" \
    ./scripts/setup-openqa-guix-template-test.sh

if [ "$watch" -eq 1 ]; then
    ./scripts/watch-openqa-guix-job.sh latest
fi
