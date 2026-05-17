#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "$repo_root/work.build-native-rootfs-policy.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

fixture_repo="$work_dir/repo"
fake_bin="$work_dir/bin"
install_dir="$work_dir/install"
output="$work_dir/build-native-rootfs.out"

mkdir -p "$fixture_repo/scripts" "$fake_bin" "$install_dir"
cp "$repo_root/scripts/build-native-rootfs.sh" \
    "$fixture_repo/scripts/build-native-rootfs.sh"
chmod +x "$fixture_repo/scripts/build-native-rootfs.sh"

for command_name in guix sudo mountpoint; do
    cat >"$fake_bin/$command_name" <<EOF
#!/bin/sh
echo "$command_name should not run before pinned-channel validation" >&2
exit 99
EOF
    chmod +x "$fake_bin/$command_name"
done

set +e
PATH="$fake_bin:$PATH" \
    "$fixture_repo/scripts/build-native-rootfs.sh" \
        --install-dir "$install_dir" >"$output" 2>&1
status=$?
set -e

[ "$status" -ne 0 ] || {
    printf 'expected build-native-rootfs.sh to fail without pinned channels\n' >&2
    exit 1
}

[ "$status" -ne 99 ] || {
    printf 'pinned-channel validation happened too late:\n' >&2
    cat "$output" >&2
    exit 1
}

grep -Fq 'missing pinned Guix channels file:' "$output" || {
    printf 'missing pinned-channel error in output:\n' >&2
    cat "$output" >&2
    exit 1
}

grep -Fq 'config/channels.scm' "$output" || {
    printf 'missing channels.scm path in output:\n' >&2
    cat "$output" >&2
    exit 1
}

if find "$fixture_repo" -maxdepth 1 \( -name 'root*.img' -o -name 'mnt.*' \) |
    grep -q .; then
    printf 'build-native-rootfs.sh created image or mount artifacts before channel validation\n' >&2
    find "$fixture_repo" -maxdepth 1 -print >&2
    exit 1
fi

printf 'build-native-rootfs policy check passed\n'
