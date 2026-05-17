#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
PATH="/usr/sbin:/sbin:$PATH"
export PATH

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tests_source="$repo_root/.cache/openqa-tests-qubesos"
tests_dest="/var/lib/openqa/share/tests/qubesos"
factory_hdd="/var/lib/openqa/share/factory/hdd"
nose2_rpm="${QUBES_OPENQA_NOSE2_RPM:-$repo_root/.cache/python3-nose2-0.15.1-3.fc41.noarch.rpm}"
nose2_rpm_url="${QUBES_OPENQA_NOSE2_RPM_URL:-https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/41/Everything/x86_64/os/Packages/p/python3-nose2-0.15.1-3.fc41.noarch.rpm}"
qubes_disk="${QUBES_OPENQA_QUBES_DISK:-/home/ubuntu/qubes-nested/vm/qubes-r4.3.0.qcow2}"
guix_root_image="${QUBES_OPENQA_GUIX_ROOT_IMAGE:-$repo_root/root.img}"
guix_template_rpm="${QUBES_OPENQA_GUIX_TEMPLATE_RPM:-}"
qubes_asset_name="${QUBES_OPENQA_QUBES_ASSET:-qubes-r4.3.0.qcow2}"
guix_asset_name="${QUBES_OPENQA_GUIX_ASSET:-guix-root.img}"
guix_rpm_asset_name="${QUBES_OPENQA_GUIX_RPM_ASSET:-guix-template-rpm.img}"
openqa_url="${QUBES_OPENQA_URL:-http://localhost:9526}"
build="${QUBES_OPENQA_BUILD:-guix-$(date -u +%Y%m%d%H%M%S)}"
template_name="${QUBES_OPENQA_TEMPLATE_NAME:-}"
appvm_name="${QUBES_OPENQA_APPVM_NAME:-guix-openqa-test-app}"
dom0_password="${QUBES_NESTED_DOM0_PASSWORD:-qubes}"
dom0_console="${QUBES_OPENQA_DOM0_CONSOLE:-root-console}"
dom0_type_max_interval="${QUBES_OPENQA_DOM0_TYPE_MAX_INTERVAL:-50}"
qemu_ram="${QUBES_OPENQA_RAM:-32768}"
qemu_cpus="${QUBES_OPENQA_CPUS:-8}"
install_mode="${GUIX_INSTALL_MODE:-}"
run_qubes_system_tests="${GUIX_RUN_QUBES_SYSTEM_TESTS:-0}"
qubes_system_tests="${GUIX_QUBES_SYSTEM_TESTS:-qubes.tests.integ.qrexec:14400 qubes.tests.integ.vm_qrexec_gui:14400}"
guix_expect_commands="${GUIX_EXPECT_COMMANDS:-}"
guix_expect_desktops="${GUIX_EXPECT_DESKTOPS:-}"
if [ -n "${GUIX_TEST_TIMEOUT:-}" ]; then
    guix_test_timeout="$GUIX_TEST_TIMEOUT"
elif [ "$run_qubes_system_tests" = "1" ]; then
    guix_test_timeout=21600
else
    guix_test_timeout=5400
fi
schedule_job=1
wait_job=0
rpm_asset_image=""
rpm_staging=""

usage() {
    cat <<'EOF'
Usage: setup-openqa-guix-template-test.sh [options]

Prepare an openQA host to test the native Guix System TemplateVM in a nested
Qubes dom0 VM, then schedule the job by default.

Options:
  --tests-source DIR       Qubes openQA test checkout. Default: .cache/openqa-tests-qubesos
  --qubes-disk FILE        Installed nested Qubes dom0 qcow2.
  --guix-root-image FILE   Native Guix root image. Default: ./root.img
  --template-rpm FILE      qvm-template RPM to install and test.
  --no-schedule            Only install tests/assets/openQA config.
  --wait                   Wait until the scheduled openQA job finishes.
  -h, --help               Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_nose2_rpm() {
    local tmp

    [ "$run_qubes_system_tests" = "1" ] || return 0
    if [ -r "$nose2_rpm" ]; then
        return
    fi

    need curl
    mkdir -p "$(dirname "$nose2_rpm")"
    tmp="$nose2_rpm.tmp.$$"
    rm -f "$tmp"
    curl -fL "$nose2_rpm_url" -o "$tmp"
    mv "$tmp" "$nose2_rpm"
}

cleanup() {
    if [ -n "$rpm_asset_image" ] && [ -e "$rpm_asset_image" ]; then
        rm -f "$rpm_asset_image"
    fi
    if [ -n "$rpm_staging" ] && [ -d "$rpm_staging" ]; then
        rm -rf "$rpm_staging"
    fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tests-source)
            tests_source="${2:-}"
            shift 2
            ;;
        --qubes-disk)
            qubes_disk="${2:-}"
            shift 2
            ;;
        --guix-root-image)
            guix_root_image="${2:-}"
            shift 2
            ;;
        --template-rpm)
            guix_template_rpm="${2:-}"
            shift 2
            ;;
        --no-schedule)
            schedule_job=0
            shift
            ;;
        --wait)
            wait_job=1
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

[ -n "$install_mode" ] || {
    if [ -n "$guix_template_rpm" ]; then
        install_mode="rpm"
    else
        install_mode="direct"
    fi
}
case "$install_mode" in
    direct|rpm) ;;
    *) die "unsupported GUIX_INSTALL_MODE: $install_mode" ;;
esac
if [ -z "$template_name" ]; then
    case "$install_mode" in
        rpm) template_name="guix" ;;
        *) template_name="guix-openqa-test" ;;
    esac
fi

[ -d "$tests_source" ] || die "missing Qubes openQA tests source: $tests_source"
[ -r "$tests_source/main.pm" ] || die "invalid Qubes openQA tests source: $tests_source"
[ -r "$qubes_disk" ] || die "missing nested Qubes disk: $qubes_disk"
[ -r "$guix_root_image" ] || die "missing Guix root image: $guix_root_image"
if [ "$install_mode" = "rpm" ]; then
    [ -r "$guix_template_rpm" ] || die "missing Guix template RPM: $guix_template_rpm"
fi
need openqa-cli
need jq
need rsync
need stat

if ! perl -MText::Glob -e1 >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y libtext-glob-perl
fi
ensure_nose2_rpm

sudo install -d -o geekotest -g root -m 0755 "$tests_dest" "$factory_hdd"
sudo rsync -a --delete --exclude .git "$tests_source"/ "$tests_dest"/
sudo rsync -a "$repo_root/openqa/qubesos"/ "$tests_dest"/
sudo install -d -o geekotest -g root -m 0755 "$tests_dest/data"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/import-native-rootfs-dom0.sh" \
    "$tests_dest/data/import-native-rootfs-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-native-guix-template-dom0.sh" \
    "$tests_dest/data/test-native-guix-template-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-guix-update-proxy-download-dom0.sh" \
    "$tests_dest/data/test-guix-update-proxy-download-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/diagnose-guix-postinstall-dom0.sh" \
    "$tests_dest/data/diagnose-guix-postinstall-dom0.sh"
if [ "$run_qubes_system_tests" = "1" ]; then
    sudo install -o geekotest -g root -m 0644 \
        "$nose2_rpm" \
        "$tests_dest/data/python3-nose2.rpm"
fi
sudo chown -R geekotest:root "$tests_dest"

copy_asset() {
    local src="$1"
    local name="$2"
    local dst="$factory_hdd/$name"
    local tmp="$dst.tmp.$$"

    if [ "$(readlink -f "$src")" = "$(readlink -f "$dst" 2>/dev/null || printf '%s' "$dst")" ]; then
        return
    fi

    # Snapshots are disabled for host-CPU nested virtualization, so the openQA
    # HDD asset is mutable. Refresh it on every scheduled run to avoid leaking
    # VM metadata or storage state from previous jobs.
    sudo cp -f --reflink=auto --sparse=always "$src" "$tmp"
    sudo chown geekotest:root "$tmp"
    sudo chmod 0644 "$tmp"
    sudo mv "$tmp" "$dst"
}

copy_qcow2_overlay_asset() {
    local src="$1"
    local name="$2"
    local dst="$factory_hdd/$name"
    local tmp="$dst.tmp.$$"
    local base="$factory_hdd/${name%.qcow2}-base.qcow2"
    local base_tmp="$base.tmp.$$"
    local backing_file

    if [ "$(readlink -f "$src")" = "$(readlink -f "$dst" 2>/dev/null || printf '%s' "$dst")" ]; then
        return
    fi

    # The nested Qubes HDD is large and mutable under openQA because snapshots
    # are disabled for host-CPU nested virtualization. Keep one pristine,
    # worker-readable base image in the openQA asset tree, then use a fresh
    # qcow2 overlay for each job so scheduling does not recopy the full image.
    if [ ! -r "$base" ] || [ "$src" -nt "$base" ]; then
        sudo cp -f --reflink=auto --sparse=always "$src" "$base_tmp"
        sudo chown geekotest:root "$base_tmp"
        sudo chmod 0644 "$base_tmp"
        sudo mv "$base_tmp" "$base"
    fi

    backing_file="$(readlink -f "$base")"
    sudo rm -f "$tmp"
    if sudo qemu-img create -q -f qcow2 -F qcow2 -b "$backing_file" "$tmp"; then
        sudo chown geekotest:root "$tmp"
        sudo chmod 0644 "$tmp"
        sudo mv "$tmp" "$dst"
    else
        sudo rm -f "$tmp"
        copy_asset "$src" "$name"
    fi
}

need qemu-img
copy_qcow2_overlay_asset "$qubes_disk" "$qubes_asset_name"
copy_asset "$guix_root_image" "$guix_asset_name"

if [ "$install_mode" = "rpm" ]; then
    need cp
    need mke2fs
    need mktemp
    need truncate
    rpm_asset_image="$(mktemp "$repo_root/work.openqa-rpm.XXXXXX.img")"
    rpm_staging="$(mktemp -d "$repo_root/work.openqa-rpm.XXXXXX")"
    rpm_bytes="$(stat -c '%s' "$guix_template_rpm")"
    rpm_image_bytes=$(( ((rpm_bytes + 67108864 + 1048575) / 1048576) * 1048576 ))
    truncate -s "$rpm_image_bytes" "$rpm_asset_image"
    cp "$guix_template_rpm" "$rpm_staging/$(basename "$guix_template_rpm")"
    cp "$repo_root/scripts/import-native-rootfs-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-native-guix-template-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-guix-update-proxy-config-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-guix-update-proxy-download-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/diagnose-guix-postinstall-dom0.sh" "$rpm_staging/"
    if [ "$run_qubes_system_tests" = "1" ]; then
        cp "$nose2_rpm" "$rpm_staging/python3-nose2.rpm"
    fi
    mke2fs -q -t ext4 -d "$rpm_staging" "$rpm_asset_image"
    rm -rf "$rpm_staging"
    copy_asset "$rpm_asset_image" "$guix_rpm_asset_name"
fi

client_key="$(openssl rand -hex 16)"
client_secret="$(openssl rand -hex 32)"
sudo install -d -o root -g root -m 0755 /etc/openqa
sudo tee /etc/openqa/client.conf >/dev/null <<EOF
[localhost]
key = $client_key
secret = $client_secret

[localhost:9526]
key = $client_key
secret = $client_secret

[http://localhost]
key = $client_key
secret = $client_secret

[http://localhost:9526]
key = $client_key
secret = $client_secret
EOF
if getent group _openqa-worker >/dev/null 2>&1; then
    sudo chown root:_openqa-worker /etc/openqa/client.conf
    sudo chmod 0640 /etc/openqa/client.conf
else
    sudo chown root:root /etc/openqa/client.conf
    sudo chmod 0644 /etc/openqa/client.conf
fi

sudo -u geekotest psql openqa >/dev/null <<SQL
INSERT INTO users (username, provider, email, fullname, nickname, is_operator, is_admin, t_created, t_updated)
VALUES ('openqa-worker', 'script', '', 'openQA Worker', 'openqa-worker', 1, 1, now(), now())
ON CONFLICT (username, provider) DO UPDATE
SET is_operator = 1, is_admin = 1, t_updated = now();

DELETE FROM api_keys
WHERE user_id = (SELECT id FROM users WHERE username = 'openqa-worker' AND provider = 'script');

INSERT INTO api_keys (key, secret, user_id, t_created, t_updated)
SELECT '$client_key', '$client_secret', id, now(), now()
FROM users
WHERE username = 'openqa-worker' AND provider = 'script';
SQL

sudo tee /etc/openqa/workers.ini >/dev/null <<'EOF'
[global]
HOST = http://localhost:9526
CACHEDIRECTORY = /var/lib/openqa/cache

[1]
WORKER_CLASS = qemu_x86_64,qemu_x86_64_staging
EOF

sudo systemctl reset-failed openqa-webui openqa-scheduler openqa-websockets openqa-livehandler openqa-worker-plain@1 >/dev/null 2>&1 || true
sudo systemctl restart openqa-webui openqa-scheduler openqa-websockets openqa-livehandler
sudo systemctl restart openqa-worker-cacheservice openqa-worker-cacheservice-minion >/dev/null 2>&1 || true
sudo systemctl restart openqa-worker-plain@1

for _ in $(seq 1 60); do
    if curl -fsS "$openqa_url/api/v1/jobs/overview" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl -fsS "$openqa_url/api/v1/jobs/overview" >/dev/null ||
    die "openQA web UI API did not become reachable"
sudo systemctl is-active --quiet openqa-worker-plain@1 ||
    die "openQA worker did not become active"

if [ "$schedule_job" -eq 0 ]; then
    printf 'openQA Guix template tests installed without scheduling a job\n'
    exit 0
fi

guix_root_bytes="$(stat -c '%s' "$guix_root_image")"
job_args=(
    DISTRI=qubesos
    VERSION=4.3
    FLAVOR=guix-template
    ARCH=x86_64
    BUILD="$build"
    TEST=guix_template
    MACHINE=qemu_x86_64
    BACKEND=qemu
    CASEDIR="$tests_dest"
    BOOTFROM=disk
    HDD_1="$qubes_asset_name"
    HDD_2="$guix_asset_name"
    NUMDISKS=2
    HDDMODEL=scsi-hd
    HDDMODEL_2=scsi-hd
    HDDSERIAL_2=guixroot
    QEMU_DISABLE_SNAPSHOTS=1
    QEMUMACHINE=q35,kernel-irqchip=split
    QEMUCPU=host,+vmx,+invtsc
    QEMURAM="$qemu_ram"
    QEMUCPUS="$qemu_cpus"
    VIRTIO_CONSOLE=1
    SERIALDEV=hvc0
    NICTYPE=user
    NICMODEL=e1000e
    WORKER_CLASS=qemu_x86_64
    QUBES_DOM0_USER=user
    QUBES_DOM0_PASSWORD="$dom0_password"
    QUBES_DOM0_CONSOLE="$dom0_console"
    QUBES_DOM0_TYPE_MAX_INTERVAL="$dom0_type_max_interval"
    QUBES_LOGIN_TIMEOUT=1200
    GUIX_INSTALL_MODE="$install_mode"
    GUIX_ROOT_DEVICE=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixroot
    GUIX_ROOT_BYTES="$guix_root_bytes"
    GUIX_ROOT_SIZE=20G
    GUIX_TEMPLATE_NAME="$template_name"
    GUIX_APPVM_NAME="$appvm_name"
    GUIX_RUN_QUBES_SYSTEM_TESTS="$run_qubes_system_tests"
    GUIX_QUBES_SYSTEM_TESTS="$qubes_system_tests"
    GUIX_EXPECT_COMMANDS="$guix_expect_commands"
    GUIX_EXPECT_DESKTOPS="$guix_expect_desktops"
    GUIX_TEST_TIMEOUT="$guix_test_timeout"
)

if [ "$install_mode" = "rpm" ]; then
    job_args=("${job_args[@]/NUMDISKS=2/NUMDISKS=3}")
    job_args+=(
        HDD_3="$guix_rpm_asset_name"
        HDDMODEL_3=scsi-hd
        HDDSERIAL_3=guixrpm
        GUIX_TEMPLATE_RPM_DEVICE=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixrpm
    )
fi

job_json="$(
    sudo openqa-cli api --host "$openqa_url" -X POST jobs "${job_args[@]}"
)"
job_id="$(printf '%s\n' "$job_json" | jq -r '.id // .ids[0] // .job_id // empty')"
[ -n "$job_id" ] || die "could not parse openQA job id from: $job_json"
printf 'scheduled openQA job %s\n' "$job_id"

if [ "$wait_job" -eq 0 ]; then
    exit 0
fi

while true; do
    job_state="$(sudo openqa-cli api --host "$openqa_url" "jobs/$job_id" | jq -r '.job.state + " " + (.job.result // "")')"
    printf '%s job %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$job_state"
    case "$job_state" in
        "done passed")
            exit 0
            ;;
        done\ *)
            exit 1
            ;;
    esac
    sleep 30
done
