#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/native/modules/qubes/services/qubes-vm.scm"
package_file="$repo_root/native/modules/qubes/packages/qubes-vm.scm"

require_contains() {
    local text="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -Fq -- "$pattern" <<<"$text"; then
        printf 'native/modules/qubes/services/qubes-vm.scm: missing %s\npattern: %s\n' \
            "$description" "$pattern" >&2
        exit 1
    fi
}

require_file_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -Fq -- "$pattern" "$file"; then
        printf '%s: missing %s\npattern: %s\n' \
            "${file#$repo_root/}" "$description" "$pattern" >&2
        exit 1
    fi
}

line_of() {
    local pattern="$1"
    local line

    line="$(grep -nF -- "$pattern" "$source_file" | head -n1 | cut -d: -f1 || true)"
    printf '%s\n' "${line:-0}"
}

assert_line_order() {
    local before_pattern="$1"
    local after_pattern="$2"
    local before
    local after

    before="$(line_of "$before_pattern")"
    after="$(line_of "$after_pattern")"
    if [ "$before" -le 0 ] || [ "$after" -le 0 ] || [ "$before" -ge "$after" ]; then
        printf 'unexpected service order: %s at line %s should precede %s at line %s\n' \
            "$before_pattern" "$before" "$after_pattern" "$after" >&2
        exit 1
    fi
}

mount_program="$(sed -n '/(define (qubes-mount-dirs-program)/,/(define (qubes-mount-dirs-shepherd-service _)/p' "$source_file")"
require_contains "$mount_program" '"/dev/xvdb /rw auto noauto,defaults,discard,nosuid,nodev 1 2\n"' \
    'standard Qubes private-volume fstab entry'
require_contains "$mount_program" '(qubesdb-read "/qubes-vm-persistence")' \
    'QubesDB persistence-mode check'
require_contains "$mount_program" '"rw-only"' \
    'AppVM rw-only persistence mode handling'
require_contains "$mount_program" '(run* mount-dirs)' \
    'upstream mount-dirs execution'
require_contains "$mount_program" '(define (repair-fstab-entry)' \
    'fstab repair helper'
mount_program_line_of() {
    local pattern="$1"
    local line

    line="$(grep -nF -- "$pattern" <<<"$mount_program" | head -n1 | cut -d: -f1 || true)"
    printf '%s\n' "${line:-0}"
}
mapfile -t repair_fstab_lines < <(grep -nF -- '(repair-fstab-entry)' <<<"$mount_program" | cut -d: -f1 || true)
already_mounted_line="$(mount_program_line_of 'Qubes private directories already mounted')"
mount_dirs_line="$(mount_program_line_of '(run* mount-dirs)')"
if [ "${#repair_fstab_lines[@]}" -lt 3 ]; then
    printf 'qubes-mount-dirs must repair /etc/fstab before and after upstream mount-dirs\n' >&2
    exit 1
fi
pre_mount_repair_line="${repair_fstab_lines[1]}"
post_mount_repair_line="${repair_fstab_lines[2]}"
if [ "$pre_mount_repair_line" -le 0 ] || [ "$already_mounted_line" -le 0 ] ||
    [ "$pre_mount_repair_line" -ge "$already_mounted_line" ]; then
    printf 'qubes-mount-dirs must repair /etc/fstab before the already-mounted fast path\n' >&2
    exit 1
fi
if [ "$mount_dirs_line" -le 0 ] || [ "$post_mount_repair_line" -le "$mount_dirs_line" ]; then
    printf 'qubes-mount-dirs must repair /etc/fstab after upstream mount-dirs returns\n' >&2
    exit 1
fi

mount_service="$(sed -n '/(define (qubes-mount-dirs-shepherd-service _)/,/(define qubes-mount-dirs-service-type)/p' "$source_file")"
bind_service="$(sed -n '/(define (qubes-bind-dirs-shepherd-service _)/,/(define qubes-bind-dirs-service-type)/p' "$source_file")"
misc_service="$(sed -n '/(define (qubes-misc-post-shepherd-service _)/,/(define qubes-misc-post-service-type)/p' "$source_file")"
qrexec_service="$(sed -n '/(define (qubes-qrexec-agent-shepherd-service _)/,/(define qubes-qrexec-agent-service-type)/p' "$source_file")"
feature_service="$(sed -n '/(define (qubes-feature-advertisement-shepherd-service _)/,/(define qubes-feature-advertisement-service-type)/p' "$source_file")"
feature_program="$(sed -n '/(define (qubes-feature-advertisement-program)/,/(define (qubes-feature-advertisement-shepherd-service _)/p' "$source_file")"
gui_program="$(sed -n '/(define (qubes-gui-agent-program)/,/(define (qubes-gui-agent-shepherd-service _)/p' "$source_file")"
gui_service="$(sed -n '/(define (qubes-gui-agent-shepherd-service _)/,/(define qubes-gui-agent-service-type)/p' "$source_file")"
compat_activation="$(sed -n '/(define (qubes-vm-compat-activation _)/,/(define qubes-vm-compat-service-type)/p' "$source_file")"

require_contains "$mount_service" "'(qubes-sysinit)" \
    'qubes-mount-dirs Shepherd dependency on qubes-sysinit'
require_contains "$bind_service" "'(qubes-mount-dirs)" \
    'qubes-bind-dirs Shepherd dependency on qubes-mount-dirs'
require_contains "$misc_service" "'(qubes-bind-dirs)" \
    'qubes-misc-post Shepherd dependency on qubes-bind-dirs'
require_contains "$qrexec_service" "(requirement '(qubes-bind-dirs))" \
    'qrexec-agent Shepherd dependency on qubes-bind-dirs'
require_contains "$feature_service" "'(qubes-qrexec-agent)" \
    'feature advertisement Shepherd dependency on qrexec-agent'
require_contains "$feature_program" 'qrexec-client-vm* "dom0" "qubes.FeaturesRequest"' \
    'feature advertisement qrexec commit path'
require_contains "$gui_service" "(requirement '(user-processes qubes-bind-dirs qubes-qrexec-agent))" \
    'GUI agent Shepherd dependency on bind-dirs and qrexec'
require_contains "$gui_program" 'qubesdb-read*' \
    'GUI agent QubesDB read'
require_file_contains "$package_file" \
    'command from argv[0]' \
    'QubesDB client wrappers force argv-independent command dispatch'
require_file_contains "$package_file" \
    '(("qubesdb-read" "read")' \
    'QubesDB read wrapper entry'
require_file_contains "$package_file" \
    '("qubesdb-write" "write")' \
    'QubesDB write wrapper entry'
require_file_contains "$repo_root/native/modules/qubes/systems/guix-template.scm" \
    'breaks substitute downloads when' \
    'Guix daemon avoids inactive 127.0.0.1 updates proxy'
require_contains "$compat_activation" \
    '(link-directory-contents "/run/current-system/profile/etc/qubes-rpc"' \
    'writable /etc/qubes-rpc materialization'
require_contains "$compat_activation" \
    '(materialize-symlinked-directory "/etc/qubes/post-install.d")' \
    'writable Qubes post-install hook directory materialization'
require_contains "$compat_activation" \
    '(mkdir-p "/etc/qubes/post-install.d")' \
    'writable Qubes post-install hook directory'
if grep -Fq -- '(replace-symlink "/run/current-system/profile/etc/qubes-rpc"' "$source_file"; then
    printf 'native Qubes activation must not leave /etc/qubes-rpc as an immutable profile symlink\n' >&2
    exit 1
fi
if grep -Fq -- '--default=True' "$source_file" "$package_file"; then
    printf 'native Qubes VM code must not use invalid qubesdb-read --default=True form\n' >&2
    exit 1
fi

require_file_contains "$package_file" \
    "(add-after 'unpack 'normalize-guix-skel-in-home-init" \
    'package phase that normalizes /etc/skel before Qubes home initialization'
require_file_contains "$package_file" \
    'skel_source=$(readlink -f /etc/skel || echo /etc/skel)' \
    'dereferenced /etc/skel source for persistent AppVM homes'
require_file_contains "$package_file" \
    'cp \"-afL$enable_selinux\" -T \"$skel_source\" \"$home_root/$homedirwithouthome\"' \
    'symlink-dereferencing skeleton copy into /rw/home'
require_file_contains "$package_file" \
    "(add-after 'normalize-guix-skel-in-home-init 'make-guix-skel-owner-writable" \
    'package phase that makes copied home skeletons writable'
require_file_contains "$package_file" \
    'chmod -R u+rwX \"$home_root/$homedirwithouthome\" || return 73' \
    'writable copied skeleton for Guix and desktop state below /rw/home'
require_file_contains "$source_file" \
    '"/run/setuid-programs:"' \
    'qrexec service PATH includes Guix privileged-program wrappers'
require_file_contains "$package_file" \
    'PATH=/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin' \
    'GUI session PATH includes Guix privileged-program wrappers'
require_file_contains "$package_file" \
    '"/qvm-template-repo-query-guix"' \
    'Guix fallback helper for qvm-template repository access'
require_file_contains "$package_file" \
    '"/qvm-template-repo-query.dnf"' \
    'preserved stock DNF qvm-template repository helper'
require_file_contains "$package_file" \
    'command -v dnf5 >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v dnf4 >/dev/null 2>&1' \
    'qvm-template repository helper keeps DNF path when DNF is present'
require_file_contains "$package_file" \
    'qvm-template-repo-query-guix\" \"$@\"' \
    'qvm-template repository helper falls back to native Guix implementation'
require_file_contains "$repo_root/native/modules/qubes/files/qvm-template-repo-query-guix" \
    'primary_metadata_url' \
    'rpm-md primary metadata parser for qvm-template Guix fallback'
require_file_contains "$repo_root/native/modules/qubes/files/qvm-template-repo-query-guix" \
    'def download(config, options, spec):' \
    'RPM download path for qvm-template Guix fallback'

assert_line_order '(service qubes-sysinit-service-type)' \
    '(service qubes-mount-dirs-service-type)'
assert_line_order '(service qubes-mount-dirs-service-type)' \
    '(service qubes-bind-dirs-service-type)'
assert_line_order '(service qubes-bind-dirs-service-type)' \
    '(service qubes-misc-post-service-type)'
assert_line_order '(service qubes-bind-dirs-service-type)' \
    '(service qubes-qrexec-agent-service-type)'
assert_line_order '(service qubes-qrexec-agent-service-type)' \
    '(service qubes-feature-advertisement-service-type)'

printf 'Qubes VM service wiring check passed\n'
