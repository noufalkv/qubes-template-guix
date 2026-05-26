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
check_missing_value scripts/test-guix-update-proxy-config-dom0.sh --template
check_missing_value scripts/test-guix-update-proxy-download-dom0.sh --template
check_missing_value scripts/test-guix-update-proxy-stub-download-dom0.sh --template
check_missing_value scripts/test-guix-central-vmupdate-dom0.sh --template
check_missing_value scripts/test-guix-central-vmupdate-dom0.sh --proxy-probe-url
check_missing_value scripts/bootstrap-qubes-update-target-dom0.sh --template-rpm
check_missing_value scripts/bootstrap-qubes-update-target-dom0.sh --target
check_missing_value scripts/test-memory-balloon-dom0.sh --template
check_missing_value scripts/inspect-native-rootfs.sh --image
check_missing_value scripts/import-native-rootfs-dom0.sh --image
check_missing_value scripts/test-native-rootfs-activation.sh --image
check_missing_value scripts/create-foreign-guix-template-dom0.sh --base
check_missing_value scripts/run-openqa-template-rpm.sh --variant
check_missing_value scripts/setup-openqa-guix-template-test.sh --tests-source
check_missing_value scripts/test-native-guix-template-dom0.sh --template

check_central_openqa_warning() {
    local tmp
    local output
    local status

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/qubes-guix-openqa-cli.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN

    set +e
    output="$(GUIX_RUN_CENTRAL_VMUPDATE_TEST=1 \
        "$repo_root/scripts/setup-openqa-guix-template-test.sh" \
        --tests-source "$tmp/missing-tests" \
        --qubes-disk "$tmp/missing-dom0.qcow2" \
        --guix-root-image "$tmp/missing-root.img" \
        --no-schedule 2>&1)"
    status=$?
    set -e

    [ "$status" -ne 0 ] || {
        printf 'expected central openQA warning probe to fail on missing assets\n' >&2
        exit 1
    }

    printf '%s\n' "$output" |
        grep -Fq 'GUIX_RUN_CENTRAL_VMUPDATE_TEST=1 requires' || {
            printf 'missing central openQA update-target warning:\n%s\n' \
                "$output" >&2
            exit 1
        }
    printf '%s\n' "$output" |
        grep -Fq 'controlled/stub updates-proxy target is not sufficient proof' || {
            printf 'missing central openQA stub-proof warning:\n%s\n' \
                "$output" >&2
            exit 1
        }
}

check_central_openqa_warning

check_setup_env_error() {
    local label="$1"
    local expected="$2"
    local tmp
    local output
    local status
    shift 2

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/qubes-guix-openqa-setup.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/tests"
    : >"$tmp/tests/main.pm"
    : >"$tmp/dom0.qcow2"
    : >"$tmp/root.img"
    : >"$tmp/template.rpm"

    set +e
    output="$(
        env "$@" \
            "$repo_root/scripts/setup-openqa-guix-template-test.sh" \
            --tests-source "$tmp/tests" \
            --qubes-disk "$tmp/dom0.qcow2" \
            --guix-root-image "$tmp/root.img" \
            --template-rpm "$tmp/template.rpm" \
            --no-schedule 2>&1
    )"
    status=$?
    set -e

    [ "$status" -ne 0 ] || {
        printf 'expected setup-openqa-guix-template-test.sh to fail: %s\n' \
            "$label" >&2
        exit 1
    }

    printf '%s\n' "$output" | grep -Fq "$expected" || {
        printf 'unexpected setup error for %s, wanted %s:\n%s\n' \
            "$label" "$expected" "$output" >&2
        exit 1
    }
}

check_setup_env_error invalid-update-target-network-mode \
    'unsupported QUBES_OPENQA_UPDATE_TARGET_NETWORK_MODE' \
    GUIX_INSTALL_MODE=rpm \
    QUBES_OPENQA_UPDATE_TARGET_NETWORK_MODE=bad
check_setup_env_error bootstrap-requires-rpm-mode \
    'GUIX_BOOTSTRAP_UPDATE_TARGET=1 requires GUIX_INSTALL_MODE=rpm' \
    GUIX_INSTALL_MODE=direct \
    GUIX_BOOTSTRAP_UPDATE_TARGET=1
check_setup_env_error bootstrap-requires-update-target-rpm \
    'missing update target template RPM' \
    GUIX_INSTALL_MODE=rpm \
    GUIX_BOOTSTRAP_UPDATE_TARGET=1
check_setup_env_error core-admin-backend-tree-preflight \
    'missing core-admin entrypoint' \
    GUIX_INSTALL_MODE=rpm \
    GUIX_CORE_ADMIN_LINUX_TREE=/tmp/qubes-guix-missing-core-admin-tree

check_invalid_template_name() {
    local label="$1"
    local output
    local status
    shift

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e

    [ "$status" -ne 0 ] || {
        printf 'expected invalid template name to fail: %s\n' "$label" >&2
        exit 1
    }

    printf '%s\n' "$output" | grep -Fq 'template name' || {
        printf 'invalid template name did not produce a useful error for %s:\n%s\n' \
            "$label" "$output" >&2
        exit 1
    }
}

check_invalid_template_name package-template-name \
    "$repo_root/scripts/package-native-template-rpm.sh" \
    --name 1bad --root-image /does/not/exist
check_invalid_template_name builder-template-name \
    env TEMPLATE_NAME=../bad \
    "$repo_root/scripts/builder-v2-template-adapter.sh" build-rootimg

printf 'script CLI contract check passed\n'
