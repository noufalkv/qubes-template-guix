#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
PATH="/usr/sbin:/sbin:$PATH"
export PATH

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tests_source="$repo_root/.cache/openqa-tests-qubesos"
tests_dest="/var/lib/openqa/share/tests/qubesos"
openqa_lock="${QUBES_OPENQA_LOCK:-/tmp/qubes-guix-openqa.lock}"
factory_hdd="/var/lib/openqa/share/factory/hdd"
qubes_version="${QUBES_VERSION:-4.3.0}"
openqa_version="${QUBES_OPENQA_VERSION:-${qubes_version%.*}}"
qubes_disk="${QUBES_OPENQA_QUBES_DISK:-}"
template_rpm="${QUBES_OPENQA_GUIX_TEMPLATE_RPM:-}"
qubes_asset_name="${QUBES_OPENQA_QUBES_ASSET:-qubes-r${qubes_version}.qcow2}"
guix_rpm_asset_name="${QUBES_OPENQA_GUIX_RPM_ASSET:-guix-template-rpm.img}"
openqa_url="${QUBES_OPENQA_URL:-http://localhost:9526}"
build="${QUBES_OPENQA_BUILD:-}"
variant="${QUBES_OPENQA_VARIANT:-}"
template_name="${QUBES_OPENQA_TEMPLATE_NAME:-}"
appvm_name="${QUBES_OPENQA_APPVM_NAME:-}"
appvm_netvm="${QUBES_OPENQA_APPVM_NETVM:-${QUBES_GUIX_APPVM_NETVM:-}}"
dom0_password="${QUBES_OPENQA_DOM0_PASSWORD:-qubes}"
dom0_console="${QUBES_OPENQA_DOM0_CONSOLE:-root-console}"
dom0_type_max_interval="${QUBES_OPENQA_DOM0_TYPE_MAX_INTERVAL:-100}"
dom0_ready_type_max_interval="${QUBES_OPENQA_DOM0_READY_TYPE_MAX_INTERVAL:-${QUBES_DOM0_READY_TYPE_MAX_INTERVAL:-$dom0_type_max_interval}}"
dom0_serial_settle_delay="${QUBES_OPENQA_DOM0_SERIAL_SETTLE_DELAY:-${QUBES_DOM0_SERIAL_SETTLE_DELAY:-3}}"
qemu_ram="${QUBES_OPENQA_RAM:-24576}"
qemu_cpus="${QUBES_OPENQA_CPUS:-8}"
qemu_append="${QUBES_OPENQA_QEMU_APPEND:-}"
max_job_time="${QUBES_OPENQA_MAX_JOB_TIME:-}"
run_proxy_download_test="${GUIX_RUN_PROXY_DOWNLOAD_TEST:-0}"
run_proxy_pull_test="${GUIX_RUN_PROXY_PULL_TEST:-0}"
run_central_vmupdate_test="${GUIX_RUN_CENTRAL_VMUPDATE_TEST:-0}"
guix_proxy_download_url="${GUIX_PROXY_DOWNLOAD_URL:-https://guix.gnu.org/}"
guix_proxy_download_timeout="${GUIX_PROXY_DOWNLOAD_TIMEOUT:-240}"
guix_proxy_pull_commit="${GUIX_PROXY_PULL_COMMIT:-}"
guix_proxy_pull_timeout="${GUIX_PROXY_PULL_TIMEOUT:-3600}"
guix_central_vmupdate_timeout="${GUIX_CENTRAL_VMUPDATE_TIMEOUT:-3600}"
guix_central_vmupdate_proxy_probe_url="${GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL:-https://codeberg.org/guix/guix.git}"
guix_test_timeout="${GUIX_TEST_TIMEOUT:-5400}"
wait_job=0
rpm_asset_image=""
rpm_staging=""
template_variant=""
rpm_asset_helpers=(
    diagnose-guix-postinstall-dom0.sh
    guest-update-proxy-preflight.sh
    test-guix-central-vmupdate-dom0.sh
    test-guix-update-proxy-dom0.sh
    test-native-guix-template-dom0.sh
)

usage() {
    cat <<'EOF'
Usage: run-openqa-template-rpm.sh [options]

Schedule RPM-mode openQA for an already built native Guix template RPM.
Template generation is handled separately by build-template-rpm.sh or Builder v2.

The host is expected to already have openQA services, workers, and client API
credentials configured.

Options:
  --variant normal|minimal  Template variant to validate. Default: normal.
  --tests-source DIR       Qubes openQA test checkout. Default: .cache/openqa-tests-qubesos
  --qubes-disk FILE        Installed nested Qubes dom0 qcow2. Required unless
                           QUBES_OPENQA_QUBES_DISK is set.
  --template-rpm FILE      qvm-template RPM to install and test.
  --build NAME             openQA BUILD value. Default: generated timestamp.
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

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

cleanup() {
    if [ -n "$rpm_asset_image" ]; then
        rm -f "$rpm_asset_image"
    fi
    if [ -n "$rpm_staging" ]; then
        rm -rf "$rpm_staging"
    fi
}
trap cleanup EXIT

set_variant_defaults() {
    local selected_variant=""

    if [ -n "$variant" ]; then
        selected_variant="$("$repo_root/scripts/template-variant.sh" "$variant" variant)"
    fi
    if [ -z "$template_name" ]; then
        template_variant="${selected_variant:-normal}"
        template_name="$("$repo_root/scripts/template-variant.sh" "$template_variant" template-name)"
    else
        template_variant="$("$repo_root/scripts/template-variant.sh" "$template_name" variant)"
        [ -z "$selected_variant" ] || [ "$template_variant" = "$selected_variant" ] ||
            die "template name $template_name does not match variant $selected_variant"
        template_name="$("$repo_root/scripts/template-variant.sh" "$template_variant" template-name)"
    fi

    if [ -z "$appvm_name" ]; then
        appvm_name="$template_name-openqa-test-app"
    fi
    : "${build:=guix-${template_variant}-rpm-$(date -u +%Y%m%d%H%M)}"
}

warn_about_optional_update_target() {
    if [ "$run_central_vmupdate_test" = "1" ]; then
        cat >&2 <<'EOF'
warning: GUIX_RUN_CENTRAL_VMUPDATE_TEST=1 requires the nested dom0 to have a
warning: standard Internet-capable Qubes updates-proxy target, normally sys-net.
EOF
    fi
}

validate_inputs() {
    local rpm_name

    [ -d "$tests_source" ] || die "missing Qubes openQA tests source: $tests_source"
    [ -r "$tests_source/main.pm" ] || die "invalid Qubes openQA tests source: $tests_source"
    [ -n "$qubes_disk" ] || die "missing --qubes-disk or QUBES_OPENQA_QUBES_DISK"
    [ -r "$qubes_disk" ] || die "missing nested Qubes disk: $qubes_disk"
    [ -r "$template_rpm" ] || die "missing Guix template RPM: $template_rpm"

    need rpm
    rpm_name="$(rpm -qp --qf '%{NAME}' "$template_rpm")"
    [ "$rpm_name" = "qubes-template-$template_name" ] ||
        die "template RPM $rpm_name does not match selected template $template_name"

    if [ -z "$max_job_time" ] && [ "$run_central_vmupdate_test" = "1" ]; then
        max_job_time=21600
    elif [ -z "$max_job_time" ] && [ "$run_proxy_pull_test" = "1" ]; then
        max_job_time=7200
    fi
}

positive_int() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9]*)
            die "$name must be a positive integer"
            ;;
    esac
    [ "$value" -gt 0 ] || die "$name must be greater than zero"
}

flag() {
    local name="$1"
    local value="$2"

    case "$value" in
        0|1) ;;
        *) die "$name must be 0 or 1" ;;
    esac
}

validate_git_commit() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9a-fA-F]*)
            die "$name must be a full 40-hex Git commit"
            ;;
    esac
    [ "${#value}" -eq 40 ] ||
        die "$name must be a full 40-hex Git commit"
}

default_proxy_pull_commit() {
    local commit

    commit="$(awk -F\" '/^[[:space:]]*\(commit / { print $2; exit }' \
        "$repo_root/config/channels.scm")"
    validate_git_commit "config/channels.scm commit" "$commit"
    printf '%s\n' "$commit"
}

prepare_optional_guix_proxy_checks() {
    flag GUIX_RUN_PROXY_DOWNLOAD_TEST "$run_proxy_download_test"
    flag GUIX_RUN_PROXY_PULL_TEST "$run_proxy_pull_test"
    flag GUIX_RUN_CENTRAL_VMUPDATE_TEST "$run_central_vmupdate_test"

    if [ "$run_proxy_download_test" = "1" ]; then
        positive_int GUIX_PROXY_DOWNLOAD_TIMEOUT "$guix_proxy_download_timeout"
    fi
    if [ "$run_central_vmupdate_test" = "1" ]; then
        positive_int GUIX_CENTRAL_VMUPDATE_TIMEOUT "$guix_central_vmupdate_timeout"
    fi

    [ "$run_proxy_pull_test" = "1" ] || return 0

    positive_int GUIX_PROXY_PULL_TIMEOUT "$guix_proxy_pull_timeout"
    if [ -z "$guix_proxy_pull_commit" ]; then
        guix_proxy_pull_commit="$(default_proxy_pull_commit)"
    else
        validate_git_commit GUIX_PROXY_PULL_COMMIT "$guix_proxy_pull_commit"
    fi
}

check_host_tools() {
    need curl
    need jq
    need openqa-cli
    need readlink
    need sudo
}

install_openqa_test_tree() {
    need flock
    need rsync
    need sudo

    exec 9>"$openqa_lock"
    flock 9

    sudo install -d -o geekotest -g root -m 0755 "$tests_dest" "$factory_hdd"
    sudo rsync -a --delete --exclude .git "$tests_source"/ "$tests_dest"/
    sudo rsync -a "$repo_root/openqa/qubesos"/ "$tests_dest"/
    sudo chown -R geekotest:root "$tests_dest"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --variant)
                require_arg "$@"
                variant="$2"
                shift 2
                ;;
            --tests-source)
                require_arg "$@"
                tests_source="$2"
                shift 2
                ;;
            --qubes-disk)
                require_arg "$@"
                qubes_disk="$2"
                shift 2
                ;;
            --template-rpm)
                require_arg "$@"
                template_rpm="$2"
                shift 2
                ;;
            --build)
                require_arg "$@"
                build="$2"
                shift 2
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
}

same_resolved_path() {
    local left="$1"
    local right="$2"

    [ "$(readlink -f "$left")" = "$(readlink -f "$right" 2>/dev/null || printf '%s\n' "$right")" ]
}

copy_asset() {
    local src="$1"
    local name="$2"
    local dst="$factory_hdd/$name"
    local tmp="$dst.tmp.$$"

    if same_resolved_path "$src" "$dst"; then
        return
    fi

    # Snapshots are disabled for host-CPU nested virtualization, so the openQA
    # HDD asset is mutable. Refresh it on every scheduled run to avoid leaking
    # VM metadata or storage state from previous jobs.
    sudo cp -f --reflink=auto --sparse=always "$src" "$tmp"
    publish_asset "$tmp" "$dst"
}

publish_asset() {
    local tmp="$1"
    local dst="$2"

    sudo chown geekotest:root "$tmp"
    sudo chmod 0644 "$tmp"
    sudo mv "$tmp" "$dst"
}

copy_qcow2_job_asset() {
    local src="$1"
    local name="$2"
    local dst="$factory_hdd/$name"
    local tmp="$dst.tmp.$$"
    local base="$factory_hdd/${name%.qcow2}-base.qcow2"
    local base_tmp="$base.tmp.$$"
    local backing_file

    if same_resolved_path "$src" "$dst"; then
        return
    fi

    if ! command -v qemu-img >/dev/null 2>&1; then
        copy_asset "$src" "$name"
        return
    fi

    # The nested Qubes HDD is large and mutable under openQA because snapshots
    # are disabled for host-CPU nested virtualization. Keep one pristine,
    # worker-readable base image in the asset tree, then create a fresh qcow2
    # job disk that points at it.
    if [ ! -r "$base" ] || [ "$src" -nt "$base" ]; then
        sudo cp -f --reflink=auto --sparse=always "$src" "$base_tmp"
        publish_asset "$base_tmp" "$base"
    fi

    backing_file="$(readlink -f "$base")"
    sudo rm -f "$tmp"
    if sudo qemu-img create -q -f qcow2 -F qcow2 -b "$backing_file" "$tmp"; then
        publish_asset "$tmp" "$dst"
    else
        sudo rm -f "$tmp"
        copy_asset "$src" "$name"
    fi
}

stage_qubes_disk_asset() {
    copy_qcow2_job_asset "$qubes_disk" "$qubes_asset_name"
}

stage_template_rpm_asset() {
    local rpm_basename rpm_bytes rpm_image_overhead rpm_image_bytes

    need cp
    need mke2fs
    need mktemp
    need stat
    need truncate

    rpm_asset_image="$(mktemp "$repo_root/work.openqa-rpm.XXXXXX.img")"
    rpm_staging="$(mktemp -d "$repo_root/work.openqa-rpm.XXXXXX")"
    rpm_basename="$(basename "$template_rpm")"
    rpm_bytes="$(stat -c '%s' "$template_rpm")"
    rpm_image_overhead=$((rpm_bytes / 10 + 268435456))
    rpm_image_bytes=$(( ((rpm_bytes + rpm_image_overhead + 1048575) / 1048576) * 1048576 ))

    truncate -s "$rpm_image_bytes" "$rpm_asset_image"
    cp "$template_rpm" "$rpm_staging/$rpm_basename"
    for helper in "${rpm_asset_helpers[@]}"; do
        [ -r "$repo_root/scripts/$helper" ] ||
            die "missing RPM asset helper: scripts/$helper"
        cp "$repo_root/scripts/$helper" "$rpm_staging/"
    done
    mke2fs -q -t ext4 -m 0 -d "$rpm_staging" "$rpm_asset_image"
    rm -rf "$rpm_staging"
    rpm_staging=""
    copy_asset "$rpm_asset_image" "$guix_rpm_asset_name"
}

stage_assets() {
    stage_qubes_disk_asset
    stage_template_rpm_asset
}

wait_for_openqa_api() {
    local _

    for _ in $(seq 1 60); do
        if curl -fsS "$openqa_url/api/v1/jobs/overview" >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done

    die "openQA web UI API did not become reachable"
}

schedule_openqa_job() {
    local job_args job_json job_id

    job_args=(
        DISTRI=qubesos
        VERSION="$openqa_version"
        FLAVOR=guix-template
        ARCH=x86_64
        BUILD="$build"
        TEST=guix_template
        MACHINE=qemu_x86_64
        BACKEND=qemu
        CASEDIR="$tests_dest"
        BOOTFROM=disk
        HDD_1="$qubes_asset_name"
        HDDMODEL=scsi-hd
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
        QUBES_DOM0_READY_TYPE_MAX_INTERVAL="$dom0_ready_type_max_interval"
        QUBES_DOM0_SERIAL_SETTLE_DELAY="$dom0_serial_settle_delay"
        QUBES_LOGIN_TIMEOUT=1200
        GUIX_TEMPLATE_NAME="$template_name"
        GUIX_APPVM_NAME="$appvm_name"
        GUIX_APPVM_NETVM="$appvm_netvm"
        GUIX_RUN_PROXY_DOWNLOAD_TEST="$run_proxy_download_test"
        GUIX_RUN_PROXY_PULL_TEST="$run_proxy_pull_test"
        GUIX_RUN_CENTRAL_VMUPDATE_TEST="$run_central_vmupdate_test"
        GUIX_PROXY_DOWNLOAD_URL="$guix_proxy_download_url"
        GUIX_PROXY_DOWNLOAD_TIMEOUT="$guix_proxy_download_timeout"
        GUIX_PROXY_PULL_COMMIT="$guix_proxy_pull_commit"
        GUIX_PROXY_PULL_TIMEOUT="$guix_proxy_pull_timeout"
        GUIX_CENTRAL_VMUPDATE_TIMEOUT="$guix_central_vmupdate_timeout"
        GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL="$guix_central_vmupdate_proxy_probe_url"
        GUIX_TEST_TIMEOUT="$guix_test_timeout"
    )

    if [ -n "$qemu_append" ]; then
        job_args+=(QEMU_APPEND="$qemu_append")
    fi
    if [ -n "$max_job_time" ]; then
        job_args+=(MAX_JOB_TIME="$max_job_time")
    fi

    job_args+=(
        HDD_2="$guix_rpm_asset_name"
        NUMDISKS=2
        HDDMODEL_2=scsi-hd
        HDDSERIAL_2=guixrpm
        GUIX_TEMPLATE_RPM_DEVICE=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixrpm
    )

    job_json="$(openqa-cli api --host "$openqa_url" -X POST jobs "${job_args[@]}")"
    job_id="$(printf '%s\n' "$job_json" | jq -r '.id // .ids[0] // .job_id // empty')"
    [ -n "$job_id" ] || die "could not parse openQA job id from: $job_json"
    printf '%s\n' "$job_id"
}

wait_for_job() {
    local job_id="$1"
    local job_state

    while true; do
        job_state="$(openqa-cli api --host "$openqa_url" "jobs/$job_id" | jq -r '.job.state + " " + (.job.result // "")')"
        printf '%s job %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$job_state"
        case "$job_state" in
            "done passed")
                return 0
                ;;
            done\ *)
                return 1
                ;;
        esac
        sleep 30
    done
}

main() {
    local job_id

    parse_args "$@"
    set_variant_defaults
    prepare_optional_guix_proxy_checks
    warn_about_optional_update_target
    validate_inputs
    check_host_tools
    install_openqa_test_tree
    stage_assets

    wait_for_openqa_api
    job_id="$(schedule_openqa_job)"
    printf 'scheduled openQA job %s\n' "$job_id"

    if [ "$wait_job" -eq 1 ]; then
        wait_for_job "$job_id"
    fi
}

main "$@"
