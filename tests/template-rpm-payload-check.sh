#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
rpm_file=""
template_name=""
source_image=""
work_dir=""
own_work_dir=0
extract_dir=""
image_dir=""
extracted_image=""
rpmdb=""
template_dir=""
PATH="/usr/sbin:/sbin:$PATH"
export PATH

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: template-rpm-payload-check.sh --rpm FILE --template NAME --source-image FILE [options]

Options:
  --work-dir DIR        Existing scratch directory. Default: temporary.
  -h, --help            Show this help.
EOF
}

cleanup() {
    if [ "$own_work_dir" -eq 1 ] && [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --rpm)
                require_arg "$@"
                rpm_file="$2"
                shift 2
                ;;
            --template)
                require_arg "$@"
                template_name="$2"
                shift 2
                ;;
            --source-image)
                require_arg "$@"
                source_image="$2"
                shift 2
                ;;
            --work-dir)
                require_arg "$@"
                work_dir="$2"
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
}

check_requirements() {
    [ -n "$rpm_file" ] || die "missing --rpm"
    [ -r "$rpm_file" ] || die "RPM not readable: $rpm_file"
    [ -n "$template_name" ] || die "missing --template"
    [ -n "$source_image" ] || die "missing --source-image"
    [ -r "$source_image" ] || die "source image not readable: $source_image"

    need cmp
    need cpio
    need readlink
    need rpm
    need rpm2cpio
    need tar

    rpm_file="$(readlink -f "$rpm_file")"
    source_image="$(readlink -f "$source_image")"
}

prepare_workdir() {
    if [ -z "$work_dir" ]; then
        work_dir="$(mktemp -d "$repo_root/work.rpm-payload.XXXXXX")"
        own_work_dir=1
    else
        mkdir -p "$work_dir"
    fi

    extract_dir="$work_dir/extract-$template_name"
    image_dir="$work_dir/extracted-image-$template_name"
    extracted_image="$image_dir/root.img"
    rpmdb="$work_dir/rpmdb"
    template_dir="$extract_dir/var/lib/qubes/vm-templates/$template_name"

    rm -rf "$extract_dir" "$image_dir" "$rpmdb"
    mkdir -p "$extract_dir" "$rpmdb"
}

extract_rpm_payload() {
    local package_name

    package_name="$(rpm --dbpath "$rpmdb" -qp --qf '%{NAME}' "$rpm_file")"
    [ "$package_name" = "qubes-template-$template_name" ] ||
        die "unexpected RPM package name: $package_name"

    (
        cd "$extract_dir"
        cpio -idm --quiet < <(rpm2cpio "$rpm_file")
    )
}

verify_template_metadata() {
    local template_conf

    template_conf="$repo_root/builder-v2-template/template.conf"
    [ -d "$template_dir" ] || die "missing template payload directory: $template_dir"
    [ -r "$template_conf" ] || die "missing template metadata: $template_conf"
    cmp -s "$template_dir/template.conf" "$template_conf" ||
        die "unexpected template.conf payload: $template_dir/template.conf"
    "$repo_root/scripts/template-appmenus.sh" --check "$template_dir" "$template_name"
}

verify_template_directories() {
    local required_dir

    for required_dir in apps apps.templates apps.tempicons; do
        [ -d "$template_dir/$required_dir" ] ||
            die "missing $required_dir directory"
    done
    [ -f "$template_dir/clean-volatile.img.tar" ] ||
        die "missing clean-volatile.img.tar"
}

verify_rpm_file_metadata() {
    local header_dir="/var/lib/qubes/vm-templates/$template_name"
    local metadata="$work_dir/rpm-file-metadata.tsv"
    local file_path mode owner group

    rpm --dbpath "$rpmdb" -qp \
        --qf '[%{FILENAMES}\t%{FILEMODES:perms}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}\n]' \
        "$rpm_file" > "$metadata"

    assert_metadata() {
        local expected_path="$1"
        local expected_mode="$2"
        local row

        row="$(awk -F '\t' -v expected="$expected_path" \
            '$1 == expected { print; exit }' "$metadata")"
        [ -n "$row" ] || die "missing RPM metadata entry: $expected_path"
        IFS=$'\t' read -r file_path mode owner group <<< "$row"
        [ "$mode" = "$expected_mode" ] ||
            die "unexpected RPM mode for $expected_path: $mode"
        [ "$owner:$group" = root:qubes ] ||
            die "unexpected RPM owner for $expected_path: $owner:$group"
    }

    assert_metadata "$header_dir" drwxrws---
    for file_path in apps apps.templates apps.tempicons; do
        assert_metadata "$header_dir/$file_path" drwxrwxr-x
    done
    for file_path in \
        whitelisted-appmenus.list \
        vm-whitelisted-appmenus.list \
        netvm-whitelisted-appmenus.list \
        template.conf; do
        assert_metadata "$header_dir/$file_path" -rw-rw-r--
    done
    assert_metadata "$header_dir/clean-volatile.img.tar" -rw-rw----

    while IFS=$'\t' read -r file_path mode owner group; do
        case "$file_path" in
            "$header_dir"/root.img.part.*)
                [ "$mode" = -rw-rw---- ] ||
                    die "unexpected RPM mode for $file_path: $mode"
                [ "$owner:$group" = root:qubes ] ||
                    die "unexpected RPM owner for $file_path: $owner:$group"
                ;;
        esac
    done < "$metadata"
}

verify_ghost_images() {
    local ghost_image

    for ghost_image in root.img private.img volatile.img; do
        [ ! -e "$template_dir/$ghost_image" ] ||
            die "$ghost_image should be an RPM ghost"
    done
}

verify_split_root_image() {
    local root_parts=()

    shopt -s nullglob
    root_parts=("$template_dir"/root.img.part.*)
    shopt -u nullglob
    [ "${#root_parts[@]}" -ge 1 ] || die "missing split root image payload"

    mkdir -p "$image_dir"
    cat "${root_parts[@]}" | tar -C "$image_dir" -xf -
    cmp -s "$extracted_image" "$source_image" ||
        die "reassembled root image differs from source image"
}

main() {
    parse_args "$@"
    check_requirements
    prepare_workdir
    extract_rpm_payload
    verify_template_metadata
    verify_template_directories
    verify_rpm_file_metadata
    verify_ghost_images
    verify_split_root_image
    printf 'template RPM payload check passed: %s\n' "$rpm_file"
}

main "$@"
