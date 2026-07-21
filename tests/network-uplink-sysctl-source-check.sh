#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
services_file="$repo_root/modules/qubes/services.scm"
packages_file="$repo_root/modules/qubes/packages.scm"

extract_definition() {
    local file="$1"
    local name="$2"

    awk -v definition="$name" '
        $0 == "(define (" definition { copying = 1 }
        copying && seen && /^\(define/ { exit }
        copying { print; seen = 1 }
    ' "$file"
}

reconfigure_program="$(
    extract_definition "$services_file" \
        "qubes-network-uplink-reconfigure-program)"
)"
sysctl_helpers="$(
    extract_definition "$packages_file" \
        "qubes-network-sysctl-helper-forms)"
)"

[ -n "$reconfigure_program" ] || {
    printf 'missing qubes-network-uplink-reconfigure-program definition\n' >&2
    exit 1
}
[ -n "$sysctl_helpers" ] || {
    printf 'missing qubes-network-sysctl-helper-forms definition\n' >&2
    exit 1
}

grep -Fq '#$@(qubes-network-sysctl-helper-forms)' \
    <<<"$reconfigure_program" || {
    printf 'hotplug reconfigure program does not splice the shared sysctl helpers\n' >&2
    exit 1
}

for private_definition in \
    '(define (sysctl-path' \
    '(define (write-sysctl' \
    '(define (apply-sysctls-to-iface'; do
    if grep -Fq "$private_definition" <<<"$reconfigure_program"; then
        printf 'hotplug reconfigure program duplicates shared helper: %s\n' \
            "$private_definition" >&2
        exit 1
    fi
done

if ! grep -Fq 'failed to write network sysctl' <<<"$sysctl_helpers" ||
        ! grep -Fq '(exit 1)' <<<"$sysctl_helpers"; then
    printf 'shared network sysctl writer is no longer fail-loud\n' >&2
    exit 1
fi

printf 'network uplink hotplug uses the shared fail-loud sysctl helpers\n'
