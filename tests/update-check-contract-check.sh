#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
services="$repo_root/modules/qubes/services.scm"
system="$repo_root/modules/qubes/system.scm"
packages="$repo_root/modules/qubes/packages.scm"
helper="$repo_root/modules/qubes/files/guix-updates-installed-check.scm"
patch="$repo_root/modules/qubes/patches/should-upstream/qubes-vm-core-upgrades-installed-check-guix.patch"
builder="$repo_root/scripts/build-native-rootfs.sh"
substitute_builder="$repo_root/scripts/build-substitute-cache.sh"
substitute_workflow="$repo_root/.github/workflows/substitute-cache.yml"

require_text() {
    local text="$1"
    local file="$2"
    grep -Fq -- "$text" "$file" || {
        printf 'missing update-check contract in %s: %s\n' "$file" "$text" >&2
        exit 1
    }
}

# Match the standard Qubes timer exactly: OnBootSec=5min and
# OnUnitActiveSec=2d.  A wall-clock cron schedule is not equivalent.
require_text '(define %qubes-update-check-initial-delay-seconds 300)' "$services"
require_text '(define %qubes-update-check-interval-seconds (* 2 24 60 60))' "$services"
require_text '(define (qubes-update-check-scheduler-program)' "$services"
require_text '(requirement '\''(qubes-qrexec-agent))' "$services"
# The upstream feature hook discovers this service through systemd.  The
# native Shepherd implementation must advertise the same feature directly.
supported_services="$(
    sed -n '/(define supported-services/,/))[[:space:]]*$/p' "$services"
)"
if ! grep -Fq '"qubes-update-check"' <<< "$supported_services"; then
    printf 'update-check support is not advertised to dom0\n' >&2
    exit 1
fi
require_text '"/proc/uptime"' "$services"
require_text '(get-internal-real-time)' "$services"
require_text 'internal-time-units-per-second' "$services"
if grep -Fq '0 */12 * * *' "$services"; then
    printf 'update check regressed to a wall-clock cron schedule\n' >&2
    exit 1
fi

# The active system generation, not a mutable per-user `guix pull` profile,
# owns the comparison baseline.
require_text 'etc-service-type' "$system"
require_text '`(("qubes-applied-guix-channels.scm"' "$system"
require_text '(current-channels)' "$system"
require_text '(search-path %load-path file)' "$system"
require_text 'QUBES_TEMPLATE_CHANNEL_COMMIT' "$system"
require_text "QUBES_TEMPLATE_CHANNEL_COMMIT=\$source_commit" "$builder"
require_text 'generated system lacks applied Guix channel state' "$builder"
require_text '.qubes-channel-commit' "$system"
require_text '.qubes-channel-commit' "$builder"
require_text "QUBES_TEMPLATE_CHANNEL_COMMIT=\$source_commit" "$substitute_builder"
require_text 'export QUBES_TEMPLATE_CHANNEL_COMMIT=' "$substitute_workflow"
require_text 'archive_git_commit_tree' "$builder"
require_text 'archive_git_commit_tree' "$substitute_builder"
require_text "\"\${source_paths[@]}\"" "$builder"
require_text "\"\${source_paths[@]}\"" "$substitute_builder"
require_text "system -L \"\$source_tree/modules\"" "$builder"
require_text "system build -L \"\$source_tree/modules\"" "$substitute_builder"
require_text "channels_file=\"\$source_tree/config/channels.scm\"" "$builder"
require_text "\"\$source_tree/config/guix-channels.scm\"" "$builder"
require_text "config=\"\$source_tree/\$config_repo_relative\"" "$builder"
require_text 'external-system-config.scm' "$builder"
require_text 'outside Qubes channel commit' "$builder"
require_text 'O_NOFOLLOW' "$builder"
require_text 'os.fstat(source_fd)' "$builder"
require_text '"st_ctime_ns"' "$builder"
require_text 'os.O_EXCL' "$builder"
require_text "\"\$source_tree/config/qubes-os-\$v.scm\"" "$substitute_builder"
require_text "pull -C \"\$source_tree/config/guix-channels.scm\"" "$substitute_builder"
require_text 'resolve_authenticated_pull_profile' "$substitute_builder"
require_text 'describe --format=json' "$substitute_builder"
require_text 'len(qubes_channels) != 1' "$substitute_builder"
require_text 'actual_commit != expected_commit' "$substitute_builder"
require_text "guix_bin=\"\$profile_guix\"" "$substitute_builder"
if grep -Fq "\"\$repo_root/config/qubes-os-\$v.scm\"" "$substitute_builder" ||
        grep -Fq "pull -C \"\$repo_root/config/guix-channels.scm\"" \
            "$substitute_builder"; then
    printf 'substitute build regressed to a mutable repository config\n' >&2
    exit 1
fi

# A local `-L` module tree is independent of the profile that happens to invoke
# Guix.  Its baked marker, then its explicit build provenance, must override a
# possibly older/newer Qubes revision in that profile.
precedence_body="$(
    sed -n '/^(define (applied-channel-revisions)/,/^(define %qubes-applied-channel-state-file/p' \
        "$system"
)"
marker_line="$(grep -nF '(or source-revision' <<< "$precedence_body" | cut -d: -f1)"
environment_line="$(grep -nF '(environment-qubes-channel-revision)' <<< "$precedence_body" | cut -d: -f1)"
profile_line="$(grep -nF '(find (lambda (revision) (eq? (car revision) '\''qubes))' \
    <<< "$precedence_body" | head -n 1 | cut -d: -f1)"
if [ -z "$marker_line" ] || [ -z "$environment_line" ] || [ -z "$profile_line" ] ||
        [ "$marker_line" -ge "$environment_line" ] ||
        [ "$environment_line" -ge "$profile_line" ]; then
    printf 'Qubes channel revision precedence is not marker > environment > profile\n' >&2
    exit 1
fi

# Resolve and authenticate through Guix.  Direct ls-remote comparisons miss
# the companion channel, mishandle pins, and can clear state on network errors.
require_text '(channel-list ' "$helper"
require_text '(latest-channel-instances' "$helper"
require_text '#:current-channels' "$helper"
require_text '(define (write-cache file channels-text revisions)' "$helper"
require_text '(define (check-without-refresh applied channels-file cache-file)' "$helper"
require_text '/guix-updates-installed-check.scm' "$packages"
require_text '"'"\$guix_bin"'" repl -q -- "'"\$checker"'"' "$patch"
if grep -Eq '^\+.*[$]git_bin|^\+.*git_bin=' "$patch"; then
    printf 'Guix update check regressed to direct unauthenticated Git probing\n' >&2
    exit 1
fi

# Refresh failures must return nonzero with no true/false result so dom0 keeps
# its previous NotifyUpdates state, matching the other package-manager paths.
require_text 'exit_code="$?"' "$patch"
require_text 'guix-update-check-latest.scm' "$patch"
require_text '(define (qubes-update-check-activation _)' "$services"
require_text '(system-generation-link? new-system)' "$services"
require_text '(same-file? new-system "/run/current-system")' "$services"
require_text '(file-append util-linux "/bin/flock")' "$services"
require_text '%qubes-update-check-lock-file' "$services"
require_text '%qubes-update-check-lock-wait-seconds 30' "$services"
require_text '%qubes-update-check-trigger-directory' "$services"
require_text '(define (claim-trigger)' "$services"
require_text '(rename-file trigger claimed-trigger)' "$services"
require_text '(define (queue-authenticated-check)' "$services"
require_text '(mkdir #$%qubes-update-check-trigger-directory #o700)' "$services"
require_text '"/etc/qubes-applied-guix-channels.scm"))' "$services"
require_text '"skip-refresh"' "$services"
require_text '(read-value file "applied channel state")' "$helper"

printf 'Qubes update-check parity contract passed\n'
