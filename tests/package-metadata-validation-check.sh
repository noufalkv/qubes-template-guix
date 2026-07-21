#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
packager="$repo_root/scripts/package-native-template-rpm.sh"

assert_rejected() {
    local option="$1"
    local value="$2"
    local output

    if output="$("$packager" "$option" "$value" 2>&1)"; then
        printf 'unsafe metadata accepted: %s %q\n' "$option" "$value" >&2
        return 1
    fi
    case "$output" in
        *"is not a safe RPM version field"*) ;;
        *)
            printf 'metadata rejected for the wrong reason: %s %q\n%s\n' \
                "$option" "$value" "$output" >&2
            return 1
            ;;
    esac
}

for option in --version --release; do
    assert_rejected "$option" ""
    assert_rejected "$option" '%{lua:print(1)}'
    assert_rejected "$option" '1"'
    assert_rejected "$option" $'1\rInjected: value'
    assert_rejected "$option" '1-2'
    assert_rejected "$option" '1/2'
    assert_rejected "$option" '1 2'
    assert_rejected "$option" '1^git'
    assert_rejected "$option" 'café'
done

printf '%s\n' 'RPM package metadata validation check passed'
