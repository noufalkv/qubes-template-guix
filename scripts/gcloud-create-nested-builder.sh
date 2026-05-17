#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

instance="${INSTANCE_NAME:-qubes-guix-dev-0508}"
zone="${ZONE:-us-east1-d}"
machine_type="${MACHINE_TYPE:-n2-standard-8}"
disk_size="${DISK_SIZE:-200GB}"
image_family="${IMAGE_FAMILY:-debian-12}"
image_project="${IMAGE_PROJECT:-debian-cloud}"
project="${PROJECT:-}"

usage() {
    cat <<'EOF'
Usage: gcloud-create-nested-builder.sh [options]

Creates a Google Compute Engine VM with nested virtualization enabled. Run as
the account that has gcloud configured.

Options:
  --name NAME       Instance name. Default: qubes-guix-dev-0508
  --zone ZONE       Zone. Default: us-east1-d
  --type TYPE       Machine type. Default: n2-standard-8
  --disk SIZE       Boot disk size. Default: 200GB
  --project ID      GCP project. Default: active gcloud project
  -h, --help        Show help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            require_arg "$@"
            instance="$2"
            shift 2
            ;;
        --zone)
            require_arg "$@"
            zone="$2"
            shift 2
            ;;
        --type)
            require_arg "$@"
            machine_type="$2"
            shift 2
            ;;
        --disk)
            require_arg "$@"
            disk_size="$2"
            shift 2
            ;;
        --project)
            require_arg "$@"
            project="$2"
            shift 2
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

project_args=()
[ -n "$project" ] && project_args=(--project "$project")

if gcloud compute instances describe "$instance" --zone "$zone" "${project_args[@]}" >/dev/null 2>&1; then
    printf 'instance already exists: %s (%s)\n' "$instance" "$zone"
    exit 0
fi

gcloud compute instances create "$instance" \
    --zone "$zone" \
    --machine-type "$machine_type" \
    --enable-nested-virtualization \
    --min-cpu-platform "Intel Cascade Lake" \
    --boot-disk-size "$disk_size" \
    --boot-disk-type pd-ssd \
    --image-family "$image_family" \
    --image-project "$image_project" \
    --metadata enable-oslogin=FALSE \
    --tags qubes-guix-dev \
    "${project_args[@]}"

printf 'created nested virtualization builder: %s (%s)\n' "$instance" "$zone"
