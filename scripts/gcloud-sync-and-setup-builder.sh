#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

instance="${INSTANCE_NAME:-qubes-guix-dev-0508}"
zone="${ZONE:-us-east1-d}"
remote_dir="${REMOTE_DIR:-~/guix}"

usage() {
    cat <<'EOF'
Usage: gcloud-sync-and-setup-builder.sh [options]

Copies this repository to a GCE builder and runs scripts/gcp-builder-setup.sh.

Options:
  --name NAME       Instance name. Default: qubes-guix-dev-0508
  --zone ZONE       Zone. Default: us-east1-d
  --remote DIR      Remote directory. Default: ~/guix
  -h, --help        Show help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            instance="${2:-}"
            shift 2
            ;;
        --zone)
            zone="${2:-}"
            shift 2
            ;;
        --remote)
            remote_dir="${2:-}"
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

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_archive="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$tmp_archive"' EXIT

tar -C "$repo_root" \
    --exclude='./root.img' \
    --exclude='./mnt.*' \
    --exclude='./work' \
    --exclude='./.cache' \
    -czf "$tmp_archive" .

gcloud compute ssh "$instance" --zone "$zone" --command "rm -rf $remote_dir && mkdir -p $remote_dir"
gcloud compute scp "$tmp_archive" "$instance:/tmp/qubes-guix-template.tar.gz" --zone "$zone"
gcloud compute ssh "$instance" --zone "$zone" --command "tar -C $remote_dir -xzf /tmp/qubes-guix-template.tar.gz && chmod +x $remote_dir/scripts/*.sh $remote_dir/tests/*.sh"
gcloud compute ssh "$instance" --zone "$zone" --command "WORKDIR=$remote_dir $remote_dir/scripts/gcp-builder-setup.sh"
