#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

version="${QUBES_VERSION:-4.3.0}"
iso_stem="Qubes-R${version}-x86_64"
workdir="${QUBES_NESTED_WORKDIR:-$HOME/qubes-nested}"
iso_dir="$workdir/iso"
boot_dir="$workdir/boot"
ks_dir="$workdir/kickstart"
vm_dir="$workdir/vm"
iso_url_base="${QUBES_ISO_URL_BASE:-https://ftp.qubes-os.org/iso}"
iso_path="$iso_dir/$iso_stem.iso"
digests_path="$iso_path.DIGESTS"
sig_path="$iso_path.asc"
release_key_url="${QUBES_RELEASE_KEY_URL:-https://keys.qubes-os.org/keys/qubes-release-4.3-signing-key.asc}"
disk_path="${QUBES_NESTED_DISK:-$vm_dir/qubes-r${version}.qcow2}"
disk_size="${QUBES_NESTED_DISK_SIZE:-120G}"
memory="${QUBES_NESTED_MEMORY:-32768}"
cpus="${QUBES_NESTED_CPUS:-8}"
ssh_port="${QUBES_NESTED_SSH_PORT:-2222}"
vnc_display="${QUBES_NESTED_VNC_DISPLAY:-7}"
monitor_socket="$vm_dir/qemu-monitor.sock"
serial_log="$vm_dir/serial.log"
serial_socket="$vm_dir/serial.sock"
qemu_log="$vm_dir/qemu.log"
ssh_key="$vm_dir/dom0_ssh_ed25519"
dom0_user="${QUBES_NESTED_DOM0_USER:-user}"
dom0_password="${QUBES_NESTED_DOM0_PASSWORD:-qubes}"

usage() {
    cat <<'EOF'
Usage: qubes-nested-dom0-host.sh COMMAND

Host-side helper for a nested Qubes dom0 test VM. It follows the Qubes openQA
QEMU shape: q35,kernel-irqchip=split, host,+vmx,+invtsc, SCSI disk, e1000e NIC.

Commands:
  download       Download the Qubes installer ISO, digest, signature, and key.
  verify         Verify the ISO digest and, when possible, the signed DIGESTS.
  prepare        Extract installer kernel/initrd and generate kickstart media.
  install        Create the disk and run the unattended Qubes installer.
  start          Start the installed nested Qubes dom0 VM in the background.
  stop           Ask the VM to power down, then kill QEMU if needed.
  status         Show VM process, ports, and key artifact paths.
  ssh            Open SSH to the nested dom0.
  wait-ssh       Wait until nested dom0 SSH responds.
  console        Run a command in nested dom0 over the serial console.
  wait-console   Wait until nested dom0 serial login works.
  put-file       Copy a local file into nested dom0 over the serial console.
  copy-root      Copy ROOT_IMG into nested dom0. Default ROOT_IMG=root.img.
  import-test    Copy scripts/root image, import the template, and run smoke tests.

Important environment overrides:
  QUBES_NESTED_WORKDIR       Default: $HOME/qubes-nested
  QUBES_NESTED_DISK_SIZE     Default: 120G
  QUBES_NESTED_MEMORY        Default: 32768
  QUBES_NESTED_CPUS          Default: 8
  QUBES_NESTED_SSH_PORT      Default: 2222
  QUBES_NESTED_VNC_DISPLAY   Default: 7 (host port 5907)
  ROOT_IMG                   Used by copy-root/import-test; default: root.img
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

mkdirs() {
    mkdir -p "$iso_dir" "$boot_dir" "$ks_dir" "$vm_dir"
}

download() {
    need wget
    mkdirs
    (
        cd "$iso_dir"
        wget -c --tries=5 "$iso_url_base/$iso_stem.iso.DIGESTS"
        wget -c --tries=5 "$iso_url_base/$iso_stem.iso.asc"
        wget -c --tries=5 "$release_key_url"
        wget -c --tries=5 "$iso_url_base/$iso_stem.iso"
    )
}

verify() {
    need sha512sum
    [ -r "$iso_path" ] || die "missing ISO: $iso_path"
    [ -r "$digests_path" ] || die "missing DIGESTS: $digests_path"

    local expected
    expected="$(awk -v iso="$iso_stem.iso" 'length($1) == 128 && $2 == "*" iso {print $1}' "$digests_path")"
    [ -n "$expected" ] || die "could not find SHA512 digest for $iso_stem.iso"
    printf '%s  %s\n' "$expected" "$iso_path" | sha512sum -c -

    if command -v gpg >/dev/null 2>&1; then
        local key
        key="$iso_dir/$(basename "$release_key_url")"
        if [ -r "$key" ]; then
            local gnupg_home
            gnupg_home="$vm_dir/gnupg"
            mkdir -p "$gnupg_home"
            chmod 700 "$gnupg_home"
            GNUPGHOME="$gnupg_home" gpg --import "$key" >/dev/null 2>&1 || true
            GNUPGHOME="$gnupg_home" gpg --verify "$digests_path" || \
                printf 'warning: DIGESTS signature was not verified with the imported release key\n' >&2
            GNUPGHOME="$gnupg_home" gpg --verify "$sig_path" "$iso_path" || \
                printf 'warning: detached ISO signature was not verified with the imported release key\n' >&2
        else
            printf 'warning: release key not found; digest verified but PGP verification skipped\n' >&2
        fi
    else
        printf 'warning: gpg not found; digest verified but PGP verification skipped\n' >&2
    fi
}

extract_boot() {
    need bsdtar
    [ -r "$iso_path" ] || die "missing ISO: $iso_path"
    rm -rf "$boot_dir/extract"
    mkdir -p "$boot_dir/extract"
    bsdtar -C "$boot_dir/extract" -xf "$iso_path" images/pxeboot/vmlinuz images/pxeboot/initrd.img
}

iso_label() {
    need isoinfo
    isoinfo -d -i "$iso_path" | awk -F': ' '/^Volume id:/ {print $2; exit}'
}

ensure_dom0_key() {
    need ssh-keygen
    mkdirs
    if [ ! -e "$ssh_key" ]; then
        ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
    fi
}

write_kickstart() {
    need genisoimage
    ensure_dom0_key

    local pubkey
    local label
    pubkey="$(cat "$ssh_key.pub")"
    label="$(iso_label)"
    [ -n "$label" ] || die "could not read ISO label"

    cat > "$ks_dir/ks.cfg" <<EOF
#version=DEVEL
cmdline
eula --agreed
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone UTC --utc
network --bootproto=dhcp --device=enp0s3 --activate --hostname=qubes-nested
rootpw --plaintext $dom0_password
user --name=$dom0_user --groups=wheel,qubes --password=$dom0_password --plaintext --gecos="Qubes test user"
firewall --enabled
harddrive --partition=LABEL=$label --dir=/
zerombr
ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda
part biosboot --fstype=biosboot --size=1 --ondisk=sda
part /boot --fstype=ext4 --size=1024 --ondisk=sda
part pv.01 --size=118000 --ondisk=sda
volgroup qubes_dom0 pv.01
logvol / --vgname=qubes_dom0 --name=root --fstype=ext4 --size=40960
logvol swap --vgname=qubes_dom0 --name=swap --fstype=swap --size=4096
logvol none --vgname=qubes_dom0 --name=vm-pool --thinpool --size=71680
bootloader --location=mbr --append="console=tty0 console=hvc0"
poweroff

%packages
@^qubes-xfce
%end

%post --log=/root/qubes-nested-kickstart-post.log
set -eu
systemctl enable sshd || true
usermod -aG qubes $dom0_user || true
mkdir -p /etc/systemd/system/getty.target.wants
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@hvc0.service
ln -sf /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
ln -sf /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/multi-user.target.wants/serial-getty@hvc0.service
ln -sf /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/multi-user.target.wants/serial-getty@ttyS0.service
[ ! -e /usr/lib/systemd/system/sshd.service ] || ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service
if [ -f /etc/default/grub ]; then
    sed -i \
        -e 's/console=ttyS0,115200n8/console=tty0 console=hvc0/g' \
        -e 's/GRUB_CMDLINE_XEN_DEFAULT="console=none /GRUB_CMDLINE_XEN_DEFAULT="com1=115200,8n1 console=com1 /' \
        /etc/default/grub
fi
if [ -f /boot/grub2/grub.cfg ]; then
    sed -i \
        -e 's/console=none /com1=115200,8n1 console=com1 /g' \
        -e 's/console=ttyS0,115200n8/console=tty0 console=hvc0/g' \
        /boot/grub2/grub.cfg
fi
default_kernel="\$(find /var/lib/qubes/vm-kernels -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "\$default_kernel" ] && [ -f /var/lib/qubes/qubes.xml ] && ! grep -q 'name="default_kernel"' /var/lib/qubes/qubes.xml; then
    sed -i "/name=\"default_pool_kernel\"/a\\    <property name=\"default_kernel\">\$default_kernel</property>" /var/lib/qubes/qubes.xml
fi
mkdir -p /home/$dom0_user/.ssh
cat > /home/$dom0_user/.ssh/authorized_keys <<'KEY_EOF'
$pubkey
KEY_EOF
chown -R $dom0_user:$dom0_user /home/$dom0_user/.ssh
chmod 700 /home/$dom0_user/.ssh
chmod 600 /home/$dom0_user/.ssh/authorized_keys
cat > /etc/sudoers.d/90-qubes-nested-$dom0_user <<'SUDO_EOF'
$dom0_user ALL=(ALL) NOPASSWD: ALL
SUDO_EOF
chmod 0440 /etc/sudoers.d/90-qubes-nested-$dom0_user
restorecon -R /home/$dom0_user/.ssh /etc/sudoers.d/90-qubes-nested-$dom0_user || true
%end
EOF

    genisoimage -quiet -V OEMDRV -o "$ks_dir/oemdrv.iso" "$ks_dir/ks.cfg"
}

prepare() {
    mkdirs
    verify
    extract_boot
    write_kickstart
}

qemu_base_args() {
    local serial_backend="${1:-file:$serial_log}"
    printf '%q ' \
        -enable-kvm \
        -machine q35,kernel-irqchip=split \
        -cpu host,+vmx,+invtsc \
        -smp "$cpus" \
        -m "$memory" \
        -device virtio-scsi-pci,id=scsi0 \
        -drive "if=none,id=drive0,file=$disk_path,format=qcow2,cache=writeback,discard=unmap" \
        -device scsi-hd,drive=drive0 \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
        -device e1000e,netdev=n0 \
        -monitor "unix:$monitor_socket,server,nowait" \
        -display "vnc=127.0.0.1:$vnc_display" \
        -serial "$serial_backend"
}

install_vm() {
    need qemu-img
    need qemu-system-x86_64
    [ -r "$boot_dir/extract/images/pxeboot/vmlinuz" ] || die "run prepare first"
    [ -r "$boot_dir/extract/images/pxeboot/initrd.img" ] || die "run prepare first"
    [ -r "$ks_dir/oemdrv.iso" ] || die "run prepare first"
    [ -r "$iso_path" ] || die "missing ISO: $iso_path"

    if [ ! -e "$disk_path" ]; then
        qemu-img create -f qcow2 "$disk_path" "$disk_size"
    fi

    rm -f "$monitor_socket"
    : > "$serial_log"
    : > "$qemu_log"

    local append
    local label
    label="$(iso_label)"
    [ -n "$label" ] || die "could not read ISO label"
    append="inst.stage2=hd:LABEL=$label inst.repo=hd:LABEL=$label:/ inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.text console=ttyS0,115200n8"

    local cmd
    cmd="qemu-system-x86_64 $(qemu_base_args "file:$serial_log") -no-reboot -cdrom $(printf '%q' "$iso_path") -drive $(printf '%q' "file=$ks_dir/oemdrv.iso,media=cdrom,readonly=on") -kernel $(printf '%q' "$boot_dir/extract/images/pxeboot/vmlinuz") -initrd $(printf '%q' "$boot_dir/extract/images/pxeboot/initrd.img") -append $(printf '%q' "$append")"

    printf 'starting unattended Qubes install; serial log: %s\n' "$serial_log"
    printf 'VNC is on 127.0.0.1:%s on the host\n' "$((5900 + vnc_display))"
    set +e
    sudo bash -c "$cmd" >"$qemu_log" 2>&1 &
    local qemu_pid=$!
    tail -n +1 -F "$serial_log" &
    local tail_pid=$!
    wait "$qemu_pid"
    local status=$?
    kill "$tail_pid" >/dev/null 2>&1 || true
    wait "$tail_pid" >/dev/null 2>&1 || true
    set -e
    if grep -Eq \
        'The installation was stopped due to an error|Non interactive installation failed|Some packages, groups or modules are missing' \
        "$serial_log"; then
        die "Qubes installer reported failure; see $serial_log"
    fi
    [ "$status" -eq 0 ] || die "Qubes installer QEMU exited with status $status; see $qemu_log and $serial_log"
}

start_vm() {
    need qemu-system-x86_64
    [ -r "$disk_path" ] || die "missing disk: $disk_path"
    local extra_args=()
    local root_img="${ROOT_IMG:-}"
    if [ -n "$root_img" ]; then
        [ -r "$root_img" ] || die "missing ROOT_IMG: $root_img"
        extra_args+=(
            -drive "if=none,id=guixroot,file=$root_img,format=raw,readonly=on"
            -device "scsi-hd,drive=guixroot,serial=guixroot"
        )
    fi
    rm -f "$monitor_socket" "$serial_socket"
    : > "$serial_log"
    : > "$qemu_log"
    local extra_qemu_args=""
    if [ "${#extra_args[@]}" -gt 0 ]; then
        extra_qemu_args="$(printf '%q ' "${extra_args[@]}")"
    fi

    local cmd
    cmd="nohup qemu-system-x86_64 $(qemu_base_args "unix:$serial_socket,server,nowait") ${extra_qemu_args}-boot c >>$(printf '%q' "$qemu_log") 2>&1 & echo \$! > $(printf '%q' "$vm_dir/qemu.pid")"
    sudo bash -c "$cmd"
    for socket in "$monitor_socket" "$serial_socket"; do
        for _ in $(seq 1 50); do
            [ -S "$socket" ] || {
                sleep 0.1
                continue
            }
            sudo chown "$(id -u):$(id -g)" "$socket" || true
            break
        done
    done
    printf 'started nested Qubes dom0; serial socket: %s, SSH port: 127.0.0.1:%s, VNC: 127.0.0.1:%s\n' "$serial_socket" "$ssh_port" "$((5900 + vnc_display))"
}

stop_vm() {
    if [ -S "$monitor_socket" ]; then
        printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$monitor_socket" >/dev/null 2>&1 || true
        sleep 10
    fi
    if [ -r "$vm_dir/qemu.pid" ] && sudo kill -0 "$(cat "$vm_dir/qemu.pid")" >/dev/null 2>&1; then
        sudo kill "$(cat "$vm_dir/qemu.pid")" >/dev/null 2>&1 || true
    fi
}

status() {
    printf 'workdir: %s\n' "$workdir"
    printf 'iso: %s\n' "$iso_path"
    printf 'disk: %s\n' "$disk_path"
    printf 'root image copied path in dom0: /home/%s/root.img\n' "$dom0_user"
    printf 'ssh: ssh -i %q -p %s %s@127.0.0.1\n' "$ssh_key" "$ssh_port" "$dom0_user"
    printf 'serial socket: %s\n' "$serial_socket"
    printf 'vnc on host: 127.0.0.1:%s\n' "$((5900 + vnc_display))"
    if [ -r "$vm_dir/qemu.pid" ]; then
        if sudo kill -0 "$(cat "$vm_dir/qemu.pid")" >/dev/null 2>&1; then
            printf 'qemu pid: %s running\n' "$(cat "$vm_dir/qemu.pid")"
        else
            printf 'qemu pid: %s not running\n' "$(cat "$vm_dir/qemu.pid")"
        fi
    else
        printf 'qemu pid: none\n'
    fi
}

ssh_dom0() {
    ensure_dom0_key
    ssh -i "$ssh_key" -p "$ssh_port" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$vm_dir/known_hosts" \
        "$dom0_user@127.0.0.1" "$@"
}

wait_ssh() {
    local deadline
    deadline=$((SECONDS + 900))
    until ssh_dom0 true >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || die "timed out waiting for nested dom0 SSH"
        sleep 5
    done
    printf 'nested dom0 SSH is reachable\n'
}

serial_command() {
    [ "$#" -gt 0 ] || die "missing console command"
    [ -S "$serial_socket" ] || die "missing serial socket: $serial_socket"
    python3 - "$serial_socket" "$dom0_user" "$dom0_password" "$*" <<'PY'
import re
import select
import shlex
import socket
import sys
import time
import uuid

sock_path, user, password, command = sys.argv[1:5]

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
deadline = time.time() + 300
while True:
    try:
        sock.connect(sock_path)
        break
    except OSError:
        if time.time() >= deadline:
            raise
        time.sleep(1)

sock.setblocking(False)
buffer = b""


def send(line):
    sock.sendall(line.encode("utf-8") + b"\n")


def read_until(patterns, timeout, echo=True):
    global buffer
    compiled = [re.compile(pattern, re.I | re.S) for pattern in patterns]
    end = time.time() + timeout
    while time.time() < end:
        for index, pattern in enumerate(compiled):
            match = pattern.search(buffer)
            if match:
                return index, match
        readable, _, _ = select.select([sock], [], [], 0.2)
        if not readable:
            continue
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("serial console disconnected")
        buffer += chunk
        if echo:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    return None, None


send("")
index, _match = read_until(
    [rb"login:\s*$", rb"password:\s*$", rb"[$#]\s*$"],
    timeout=900,
)
if index is None:
    raise SystemExit("timed out waiting for serial login prompt")
if index == 0:
    send(user)
    index, _match = read_until([rb"password:\s*$"], timeout=60)
    if index is None:
        raise SystemExit("timed out waiting for serial password prompt")
    send(password)
    index, _match = read_until([rb"[$#]\s*$"], timeout=120)
    if index is None:
        raise SystemExit("timed out waiting for shell prompt after login")
elif index == 1:
    send(password)
    index, _match = read_until([rb"[$#]\s*$"], timeout=120)
    if index is None:
        raise SystemExit("timed out waiting for shell prompt after password")

sentinel = "__D{}__".format(uuid.uuid4().hex[:8])
buffer = b""
quoted_command = shlex.quote(command)
send("sudo -n bash -c {}; rc=$?; printf '\\n{}:%s\\n' \"$rc\"".format(
    quoted_command, sentinel))
_index, match = read_until(
    [re.escape(sentinel).encode("ascii") + rb":([0-9]+)"],
    timeout=7200,
)
if match is None:
    raise SystemExit("timed out waiting for serial command completion")
raise SystemExit(int(match.group(1)))
PY
}

wait_console() {
    serial_command true >/dev/null
    printf 'nested dom0 serial console is reachable\n'
}

serial_put_file() {
    local source="$1"
    local destination="$2"
    [ -r "$source" ] || die "missing source file: $source"
    [ -S "$serial_socket" ] || die "missing serial socket: $serial_socket"

    python3 - "$serial_socket" "$dom0_user" "$dom0_password" "$source" "$destination" <<'PY'
import base64
import os
import re
import select
import shlex
import socket
import sys
import time
import uuid

sock_path, user, password, source, destination = sys.argv[1:6]
with open(source, "rb") as source_file:
    payload = base64.encodebytes(source_file.read())
if not payload.endswith(b"\n"):
    payload += b"\n"

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
deadline = time.time() + 300
while True:
    try:
        sock.connect(sock_path)
        break
    except OSError:
        if time.time() >= deadline:
            raise
        time.sleep(1)

sock.setblocking(False)
buffer = b""


def send(line):
    sock.sendall(line.encode("utf-8") + b"\n")


def read_until(patterns, timeout, echo=True):
    global buffer
    compiled = [re.compile(pattern, re.I | re.S) for pattern in patterns]
    end = time.time() + timeout
    while time.time() < end:
        for index, pattern in enumerate(compiled):
            match = pattern.search(buffer)
            if match:
                return index, match
        readable, _, _ = select.select([sock], [], [], 0.2)
        if not readable:
            continue
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("serial console disconnected")
        buffer += chunk
        if echo:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    return None, None


send("")
index, _match = read_until(
    [rb"login:\s*$", rb"password:\s*$", rb"[$#]\s*$"],
    timeout=900,
)
if index is None:
    raise SystemExit("timed out waiting for serial login prompt")
if index == 0:
    send(user)
    index, _match = read_until([rb"password:\s*$"], timeout=60)
    if index is None:
        raise SystemExit("timed out waiting for serial password prompt")
    send(password)
    index, _match = read_until([rb"[$#]\s*$"], timeout=120)
    if index is None:
        raise SystemExit("timed out waiting for shell prompt after login")
elif index == 1:
    send(password)
    index, _match = read_until([rb"[$#]\s*$"], timeout=120)
    if index is None:
        raise SystemExit("timed out waiting for shell prompt after password")

sentinel = "__P{}__".format(uuid.uuid4().hex[:8])
payload_path = "/tmp/{}.{}.b64".format(os.path.basename(destination), os.getpid())
payload_path_q = shlex.quote(payload_path)
destination_q = shlex.quote(destination)
inner = (
    "cat > {payload}; rc=$?; "
    "if [ \"$rc\" -eq 0 ]; then "
    "base64 -d {payload} > {destination} && chmod +x {destination}; rc=$?; "
    "fi; "
    "rm -f {payload}; "
    "stty echo >/dev/null 2>&1 || true; "
    "printf '\\n{sentinel}:%s\\n' \"$rc\""
).format(
    payload=payload_path_q,
    destination=destination_q,
    sentinel=sentinel,
)

buffer = b""
send("stty -echo")
index, _match = read_until([rb"[$#]\s*$"], timeout=30, echo=False)
if index is None:
    raise SystemExit("timed out disabling serial echo")

send("sudo -n bash -c {}".format(shlex.quote(inner)))
for payload_line in payload.splitlines(keepends=True):
    sock.sendall(payload_line)
    time.sleep(0.05)
sock.sendall(b"\x04")
_index, match = read_until(
    [re.escape(sentinel).encode("ascii") + rb":([0-9]+)"],
    timeout=600,
)
if match is None:
    try:
        sock.sendall(b"\x03\nstty echo\n")
    except OSError:
        pass
    raise SystemExit("timed out waiting for serial file copy completion")
raise SystemExit(int(match.group(1)))
PY
}

copy_root() {
    local root_img="${ROOT_IMG:-root.img}"
    [ -r "$root_img" ] || die "missing ROOT_IMG: $root_img"
    wait_ssh
    scp -i "$ssh_key" -P "$ssh_port" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$vm_dir/known_hosts" \
        "$root_img" "$dom0_user@127.0.0.1:/home/$dom0_user/root.img"
}

import_test() {
    local root_img="${ROOT_IMG:-root.img}"
    [ -r scripts/import-native-rootfs-dom0.sh ] || die "run from repository root"
    [ -r scripts/test-native-guix-template-dom0.sh ] || die "run from repository root"
    if [ -S "$serial_socket" ]; then
        local root_device="${QUBES_NESTED_ROOT_DEVICE:-/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixroot}"
        wait_console
        serial_put_file scripts/import-native-rootfs-dom0.sh "/home/$dom0_user/import-native-rootfs-dom0.sh"
        serial_put_file scripts/test-native-guix-template-dom0.sh "/home/$dom0_user/test-native-guix-template-dom0.sh"
        serial_command "test -e $(printf '%q' "$root_device") || { lsblk; ls -l /dev/disk/by-id || true; exit 1; }"
        serial_command "for vm in guix-native-test-app guix-native-test; do
    if qvm-ls --raw-list | grep -Fxq \"\$vm\"; then
        qvm-shutdown --wait \"\$vm\" >/dev/null 2>&1 || true
        qvm-remove --force \"\$vm\"
    fi
done"
        serial_command "cd /home/$dom0_user && ./import-native-rootfs-dom0.sh --image $(printf '%q' "$root_device") --name guix-native-test --root-size 20G && ./test-native-guix-template-dom0.sh --template guix-native-test --keep-appvm"
        return
    fi

    [ -r "$root_img" ] || die "missing ROOT_IMG: $root_img"
    wait_ssh
    scp -i "$ssh_key" -P "$ssh_port" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$vm_dir/known_hosts" \
        "$root_img" \
        scripts/import-native-rootfs-dom0.sh \
        scripts/test-native-guix-template-dom0.sh \
        "$dom0_user@127.0.0.1:/home/$dom0_user/"
    ssh_dom0 chmod +x import-native-rootfs-dom0.sh test-native-guix-template-dom0.sh
    ssh_dom0 'for vm in guix-native-test-app guix-native-test; do if qvm-ls --raw-list | grep -Fxq "$vm"; then qvm-shutdown --wait "$vm" >/dev/null 2>&1 || true; qvm-remove --force "$vm"; fi; done'
    ssh_dom0 ./import-native-rootfs-dom0.sh --image root.img --name guix-native-test --root-size 20G
    ssh_dom0 ./test-native-guix-template-dom0.sh --template guix-native-test --keep-appvm
}

command="${1:-}"
case "$command" in
    download)
        download
        ;;
    verify)
        verify
        ;;
    prepare)
        prepare
        ;;
    install)
        install_vm
        ;;
    start)
        start_vm
        ;;
    stop)
        stop_vm
        ;;
    status)
        status
        ;;
    ssh)
        shift
        ssh_dom0 "$@"
        ;;
    wait-ssh)
        wait_ssh
        ;;
    console)
        shift
        serial_command "$@"
        ;;
    wait-console)
        wait_console
        ;;
    put-file)
        shift
        [ "$#" -eq 2 ] || die "usage: $0 put-file SOURCE DESTINATION"
        serial_put_file "$1" "$2"
        ;;
    copy-root)
        copy_root
        ;;
    import-test)
        import_test
        ;;
    -h|--help|help|'')
        usage
        ;;
    *)
        die "unknown command: $command"
        ;;
esac
