#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root_image="$repo_root/root.img"
template_name="guix"
version="$(date -u +%Y%m%d)"
release="1"
output_dir="$repo_root/dist"
split_size="1900M"
workdir=""
payload=""
image_dir=""
topdir=""
template_dir=""
spec=""
template_conf=""
rpm_path=""
PATH="/usr/sbin:/sbin:$PATH"
export PATH

# shellcheck source=scripts/lib.sh
. "$repo_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: package-native-template-rpm.sh [options]

Build a qvm-template-compatible RPM for the native Guix System TemplateVM.

Options:
  --root-image FILE   Root image to package. Default: ./root.img
  --name NAME         Template name: guix or guix-minimal. Default: guix
  --version VERSION   RPM version. Default: current UTC date as YYYYMMDD
  --release RELEASE   RPM release. Default: 1
  --output-dir DIR    Directory for the RPM. Default: ./dist
  --split-size SIZE   Split size for root.img.part.NN. Default: 1900M
  -h, --help          Show this help.

The generated package follows the Qubes qvm-template package layout:
  var/lib/qubes/vm-templates/NAME/root.img.part.NN
  var/lib/qubes/vm-templates/NAME/template.conf
  var/lib/qubes/vm-templates/NAME/*whitelisted-appmenus.list
EOF
}

validate_version_field() {
    local value="$1"
    local label="$2"
    local LC_ALL=C

    # These values are interpolated into both an RPM spec and the expected
    # output filename.  Match the ASCII label grammar consumed by
    # qvm-template; a denylist can miss spec macros (%{...}), quotes, carriage
    # returns, non-ASCII characters, or future RPM syntax.
    [[ "$value" =~ ^[A-Za-z0-9._+~]+$ ]] ||
        die "$label is not a safe RPM version field: $value"
}

cleanup() {
    if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        rm -rf "$workdir"
    fi
}
trap cleanup EXIT

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root-image)
                require_arg "$@"
                root_image="$2"
                shift 2
                ;;
            --name)
                require_arg "$@"
                template_name="$2"
                shift 2
                ;;
            --version)
                require_arg "$@"
                version="$2"
                shift 2
                ;;
            --release)
                require_arg "$@"
                release="$2"
                shift 2
                ;;
            --output-dir)
                require_arg "$@"
                output_dir="$2"
                shift 2
                ;;
            --split-size)
                require_arg "$@"
                split_size="$2"
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
    template_name="$("$repo_root/scripts/template-variant.sh" "$template_name" template-name)"
    validate_version_field "$version" "version"
    validate_version_field "$release" "release"

    need cp
    need rpmbuild
    need split
    need tar

    [ -r "$root_image" ] || die "root image not readable: $root_image"
}

prepare_workdir() {
    workdir="$(mktemp -d "$repo_root/work.package.XXXXXX")"
    payload="$workdir/payload"
    image_dir="$workdir/image"
    topdir="$workdir/rpmbuild"
    template_dir="$payload/var/lib/qubes/vm-templates/$template_name"
    spec="$topdir/SPECS/qubes-template-$template_name.spec"
    template_conf="$repo_root/builder-v2-template/template.conf"

    mkdir -p "$template_dir" "$image_dir" "$topdir/BUILD" "$topdir/BUILDROOT" \
        "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS" \
        "$topdir/rpmdb" "$output_dir"
}

stage_payload() {
    [ -r "$template_conf" ] || die "missing template metadata: $template_conf"

    cp --reflink=auto --sparse=always "$root_image" "$image_dir/root.img"
    tar -C "$image_dir" -Scf - root.img |
        split -d -a 2 -b "$split_size" - "$template_dir/root.img.part."

    cp "$template_conf" "$template_dir/template.conf"
    mkdir -p "$template_dir/apps" "$template_dir/apps.templates" "$template_dir/apps.tempicons"
    : > "$template_dir/clean-volatile.img.tar"
    "$repo_root/scripts/template-appmenus.sh" --install "$template_dir" "$template_name"
}

write_spec() {
    local description summary

    summary="GNU Guix System Qubes template"
    description="Native GNU Guix System TemplateVM for Qubes OS with QubesDB,"
    description+=" qrexec, and Qubes private-volume persistence support."

    cat > "$spec" <<EOF
%define dest_dir /var/lib/qubes/vm-templates/$template_name
%define _binaries_in_noarch_packages_terminate_build 0

Name: qubes-template-$template_name
Version: $version
Release: $release
Summary: $summary
License: GPLv3+
URL: https://www.qubes-os.org/
Requires: xdg-utils
Requires(post): tar
BuildArch: noarch
Provides: qubes-template
Obsoletes: %{name} < $version-$release
AutoReqProv: no

%description
$description

%install
rm -rf "%{buildroot}"
mkdir -p "%{buildroot}%{dest_dir}"
cp -a "$template_dir"/. "%{buildroot}%{dest_dir}"/
touch "%{buildroot}%{dest_dir}/root.img"
touch "%{buildroot}%{dest_dir}/private.img"
touch "%{buildroot}%{dest_dir}/volatile.img"

%pre
echo "***** ERROR: do not install template using rpm/dnf or similar" >&2
echo "*****        use 'qvm-template install' instead" >&2
exit 1

%clean
rm -rf "%{buildroot}"

%files
%defattr(0660,root,qubes,0770)
%attr(2770,root,qubes) %dir %{dest_dir}

%ghost %{dest_dir}/root.img
%ghost %{dest_dir}/private.img
%ghost %{dest_dir}/volatile.img

%{dest_dir}/root.img.part.*
%{dest_dir}/clean-volatile.img.tar

%attr(0775,root,qubes) %dir %{dest_dir}/apps
%attr(0775,root,qubes) %dir %{dest_dir}/apps.templates
%attr(0775,root,qubes) %dir %{dest_dir}/apps.tempicons
%attr(0664,root,qubes) %{dest_dir}/*whitelisted-appmenus.list
%attr(0664,root,qubes) %{dest_dir}/template.conf
EOF
}

build_rpm() {
    rpmbuild -bb \
        --define "_topdir $topdir" \
        --define "_dbpath $topdir/rpmdb" \
        --define "_build_id_links none" \
        "$spec" >&2

    rpm_path="$topdir/RPMS/noarch/qubes-template-$template_name-$version-$release.noarch.rpm"
    [ -s "$rpm_path" ] || die "rpmbuild did not produce an RPM: $rpm_path"
}

publish_rpm() {
    cp -f "$rpm_path" "$output_dir/"
    printf '%s\n' "$output_dir/$(basename "$rpm_path")"
}

main() {
    parse_args "$@"
    check_requirements
    prepare_workdir
    stage_payload
    write_spec
    build_rpm
    publish_rpm
}

main "$@"
