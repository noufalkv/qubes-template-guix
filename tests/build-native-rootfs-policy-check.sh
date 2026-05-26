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

rm -rf "$fixture_repo" "$fake_bin" "$install_dir"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/config" "$fake_bin" "$install_dir" "$work_dir/home"
cp "$repo_root/scripts/build-native-rootfs.sh" \
    "$fixture_repo/scripts/build-native-rootfs.sh"
chmod +x "$fixture_repo/scripts/build-native-rootfs.sh"
: >"$fixture_repo/config/channels.scm"
: >"$fixture_repo/config.scm"
: >"$work_dir/order.log"

cat >"$fake_bin/guix" <<EOF
#!/bin/sh
printf 'guix %s\\n' "\$*" >>"$work_dir/order.log"
case "\$1" in
    pull) exit 0 ;;
    *) exit 99 ;;
esac
EOF
chmod +x "$fake_bin/guix"

cat >"$fake_bin/sudo" <<EOF
#!/bin/sh
printf 'sudo %s\\n' "\$*" >>"$work_dir/order.log"
exit 88
EOF
chmod +x "$fake_bin/sudo"

cat >"$fake_bin/mountpoint" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$fake_bin/mountpoint"

mkdir -p "$work_dir/home/.config/guix/current/bin"
cat >"$work_dir/home/.config/guix/current/bin/guix" <<EOF
#!/bin/sh
printf 'current-guix %s\\n' "\$*" >>"$work_dir/order.log"
exit 99
EOF
chmod +x "$work_dir/home/.config/guix/current/bin/guix"

set +e
HOME="$work_dir/home" \
PATH="$fake_bin:$PATH" \
    "$fixture_repo/scripts/build-native-rootfs.sh" \
        --install-dir "$install_dir" \
        --config "$fixture_repo/config.scm" >"$output" 2>&1
status=$?
set -e

[ "$status" -eq 88 ] || {
    printf 'expected build-native-rootfs.sh to reach sudo init after guix pull, got %s:\n' "$status" >&2
    cat "$output" >&2
    cat "$work_dir/order.log" >&2
    exit 1
}

cat >"$work_dir/expected-order.log" <<EOF
guix pull --channels=$fixture_repo/config/channels.scm
sudo $work_dir/home/.config/guix/current/bin/guix time-machine -C $fixture_repo/config/channels.scm -- system init --no-bootloader -L $fixture_repo/native/modules $fixture_repo/config.scm $install_dir
EOF

cmp -s "$work_dir/expected-order.log" "$work_dir/order.log" || {
    printf 'unexpected build-native-rootfs command order:\n' >&2
    printf 'expected:\n' >&2
    cat "$work_dir/expected-order.log" >&2
    printf 'actual:\n' >&2
    cat "$work_dir/order.log" >&2
    exit 1
}

printf 'build-native-rootfs policy check passed\n'
