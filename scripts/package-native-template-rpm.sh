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
gui_enabled="1"
shrink_image=1
appmenu_entries=()
appmenu_entries_set=0
workdir=""
PATH="/usr/sbin:/sbin:$PATH"
export PATH

usage() {
    cat <<'EOF'
Usage: package-native-template-rpm.sh [options]

Build a qvm-template-compatible RPM for the native Guix System TemplateVM.

Options:
  --root-image FILE   Root image to package. Default: ./root.img
  --name NAME         Template name. Package name becomes qubes-template-NAME.
                      Default: guix
  --version VERSION   RPM version. Default: current UTC date as YYYYMMDD
  --release RELEASE   RPM release. Default: 1
  --output-dir DIR    Directory for the RPM. Default: ./dist
  --split-size SIZE   Split size for root.img.part.NN. Default: 1900M
  --gui 0|1           Advertise GUI support status. Default: 1.
  --appmenu-entry ID  Add a desktop-file ID to Qubes appmenu allowlists.
                      Defaults to xfce4-terminal.desktop for normal names and
                      xterm.desktop for names ending in -minimal.
  --no-shrink         Do not minimize the ext4 root image before packaging.
  -h, --help          Show this help.

The generated package follows the Qubes qvm-template package layout:
  var/lib/qubes/vm-templates/NAME/root.img.part.NN
  var/lib/qubes/vm-templates/NAME/template.conf
  var/lib/qubes/vm-templates/NAME/*whitelisted-appmenus.list
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

validate_never_pipe() {
    case "$1" in
        *'|'*) die "$2 must not contain |" ;;
    esac
}

validate_component() {
    local value="$1"
    local label="$2"

    [ -n "$value" ] || die "$label must not be empty"
    validate_never_pipe "$value" "$label"
    case "$value" in
        */*|*' '*|*$'\t'*|*$'\n'*) die "$label contains an unsupported character: $value" ;;
    esac
}

validate_version_field() {
    local value="$1"
    local label="$2"

    [ -n "$value" ] || die "$label must not be empty"
    validate_never_pipe "$value" "$label"
    case "$value" in
        *-*|*/*|*' '*|*$'\t'*|*$'\n'*) die "$label contains an unsupported RPM character: $value" ;;
    esac
}

cleanup() {
    if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        rm -rf "$workdir"
    fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root-image)
            root_image="${2:-}"
            shift 2
            ;;
        --name)
            template_name="${2:-}"
            shift 2
            ;;
        --version)
            version="${2:-}"
            shift 2
            ;;
        --release)
            release="${2:-}"
            shift 2
            ;;
        --output-dir)
            output_dir="${2:-}"
            shift 2
            ;;
        --split-size)
            split_size="${2:-}"
            shift 2
            ;;
        --gui)
            gui_enabled="${2:-}"
            shift 2
            ;;
        --appmenu-entry)
            appmenu_entries+=("${2:-}")
            appmenu_entries_set=1
            shift 2
            ;;
        --no-shrink)
            shrink_image=0
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

need awk
need cp
need rpmbuild
need split
need tar
if [ "$shrink_image" -eq 1 ]; then
    need du
    need e2fsck
    need resize2fs
    need stat
fi

[ -r "$root_image" ] || die "root image not readable: $root_image"
case "$gui_enabled" in
    ""|0|1) ;;
    *) die "--gui must be 0 or 1" ;;
esac
validate_component "$template_name" "template name"
validate_version_field "$version" "version"
validate_version_field "$release" "release"
if [ "${#appmenu_entries[@]}" -eq 0 ] && [ "$appmenu_entries_set" -eq 0 ]; then
    case "$template_name" in
        *-minimal) appmenu_entries=(xterm.desktop) ;;
        *) appmenu_entries=(xfce4-terminal.desktop) ;;
    esac
fi
for appmenu_entry in "${appmenu_entries[@]}"; do
    validate_component "$appmenu_entry" "appmenu entry"
done

summary="GNU Guix System Qubes template"
description="Native GNU Guix System TemplateVM for Qubes OS with QubesDB, qrexec, and Qubes private-volume persistence support."
validate_never_pipe "$summary" "summary"
validate_never_pipe "$description" "description"

workdir="$(mktemp -d "$repo_root/work.package.XXXXXX")"
payload="$workdir/payload"
image_dir="$workdir/image"
topdir="$workdir/rpmbuild"
template_dir="$payload/var/lib/qubes/vm-templates/$template_name"
spec="$topdir/SPECS/qubes-template-$template_name.spec"

mkdir -p "$template_dir" "$image_dir" "$topdir/BUILD" "$topdir/BUILDROOT" \
    "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS" \
    "$topdir/rpmdb" "$output_dir"

if ! cp --reflink=auto --sparse=always "$root_image" "$image_dir/root.img" 2>/dev/null; then
    cp "$root_image" "$image_dir/root.img"
fi
cp --sparse=always "$image_dir/root.img" "$image_dir/root.img.sparse"
mv -f "$image_dir/root.img.sparse" "$image_dir/root.img"

if [ "$shrink_image" -eq 1 ]; then
    before_apparent="$(stat -c '%s' "$image_dir/root.img")"
    before_allocated="$(du -B1 "$image_dir/root.img" | awk '{print $1}')"
    e2fsck -fy "$image_dir/root.img" >&2
    resize2fs -M "$image_dir/root.img" >&2
    e2fsck -fy "$image_dir/root.img" >&2
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -d "$image_dir/root.img" 2>/dev/null || true
    fi
    after_apparent="$(stat -c '%s' "$image_dir/root.img")"
    after_allocated="$(du -B1 "$image_dir/root.img" | awk '{print $1}')"
    printf 'root.img minimized: apparent %s -> %s bytes, allocated %s -> %s bytes\n' \
        "$before_apparent" "$after_apparent" "$before_allocated" "$after_allocated" >&2
fi

tar -C "$image_dir" -Scf - root.img |
    split -d -a 2 -b "$split_size" - "$template_dir/root.img.part."

cat > "$template_dir/template.conf" <<EOF
virt-mode=pvh
qrexec=1
EOF
if [ -n "$gui_enabled" ]; then
    printf 'gui=%s\n' "$gui_enabled" >> "$template_dir/template.conf"
fi

mkdir -p "$template_dir/apps" "$template_dir/apps.templates" "$template_dir/apps.tempicons"
: > "$template_dir/clean-volatile.img.tar"
printf '%s\n' "${appmenu_entries[@]}" > "$template_dir/whitelisted-appmenus.list"
printf '%s\n' "${appmenu_entries[@]}" > "$template_dir/vm-whitelisted-appmenus.list"
printf '%s\n' "${appmenu_entries[@]}" > "$template_dir/netvm-whitelisted-appmenus.list"

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
%defattr(0644,root,root,0755)
%attr(0755,root,root) %dir %{dest_dir}

%ghost %{dest_dir}/root.img
%ghost %{dest_dir}/private.img
%ghost %{dest_dir}/volatile.img

%{dest_dir}/root.img.part.*
%{dest_dir}/clean-volatile.img.tar

%attr(0755,root,root) %dir %{dest_dir}/apps
%attr(0755,root,root) %dir %{dest_dir}/apps.templates
%attr(0755,root,root) %dir %{dest_dir}/apps.tempicons
%attr(0644,root,root) %{dest_dir}/whitelisted-appmenus.list
%attr(0644,root,root) %{dest_dir}/vm-whitelisted-appmenus.list
%attr(0644,root,root) %{dest_dir}/netvm-whitelisted-appmenus.list
%attr(0644,root,root) %{dest_dir}/template.conf
EOF

rpmbuild -bb \
    --define "_topdir $topdir" \
    --define "_dbpath $topdir/rpmdb" \
    --define "_build_id_links none" \
    "$spec" >&2

rpm_path="$(find "$topdir/RPMS" -type f -name "qubes-template-$template_name-*.rpm" -print -quit)"
[ -n "$rpm_path" ] || die "rpmbuild did not produce an RPM"
cp -f "$rpm_path" "$output_dir/"

printf '%s\n' "$output_dir/$(basename "$rpm_path")"
