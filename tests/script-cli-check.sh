#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

check_missing_value() {
    local script="$1"
    local option="$2"
    local output
    local status

    set +e
    output="$("$repo_root/$script" "$option" 2>&1)"
    status=$?
    set -e

    [ "$status" -ne 0 ] || {
        printf 'expected %s %s to fail\n' "$script" "$option" >&2
        exit 1
    }

    printf '%s\n' "$output" | grep -Fq -- "$option requires a value" || {
        printf 'missing useful error for %s %s:\n%s\n' \
            "$script" "$option" "$output" >&2
        exit 1
    }
}

check_missing_value scripts/build-native-rootfs.sh --variant
check_missing_value scripts/package-native-template-rpm.sh --root-image
check_missing_value scripts/test-template-rpm-lifecycle-dom0.sh --rpm
check_missing_value scripts/test-update-proxy-default-target-dom0.sh --template
check_missing_value scripts/test-memory-balloon-dom0.sh --template
check_missing_value scripts/inspect-native-rootfs.sh --image
check_missing_value scripts/import-native-rootfs-dom0.sh --image
check_missing_value scripts/test-native-rootfs-activation.sh --image
check_missing_value scripts/create-foreign-guix-template-dom0.sh --base
check_missing_value scripts/run-openqa-template-rpm.sh --variant
check_missing_value scripts/gcloud-create-nested-builder.sh --name
check_missing_value scripts/gcloud-sync-and-setup-builder.sh --name
check_missing_value scripts/setup-openqa-guix-template-test.sh --tests-source
check_missing_value scripts/test-native-guix-template-dom0.sh --template

printf 'script CLI contract check passed\n'
