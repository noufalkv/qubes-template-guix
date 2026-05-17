#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

instance="${INSTANCE_NAME:-qubes-guix-dev-0508}"
zone="${ZONE:-us-east1-d}"
remote_dir="${REMOTE_DIR:-~/guix}"
dry_run=0

usage() {
    cat <<'EOF'
Usage: gcloud-sync-and-setup-builder.sh [options]

Copies this repository to a GCE builder and runs scripts/gcp-builder-setup.sh.

Options:
  --name NAME       Instance name. Default: qubes-guix-dev-0508
  --zone ZONE       Zone. Default: us-east1-d
  --remote DIR      Remote directory. Default: ~/guix
  --dry-run         Print the gcloud commands without running them.
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

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_path_expr() {
    case "$1" in
        "~")
            printf '$HOME'
            ;;
        "~/"*)
            printf '$HOME/%s' "$(shell_quote "${1#\~/}")"
            ;;
        *)
            shell_quote "$1"
            ;;
    esac
}

run_gcloud() {
    if [ "$dry_run" -eq 1 ]; then
        printf '+'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$@"
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
        --remote)
            require_arg "$@"
            remote_dir="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
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

[ -n "$remote_dir" ] || die "empty remote directory"
case "$remote_dir" in
    *$'\n'*|*$'\r'*) die "remote directory contains a newline" ;;
esac
remote_dir_expr="$(remote_path_expr "$remote_dir")"
remote_prepare_command="rm -rf -- $remote_dir_expr && mkdir -p -- $remote_dir_expr"
remote_unpack_command="tar -C $remote_dir_expr -xzf /tmp/qubes-guix-template.tar.gz && chmod +x $remote_dir_expr/scripts/*.sh $remote_dir_expr/tests/*.sh"
remote_setup_command="WORKDIR=$remote_dir_expr $remote_dir_expr/scripts/gcp-builder-setup.sh"

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$dry_run" -eq 1 ]; then
    tmp_archive="/tmp/qubes-guix-template.tar.gz"
    printf 'remote prepare command: %s\n' "$remote_prepare_command"
    printf 'remote unpack command: %s\n' "$remote_unpack_command"
    printf 'remote setup command: %s\n' "$remote_setup_command"
else
    tmp_archive="$(mktemp --suffix=.tar.gz)"
    trap 'rm -f "$tmp_archive"' EXIT

    tar -C "$repo_root" \
        --exclude='./root.img' \
        --exclude='./mnt.*' \
        --exclude='./work' \
        --exclude='./.cache' \
        -czf "$tmp_archive" .
fi

run_gcloud gcloud compute ssh "$instance" --zone "$zone" \
    --command "$remote_prepare_command"
run_gcloud gcloud compute scp "$tmp_archive" \
    "$instance:/tmp/qubes-guix-template.tar.gz" --zone "$zone"
run_gcloud gcloud compute ssh "$instance" --zone "$zone" \
    --command "$remote_unpack_command"
run_gcloud gcloud compute ssh "$instance" --zone "$zone" \
    --command "$remote_setup_command"
