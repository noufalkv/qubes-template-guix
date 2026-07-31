#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
services="$repo_root/modules/qubes/services.scm"
system="$repo_root/modules/qubes/system.scm"
packages="$repo_root/modules/qubes/packages.scm"
helper="$repo_root/modules/qubes/files/guix-updates-installed-check"
patch="$repo_root/modules/qubes/patches/should-upstream/qubes-vm-core-upgrades-installed-check-guix.patch"
builder="$repo_root/scripts/build-native-rootfs.sh"
substitute_builder="$repo_root/scripts/build-substitute-cache.sh"
substitute_workflow="$repo_root/.github/workflows/substitute-cache.yml"
build_channels="$repo_root/config/channels.scm"
installed_channels="$repo_root/config/guix-channels.scm"

# Guix recursively imports every .scm file below the channel module root.
# Standalone programs in files/ must therefore remain extensionless in source
# and receive their user-facing suffix only when packaged.
if find "$repo_root/modules" \( -type f -o -type l \) \
        -path '*/files/*.scm' \
        -print -quit | grep -q .; then
    printf '%s\n' 'standalone .scm program found inside the channel module tree' \
        >&2
    exit 1
fi

require_text() {
    local text="$1"
    local file="$2"
    grep -Fq -- "$text" "$file" || {
        printf 'missing update-check contract in %s: %s\n' "$file" "$text" >&2
        exit 1
    }
}

# Both template construction and the installed pull/reconfigure path must
# resolve authenticated branch heads rather than freezing a Guix revision.
for channels_file in "$build_channels" "$installed_channels"; do
    if grep -Eq '\(commit([[:space:]]|\))' "$channels_file"; then
        printf 'Guix channel is unexpectedly pinned in %s\n' \
            "$channels_file" >&2
        exit 1
    fi
    if [ "$(grep -Fc \
            '(url "https://codeberg.org/guix/guix.git")' \
            "$channels_file")" -ne 1 ]; then
        printf 'Guix channel does not use the authenticated Codeberg upstream in %s\n' \
            "$channels_file" >&2
        exit 1
    fi
    require_text '(branch "master")' "$channels_file"
    require_text '"9edb3f66fd807b096b48283debdcddccfea34bad"' \
        "$channels_file"
    require_text '"BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"' \
        "$channels_file"
done

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
require_text './scripts/bootstrap-guix-secure.sh' "$substitute_workflow"
require_text './scripts/build-substitute-cache.sh prepare' "$substitute_workflow"
require_text 'cancel-in-progress: false' "$substitute_workflow"
require_text "cron: '17 4 * * *'" "$substitute_workflow"
require_text \
    "shard_regex='^substitute-cache-nars-v2-[0-9a-f]{40}-[0-9a-f]{40}-[0-9]{4}-[0-9a-f]{64}\$'" \
    "$substitute_workflow"
require_text "printf 'snapshot-sha256:%s\\n'" "$substitute_workflow"
require_text \
    "substitute-cache-snapshot?run=\$GITHUB_RUN_ID-\$GITHUB_RUN_ATTEMPT" \
    "$substitute_workflow"
require_text "for attempt in \$(seq 1 6); do" "$substitute_workflow"
require_text "test \"\$attempt\" -lt 6" "$substitute_workflow"
require_text 'sleep 5' "$substitute_workflow"
if [ "$(grep -Fc \
        "gh api --header 'Cache-Control: no-cache' --paginate --slurp" \
        "$substitute_workflow")" -ne 3 ]; then
    printf '%s\n' 'not every managed Release snapshot forces revalidation' >&2
    exit 1
fi

# Execute the workflow's argument-assembly block.  Each metadata ZIP expands
# to an option/value pair, so the number of array elements is not the number
# of generations.
recovery_prior_block="$(
    awk '
        /- name: Recover Pages and cleanup plan from public Releases/ {
            recovery = 1
        }
        recovery && /^[[:space:]]+prior=\(\)$/ { capture = 1 }
        capture && /^[[:space:]]+if test "\$publish_needed"/ { exit }
        capture {
            sub(/^[[:space:]]+/, "")
            print
        }
    ' "$substitute_workflow"
)"
if ! grep -Fq "prior+=(--prior-metadata \"\$metadata\")" \
        <<< "$recovery_prior_block"; then
    printf '%s\n' 'recovery metadata argument block was not extracted' >&2
    exit 1
fi
recovery_count_dir="$(mktemp -d)"
touch -- "$recovery_count_dir/one.zip" "$recovery_count_dir/two.zip"
if ! metadata_dir="$recovery_count_dir" generation_count=2 \
        bash -euo pipefail -c "$recovery_prior_block"; then
    rm -f -- "$recovery_count_dir/one.zip" "$recovery_count_dir/two.zip"
    rmdir -- "$recovery_count_dir"
    printf '%s\n' 'recovery metadata argument count rejects valid ZIPs' >&2
    exit 1
fi
rm -f -- "$recovery_count_dir/one.zip" "$recovery_count_dir/two.zip"
rmdir -- "$recovery_count_dir"

require_text "cmp -- \"\$local_snapshot\" \"\$downloaded_snapshot\"" \
    "$substitute_workflow"
require_text \
    '.revoke_gc_marker_releases[] | [.repository, .release_tag] | @tsv' \
    "$substitute_workflow"
require_text "grep -Fq '(HTTP 404)'" "$substitute_workflow"

workflow_revoke_line="$(
    grep -nF -- '- name: Revoke invalid GC markers before the Pages transition' \
        "$substitute_workflow" | cut -d: -f1
)"
workflow_deploy_line="$(
    grep -nF -- '- name: Deploy retained narinfo index to GitHub Pages' \
        "$substitute_workflow" | cut -d: -f1
)"
workflow_verify_line="$(
    grep -nF -- '- name: Verify the exact Pages snapshot and published cache' \
        "$substitute_workflow" | cut -d: -f1
)"
workflow_marker_line="$(
    grep -nF -- \
        '- name: Record the verified Pages deployment for garbage collection' \
        "$substitute_workflow" | cut -d: -f1
)"
workflow_cleanup_line="$(
    grep -nF -- '- name: Remove Releases authorized by the GC plan' \
        "$substitute_workflow" | cut -d: -f1
)"
if [ -z "$workflow_revoke_line" ] || [ -z "$workflow_deploy_line" ] ||
        [ -z "$workflow_verify_line" ] || [ -z "$workflow_marker_line" ] ||
        [ -z "$workflow_cleanup_line" ] ||
        [ "$workflow_revoke_line" -ge "$workflow_deploy_line" ] ||
        [ "$workflow_deploy_line" -ge "$workflow_verify_line" ] ||
        [ "$workflow_verify_line" -ge "$workflow_marker_line" ] ||
        [ "$workflow_marker_line" -ge "$workflow_cleanup_line" ]; then
    printf '%s\n' \
        'substitute GC ordering is not revoke -> deploy -> verify -> mark -> delete' \
        >&2
    exit 1
fi
require_text 'archive_git_commit_tree' "$builder"
require_text 'archive_git_commit_tree' "$substitute_builder"
require_text "\"\${source_paths[@]}\"" "$builder"
require_text "\"\${source_paths[@]}\"" "$substitute_builder"
require_text 'scripts/git-tracked-tree.sh' "$substitute_builder"
require_text 'scripts/lib.sh' "$substitute_builder"
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
require_text 'actual_commit != expected_qubes_commit' "$substitute_builder"
require_text "guix_bin=\"\$profile_guix\"" "$substitute_builder"
require_text '--authenticated-guix-checkout' "$substitute_builder"
require_text '--guix-security-floor' "$substitute_builder"
require_text 'len(guix_channels) != 1' "$substitute_builder"
require_text 'guix_channel.get("url") not in expected_urls' "$substitute_builder"
require_text 'merge-base --is-ancestor' "$substitute_builder"
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
    sed -n '/^(define (applied-channel-revisions)/,/^(define (qubes-applied-channel-state-etc/p' \
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

# Provenance depends on the OS instantiation context.  The channel compiler
# imports every module without that context, so state-file construction must
# remain deferred behind a service extension.
require_text '(define (qubes-applied-channel-state-etc _)' "$system"
require_text '(service-extension etc-service-type' "$system"
require_text '(service qubes-applied-channel-state-service-type)' "$system"
if grep -Fq '(define %qubes-applied-channel-state-file' "$system"; then
    printf 'applied channel state is constructed eagerly at module import\n' >&2
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
