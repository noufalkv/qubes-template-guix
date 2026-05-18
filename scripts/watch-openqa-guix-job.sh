#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

openqa_url="${QUBES_OPENQA_URL:-http://localhost:9526}"
pool_root="${QUBES_OPENQA_POOL_ROOT:-/var/lib/openqa/pool/1}"
results_root="${QUBES_OPENQA_RESULTS_ROOT:-/var/lib/openqa/testresults/00000}"
status_interval="${QUBES_OPENQA_STATUS_INTERVAL:-300}"
done_status_interval="${QUBES_OPENQA_DONE_STATUS_INTERVAL:-600}"
show_worker_journal="${QUBES_OPENQA_SHOW_WORKER_JOURNAL:-0}"
worker_journal_interval="${QUBES_OPENQA_WORKER_JOURNAL_INTERVAL:-120}"
show_done_logs="${QUBES_OPENQA_SHOW_DONE_LOGS:-0}"
initial_tail_lines="${QUBES_OPENQA_INITIAL_TAIL_LINES:-0}"
suppress_transfer_blocks="${QUBES_OPENQA_SUPPRESS_TRANSFER_BLOCKS:-1}"
job_selector="${1:-latest}"

usage() {
    cat <<'EOF'
Usage: watch-openqa-guix-job.sh [JOB_ID|latest]

Watch the latest running openQA job, or a specific job ID, from an openQA host.

In "latest" mode, completed jobs are reported by status only unless
QUBES_OPENQA_SHOW_DONE_LOGS=1 is set. This keeps long-running watch panes from
replaying archived logs that were already streamed from the live worker pool.

By default the watcher attaches at the current end of each log and prints only
new bytes. Set QUBES_OPENQA_INITIAL_TAIL_LINES to a positive line count when
you want context from already-written logs.

Raw virtio-console file uploads are suppressed by default because openQA sends
large artifacts to the guest as base64 here-documents. Set
QUBES_OPENQA_SUPPRESS_TRANSFER_BLOCKS=0 to show the unfiltered console stream.
EOF
}

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: missing required command: %s\n' "$1" >&2
        exit 1
    }
}

latest_job_id() {
    openqa-cli api --host "$openqa_url" jobs limit=30 |
        jq -r '[.jobs[]] | sort_by(.id) |
               (map(select(.state != "done"))[-1] // .[-1]) |
               .id // empty'
}

need find
need jq
need openqa-cli
need stat
need tail
need dd

declare -A log_offsets
declare -A log_identities
declare -A transfer_block_active
declare -A transfer_notice_printed
last_job_id=""
last_status_line=""
last_status_at=0
last_state=""
last_worker_journal_at=0

case "$job_selector" in
    -h|--help)
        usage
        exit 0
        ;;
esac

case "$initial_tail_lines" in
    ''|*[!0-9]*)
        printf 'error: QUBES_OPENQA_INITIAL_TAIL_LINES must be a non-negative integer\n' >&2
        exit 1
        ;;
esac

log_size() {
    stat -c '%s' "$1" 2>/dev/null || printf 0
}

log_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null || printf missing
}

print_transfer_notice() {
    local key="$1"

    if [ "${transfer_notice_printed[$key]:-0}" != "1" ]; then
        printf '[openQA file-transfer block suppressed; set QUBES_OPENQA_SUPPRESS_TRANSFER_BLOCKS=0 for raw console uploads]\n'
        transfer_notice_printed["$key"]=1
    fi
}

print_log_payload() {
    local key="$1"
    local path="$2"
    local offset="$3"
    local count="$4"
    local line

    if [ "$suppress_transfer_blocks" != "1" ] ||
        [ "$(basename "$path")" != "virtio_console.log" ]; then
        dd if="$path" bs=1 skip="$offset" count="$count" status=none || true
        return 0
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${transfer_block_active[$key]:-0}" = "1" ]; then
            case "$line" in
                *OPENQA_EOF*|*oqeof*)
                    transfer_block_active["$key"]=0
                    ;;
            esac
            continue
        fi

        case "$line" in
            *".b64"*"<<'OPENQA_EOF'"*|*".b64"*'<<"OPENQA_EOF"'*|*".b64"*"<<'oqeof'"*|*".b64"*'<<"oqeof"'*)
                print_transfer_notice "$key"
                transfer_block_active["$key"]=1
                continue
                ;;
        esac

        if [[ "$line" =~ ^[[:space:]\>]*[A-Za-z0-9+/=]{160,}$ ]]; then
            print_transfer_notice "$key"
            continue
        fi

        printf '%s\n' "$line"
    done < <(dd if="$path" bs=1 skip="$offset" count="$count" status=none || true)
}

show_initial_tail() {
    local key="$1"
    local path="$2"
    local label="$3"
    local size
    local identity

    size="$(log_size "$path")"
    identity="$(log_identity "$path")"

    if [ "$initial_tail_lines" -gt 0 ]; then
        printf '\n===== %s: %s (last %s lines, size=%s) =====\n' \
            "$label" "$path" "$initial_tail_lines" "$size"
        if [ "$suppress_transfer_blocks" = "1" ] &&
            [ "$(basename "$path")" = "virtio_console.log" ]; then
            tail -n "$initial_tail_lines" "$path" |
                sed -e '/\.b64.*OPENQA_EOF/,/OPENQA_EOF/d' \
                    -e '/\.b64.*oqeof/,/oqeof/d' || true
        else
            tail -n "$initial_tail_lines" "$path" || true
        fi
        printf '\n'
    else
        printf '\n===== %s: %s (attached at byte %s) =====\n' \
            "$label" "$path" "$size"
    fi

    log_identities["$key"]="$identity"
    log_offsets["$key"]="$size"
}

show_new_log_bytes() {
    local key="$1"
    local path="$2"
    local label="$3"
    local size
    local identity
    local offset
    local previous_identity
    local count

    [ -r "$path" ] || return 0

    size="$(log_size "$path")"
    identity="$(log_identity "$path")"
    offset="${log_offsets[$key]:-}"
    previous_identity="${log_identities[$key]:-}"

    if [ -z "$offset" ]; then
        show_initial_tail "$key" "$path" "$label"
        return 0
    fi

    if [ "$previous_identity" != "$identity" ]; then
        log_identities["$key"]="$identity"

        if [ "$size" -eq "$offset" ]; then
            return 0
        fi

        if [ "$size" -gt "$offset" ]; then
            count=$((size - offset))
            printf '\n===== %s: %s (replaced, +%s bytes) =====\n' "$label" "$path" "$count"
            print_log_payload "$key" "$path" "$offset" "$count"
            printf '\n'
            log_offsets["$key"]="$size"
            return 0
        fi

        show_initial_tail "$key" "$path" "$label"
        return 0
    fi

    if [ "$size" -gt "$offset" ]; then
        count=$((size - offset))
        printf '\n===== %s: %s (+%s bytes) =====\n' "$label" "$path" "$count"
        print_log_payload "$key" "$path" "$offset" "$count"
        printf '\n'
        log_offsets["$key"]="$size"
    fi
}

print_status_if_needed() {
    local job_id="$1"
    local status_line="$2"
    local state="$3"
    local now
    local interval

    now="$(date +%s)"
    interval="$status_interval"
    if [ "$job_selector" = "latest" ] && [ "$state" = "done" ]; then
        interval="$done_status_interval"
    fi

    if [ "$status_line" != "$last_status_line" ] ||
        [ $((now - last_status_at)) -ge "$interval" ]; then
        printf '\n[%s] openQA job %s %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$status_line"
        if [ "$job_selector" = "latest" ] && [ "$state" = "done" ]; then
            printf 'latest job is done; waiting quietly for a newer job\n'
        fi
        last_status_line="$status_line"
        last_status_at="$now"
    fi
}

while true; do
    if [ "$job_selector" = "latest" ]; then
        job_id="$(latest_job_id)"
    else
        job_id="$job_selector"
    fi

    if [ "$job_id" != "$last_job_id" ]; then
        log_offsets=()
        log_identities=()
        last_job_id="$job_id"
        last_status_line=""
        last_status_at=0
        last_state=""
    fi

    if [ -z "$job_id" ]; then
        print_status_if_needed none "no jobs found" none
        sleep 5
        continue
    fi

    job_json="$(openqa-cli api --host "$openqa_url" "jobs/$job_id")"
    state="$(printf '%s\n' "$job_json" | jq -r '.job.state // "unknown"')"
    status_line="$(
        printf '%s\n' "$job_json" |
            jq -r '"state=" + (.job.state // "unknown")
                   + " result=" + (.job.result // "none")
                   + " build=" + (.job.settings.BUILD // "")
                   + " cpus=" + (.job.settings.QEMUCPUS // "")
                   + " ram=" + (.job.settings.QEMURAM // "")'
    )"
    print_status_if_needed "$job_id" "$status_line" "$state"

    if [ "$job_selector" = "latest" ] && [ "$state" = "done" ] &&
        [ "$show_done_logs" != "1" ]; then
        if [ "$last_state" != "done" ]; then
            printf 'job %s completed; archived logs are not replayed in latest mode. ' "$job_id"
            printf 'Run %s %s or set QUBES_OPENQA_SHOW_DONE_LOGS=1 to inspect them.\n' "$0" "$job_id"
        fi
        last_state="$state"
        sleep 5
        continue
    fi

    job_dir="$(
        find "$results_root" -maxdepth 1 -type d \
            -name "$(printf '%08d' "$job_id")-*" \
            -print -quit 2>/dev/null || true
    )"

    if [ -z "$job_dir" ]; then
        now="$(date +%s)"
        if [ "$show_worker_journal" = "1" ] &&
            [ $((now - last_worker_journal_at)) -ge "$worker_journal_interval" ]; then
            journalctl -u openqa-worker-plain@1 -n 20 --no-pager 2>/dev/null || true
            last_worker_journal_at="$now"
        fi
        sleep 5
        continue
    fi

    streamed_pool_logs=0
    if [ "$state" != "done" ] && [ -d "$pool_root" ]; then
        for log in autoinst-log.txt virtio_console.log serial0 serial_terminal.txt worker-log.txt; do
            if [ -r "$pool_root/$log" ]; then
                show_new_log_bytes "pool:$log" "$pool_root/$log" "live pool $log"
                streamed_pool_logs=1
            fi
        done
    fi

    if [ "$streamed_pool_logs" = "0" ]; then
        for log in autoinst-log.txt serial0.txt serial_terminal.txt worker-log.txt; do
            if [ -r "$job_dir/$log" ]; then
                show_new_log_bytes "result:$log" "$job_dir/$log" "result $log"
            fi
        done
    fi

    last_state="$state"

    sleep 5
done
