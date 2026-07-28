#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "$repo_root/work.cache-failure.XXXXXX")"
publication_pid=""
publication_lock_pid=""
publication_lock_release=""

cleanup() {
    if [ -n "$publication_lock_release" ]; then
        : > "$publication_lock_release"
    fi
    if [ -n "$publication_pid" ]; then
        kill "$publication_pid" 2>/dev/null || true
        wait "$publication_pid" 2>/dev/null || true
    fi
    if [ -n "$publication_lock_pid" ]; then
        wait "$publication_lock_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

# Exercise the current script and channel sources from a clean, self-contained
# repository.  Production builds deliberately reject dirty channel sources, so
# this failure-injection test must not depend on the caller's working-tree
# state.
fixture_repo="$work_dir/repository"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/config/substitute-cache"
cp -a -- "$repo_root/modules" "$fixture_repo/modules"
cp -- "$repo_root/.guix-channel" "$fixture_repo/.guix-channel"
cp -- "$repo_root/config/guix-channels.scm" \
    "$repo_root/config/qubes-os-normal.scm" "$fixture_repo/config/"
cp -- "$repo_root/config/substitute-cache/signing-key.pub" \
    "$fixture_repo/config/substitute-cache/signing-key.pub"
cp -- "$repo_root/scripts/build-substitute-cache.sh" \
    "$repo_root/scripts/substitute-cache-manifest.py" \
    "$repo_root/scripts/git-tracked-tree.sh" \
    "$repo_root/scripts/lib.sh" "$fixture_repo/scripts/"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" add -- .
git -C "$fixture_repo" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgSign=false \
    -c user.name='Substitute cache test' \
    -c user.email='substitute-cache-test@example.invalid' \
    commit -qm 'Create clean cache-build fixture'
FAKE_SOURCE_COMMIT="$(git -C "$fixture_repo" rev-parse --verify 'HEAD^{commit}')"
export FAKE_SOURCE_COMMIT
FAKE_FIXTURE_REPO="$fixture_repo"
export FAKE_FIXTURE_REPO
build_script="$fixture_repo/scripts/build-substitute-cache.sh"

# Model the checkout handed off by bootstrap: FLOOR is the fixed minimum,
# BOOTSTRAP_HEAD is the revision it authenticated, and the later composed pull
# may select a newer descendant without being pinned to either one.
real_git="$(command -v git)"
authenticated_guix_checkout="$work_dir/authenticated-guix"
git -C "$work_dir" init -q authenticated-guix
git -C "$authenticated_guix_checkout" \
    -c user.name='Guix checkout test' \
    -c user.email='guix-checkout-test@example.invalid' \
    -c commit.gpgSign=false \
    commit -q --allow-empty -m 'Security floor'
guix_security_floor="$(
    git -C "$authenticated_guix_checkout" rev-parse --verify HEAD
)"
git -C "$authenticated_guix_checkout" \
    -c user.name='Guix checkout test' \
    -c user.email='guix-checkout-test@example.invalid' \
    -c commit.gpgSign=false \
    commit -q --allow-empty -m 'Bootstrap authenticated head'
bootstrap_guix_head="$(
    git -C "$authenticated_guix_checkout" rev-parse --verify HEAD
)"
git -C "$authenticated_guix_checkout" \
    -c user.name='Guix checkout test' \
    -c user.email='guix-checkout-test@example.invalid' \
    -c commit.gpgSign=false \
    commit -q --allow-empty -m 'Channel-composed pull head'
FAKE_GUIX_COMMIT="$(
    git -C "$authenticated_guix_checkout" rev-parse --verify HEAD
)"
git -C "$authenticated_guix_checkout" remote add origin \
    https://codeberg.org/guix/guix.git
git -C "$authenticated_guix_checkout" checkout -q --detach \
    "$bootstrap_guix_head"
export FAKE_GUIX_COMMIT
export FAKE_AUTHENTICATED_GUIX_CHECKOUT="$authenticated_guix_checkout"
export FAKE_GUIX_SECURITY_FLOOR="$guix_security_floor"
export REAL_GIT="$real_git"
security_options=(
    --authenticated-guix-checkout "$authenticated_guix_checkout"
    --guix-security-floor "$guix_security_floor"
)

fake_guix="$work_dir/guix"
fake_guix_log="$work_dir/guix.log"
fake_git="$work_dir/git"
fake_git_log="$work_dir/git.log"
fake_curl="$work_dir/curl"
fake_curl_log="$work_dir/curl.log"
fake_stat="$work_dir/stat"
fake_narinfo_attempts="$work_dir/narinfo-attempts"
fake_bake_started="$work_dir/bake-started"
fake_upstream_round="$work_dir/upstream-round"
fake_upstream_requests="$work_dir/upstream-requests"
fake_store_hash=00000000000000000000000000000000
fake_store_path="$work_dir/store/$fake_store_hash-system"
fake_pull_target="$work_dir/store/11111111111111111111111111111111-pull-profile"
fake_deriver="$work_dir/store/22222222222222222222222222222222-pull-profile.drv"
fake_modules_deriver="$work_dir/store/33333333333333333333333333333333-guix-modules.drv"
fake_modules_output="$work_dir/store/44444444444444444444444444444444-guix-modules"
fake_modules_runtime="$work_dir/store/55555555555555555555555555555555-module-runtime"
fake_derivation_source="$work_dir/store/66666666666666666666666666666666-channel-source"
fake_upstream_present="$work_dir/store/77777777777777777777777777777777-present"
fake_upstream_missing="$work_dir/store/88888888888888888888888888888888-missing"
fake_upstream_http_retry="$work_dir/store/99999999999999999999999999999999-http-retry"
fake_upstream_curl_retry="$work_dir/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-curl-retry"
fake_upstream_no_result="$work_dir/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-no-result"
public_key="$work_dir/signing-key.pub"
private_key="$work_dir/signing-key.sec"
output="$work_dir/site"
unsafe_output="$work_dir/not-a-cache"
late_output="$work_dir/late-site"
late_replacement="$work_dir/late-replacement"
late_displaced="$work_dir/late-displaced"
late_downloaded="$work_dir/late-nar-downloaded"
publication_lock_ready="$work_dir/publication-lock-ready"
publication_lock_release="$work_dir/publication-lock-release"
gap_output="$work_dir/gap-site"
gap_replacement="$work_dir/gap-replacement"
gap_displaced="$work_dir/gap-displaced"
gap_stat_counter="$work_dir/gap-stat-counter"

mkdir -p \
    "$fake_store_path" \
    "$fake_pull_target" \
    "$fake_modules_output" \
    "$fake_modules_runtime" \
    "$fake_derivation_source" \
    "$fake_upstream_present" \
    "$fake_upstream_missing" \
    "$fake_upstream_http_retry" \
    "$fake_upstream_curl_retry" \
    "$fake_upstream_no_result" \
    "$output" \
    "$unsafe_output" \
    "$late_output" \
    "$late_replacement/nested" \
    "$gap_output" \
    "$gap_replacement/nested"
: > "$fake_deriver"
: > "$fake_modules_deriver"
export FAKE_MODULES_DERIVER="$fake_modules_deriver"
export FAKE_MODULES_OUTPUT="$fake_modules_output"
export FAKE_MODULES_RUNTIME="$fake_modules_runtime"
export FAKE_DERIVATION_SOURCE="$fake_derivation_source"
printf '%s\n' 'qubes-template-guix static cache v1' > \
    "$output/.qubes-template-guix-cache"
printf '%s\n' 'qubes-template-guix static cache v1' > \
    "$late_output/.qubes-template-guix-cache"
printf '%s\n' 'qubes-template-guix static cache v1' > \
    "$gap_output/.qubes-template-guix-cache"
printf '%s\n' sentinel > "$output/sentinel"
printf '%s\n' original > "$late_output/sentinel"
printf '%s\n' original > "$gap_output/sentinel"
printf '%s\n' preserve > "$late_replacement/nested/unrelated-data"
printf '%s\n' preserve > "$gap_replacement/nested/unrelated-data"
printf '%s\n' keep > "$unsafe_output/unrelated-data"

cat > "$fake_guix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s %s\n' "${1:-}" "${2:-}" >> "${FAKE_GUIX_LOG:?}"

case "${1:-} ${2:-}" in
    'system build')
        [ "$0" = "${FAKE_PULL_TARGET:?}/bin/guix" ] || exit 36
        [ "${QUBES_TEMPLATE_CHANNEL_COMMIT:-}" = \
            "${FAKE_SOURCE_COMMIT:?}" ] || exit 26
        [ "${3:-}" = -L ] || exit 27
        case "${4:-}" in
            "${FAKE_FIXTURE_REPO:?}/modules") exit 28 ;;
            "${TMPDIR:?}"/*/qubes-channel-source/modules) ;;
            *) exit 29 ;;
        esac
        [ -r "${4:?}/qubes/system.scm" ] || exit 30
        [ -r "${4:?}/../config/substitute-cache/signing-key.pub" ] || exit 31
        case "${5:-}" in
            "${TMPDIR:?}"/*/qubes-channel-source/config/qubes-os-normal.scm) ;;
            *) exit 32 ;;
        esac
        [ -r "${5:?}" ] || exit 33
        if [ "${FAKE_GUIX_MODE:?}" = system-failure ]; then
            exit 23
        fi
        if [ "$FAKE_GUIX_MODE" = upstream-probe-mixed ]; then
            printf '%s\n' "${FAKE_UPSTREAM_MISSING:?}"
        else
            printf '%s\n' "${FAKE_STORE_PATH:?}"
        fi
        ;;
    'pull -C')
        case "${3:-}" in
            "${TMPDIR:?}"/*/qubes-channel-source/config/guix-channels.scm) ;;
            *) exit 34 ;;
        esac
        [ -r "${3:?}" ] || exit 35
        [ "${5:-}" = --verbosity=3 ] || exit 39
        if [ "${FAKE_GUIX_MODE:?}" = pull-failure ]; then
            exit 24
        fi
        profile=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -p ]; then
                profile="${2:?}"
                break
            fi
            shift
        done
        [ -n "$profile" ]
        ln -s "${FAKE_PULL_TARGET:?}" "$profile"
        ;;
    'describe --format=json')
        [ "$0" = "${FAKE_PULL_TARGET:?}/bin/guix" ] || exit 37
        [ "${3:-}" = "--profile=${FAKE_PULL_TARGET:?}" ] || exit 38
        qubes_commit="${FAKE_SOURCE_COMMIT:?}"
        if [ "${FAKE_GUIX_MODE:?}" = pull-commit-mismatch ]; then
            qubes_commit=0000000000000000000000000000000000000000
        fi
        guix_url="${FAKE_GUIX_URL:-https://git.guix.gnu.org/guix.git}"
        guix_branch=master
        guix_commit="${FAKE_GUIX_COMMIT:?}"
        extra_guix_channel=""
        case "$FAKE_GUIX_MODE" in
            guix-url-mismatch) guix_url=https://example.invalid/guix.git ;;
            guix-branch-mismatch) guix_branch=testing ;;
            guix-commit-malformed) guix_commit=abc123 ;;
            guix-duplicate)
                extra_guix_channel=',{"name":"guix","url":"https://codeberg.org/guix/guix.git","branch":"master","commit":"'"$guix_commit"'"}'
                ;;
        esac
        printf '[{"name":"guix","url":"%s","branch":"%s","commit":"%s"}%s,' \
            "$guix_url" "$guix_branch" "$guix_commit" "$extra_guix_channel"
        printf '{"name":"qubes","commit":"%s"}]\n' "$qubes_commit"
        ;;
    'gc --derivers')
        printf '%s\n' "${FAKE_DERIVER:?}"
        ;;
    'gc -R')
        if [ "${FAKE_GUIX_MODE:?}" = upstream-probe-mixed ] &&
                [[ "${3:-}" != *.drv ]]; then
            printf '%s\n' \
                "${FAKE_UPSTREAM_PRESENT:?}" \
                "${FAKE_UPSTREAM_MISSING:?}" \
                "${FAKE_UPSTREAM_HTTP_RETRY:?}" \
                "${FAKE_UPSTREAM_CURL_RETRY:?}" \
                "${FAKE_UPSTREAM_NO_RESULT:?}"
        elif [ "${FAKE_GUIX_MODE:?}" = pull-closure-fixture ]; then
            case "${3:-}" in
                "${FAKE_DERIVER:?}")
                    printf '%s\n' \
                        "$FAKE_DERIVER" \
                        "${FAKE_MODULES_DERIVER:?}" \
                        "${FAKE_DERIVATION_SOURCE:?}"
                    ;;
                "${FAKE_MODULES_OUTPUT:?}")
                    printf '%s\n' \
                        "$FAKE_MODULES_OUTPUT" \
                        "${FAKE_MODULES_RUNTIME:?}"
                    ;;
                *) printf '%s\n' "${3:?}" ;;
            esac
        else
            case "${3:-}" in
                *.drv)
                    printf '%s\n' "${3:?}" "${FAKE_STORE_PATH:?}"
                    ;;
                *) printf '%s\n' "${FAKE_STORE_PATH:?}" ;;
            esac
        fi
        ;;
    'repl -q')
        [ "${3:-}" = -- ] || exit 40
        [ -s "${4:?}" ] || exit 41
        [ -s "${5:?}" ] || exit 42
        if [ "${FAKE_GUIX_MODE:?}" = repl-incomplete ]; then
            printf '%s\n' "${FAKE_STORE_PATH:?}"
            exit 0
        fi
        if [ "$FAKE_GUIX_MODE" = pull-closure-fixture ]; then
            grep -Fxq -- "${FAKE_DERIVER:?}" "$5" || exit 43
            grep -Fxq -- "${FAKE_MODULES_DERIVER:?}" "$5" || exit 44
            [ "$(wc -l < "$5" | tr -d '[:space:]')" -eq 2 ] || exit 45
            printf '%s\n' "${FAKE_MODULES_OUTPUT:?}"
        else
            printf '%s\n' "${FAKE_STORE_PATH:?}"
        fi
        printf '%s\n' qubes-realized-derivation-outputs-complete
        ;;
    'publish -p')
        bypass_options=0
        for argument in "$@"; do
            case "$argument" in
                --cache-bypass-threshold=0)
                    bypass_options=$((bypass_options + 1))
                    ;;
                --cache-bypass-threshold=*) exit 46 ;;
            esac
        done
        [ "$bypass_options" -eq 1 ] || exit 47
        if [ "${FAKE_GUIX_MODE:?}" = publisher-collision ]; then
            exit 98
        fi
        if [ "$FAKE_GUIX_MODE" = publisher-dies-during-bake ]; then
            while [ ! -e "${FAKE_BAKE_STARTED_FILE:?}" ]; do
                sleep 0.1
            done
            exit 97
        fi
        exec sleep 60
        ;;
    *)
        printf 'unexpected fake guix invocation: %q' "$1" >&2
        printf ' %q' "${@:2}" >&2
        printf '\n' >&2
        exit 25
        ;;
esac
EOF
chmod +x "$fake_guix"
mkdir -p "$fake_pull_target/bin"
ln -s "$fake_guix" "$fake_pull_target/bin/guix"

cat > "$fake_git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = -C ] &&
        [ "${2:-}" = "${FAKE_AUTHENTICATED_GUIX_CHECKOUT:?}" ]; then
    printf '%s\n' "${*:3}" >> "${FAKE_GIT_LOG:?}"
    case "${3:-}" in
        fetch)
            [ "${4:-}" = --no-tags ]
            [ "${5:-}" = origin ]
            [ "${6:-}" = \
                '+refs/heads/master:refs/remotes/origin/master' ]
            "$REAL_GIT" -C "$FAKE_AUTHENTICATED_GUIX_CHECKOUT" \
                update-ref refs/remotes/origin/master "$FAKE_GUIX_COMMIT"
            exit 0
            ;;
        merge-base)
            if [ "${FAKE_GUIX_MODE:-}" = guix-floor-failure ] &&
                    [ "${5:-}" = "${FAKE_GUIX_SECURITY_FLOOR:?}" ] &&
                    [ "${6:-}" = "$FAKE_GUIX_COMMIT" ]; then
                exit 1
            fi
            ;;
    esac
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$fake_git"

cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${FAKE_CURL_LOG:?}"
printf '\n' >> "${FAKE_CURL_LOG:?}"

output_file=""
header_file=""
config_file=""
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    case "${arguments[index]}" in
        --output) output_file="${arguments[index + 1]:?}" ;;
        --dump-header) header_file="${arguments[index + 1]:?}" ;;
        --config) config_file="${arguments[index + 1]:?}" ;;
    esac
done

if [ -n "$config_file" ]; then
    [ -r "$config_file" ]
    round=1
    if [ -n "${FAKE_UPSTREAM_ROUND_FILE:-}" ]; then
        if [ -r "$FAKE_UPSTREAM_ROUND_FILE" ]; then
            read -r round < "$FAKE_UPSTREAM_ROUND_FILE"
            round=$((round + 1))
        fi
        printf '%s\n' "$round" > "$FAKE_UPSTREAM_ROUND_FILE"
    fi
    batch_status=0
    request_count=0
    request_url=""
    while IFS= read -r config_line; do
        case "$config_line" in
            'url = "'*)
                [ -z "$request_url" ]
                request_url="${config_line#url = \"}"
                request_url="${request_url%\"}"
                ;;
            'output = "/dev/null"')
                [ -n "$request_url" ]
                request_count=$((request_count + 1))
                printf 'upstream-url %s\n' "$request_url" \
                    >> "${FAKE_CURL_LOG:?}"
                if [ -n "${FAKE_UPSTREAM_REQUESTS_FILE:-}" ]; then
                    printf '%s\t%s\n' "$round" "$request_url" \
                        >> "$FAKE_UPSTREAM_REQUESTS_FILE"
                fi
                hash="${request_url##*/}"
                hash="${hash%.narinfo}"
                if [ "${FAKE_GUIX_MODE:?}" = upstream-probe-mixed ]; then
                    present_hash="${FAKE_UPSTREAM_PRESENT##*/}"
                    present_hash="${present_hash%%-*}"
                    missing_hash="${FAKE_UPSTREAM_MISSING##*/}"
                    missing_hash="${missing_hash%%-*}"
                    http_retry_hash="${FAKE_UPSTREAM_HTTP_RETRY##*/}"
                    http_retry_hash="${http_retry_hash%%-*}"
                    curl_retry_hash="${FAKE_UPSTREAM_CURL_RETRY##*/}"
                    curl_retry_hash="${curl_retry_hash%%-*}"
                    no_result_hash="${FAKE_UPSTREAM_NO_RESULT##*/}"
                    no_result_hash="${no_result_hash%%-*}"
                    case "$hash:$round" in
                        "$present_hash":*) code=200; transfer_status=0 ;;
                        "$missing_hash":*) code=404; transfer_status=0 ;;
                        "$http_retry_hash":1) code=503; transfer_status=0 ;;
                        "$http_retry_hash":*) code=200; transfer_status=0 ;;
                        "$curl_retry_hash":1) code=000; transfer_status=28 ;;
                        "$curl_retry_hash":*) code=404; transfer_status=0 ;;
                        "$no_result_hash":1)
                            batch_status=28
                            request_url=""
                            continue
                            ;;
                        "$no_result_hash":*) code=200; transfer_status=0 ;;
                        *) exit 58 ;;
                    esac
                elif [ "$FAKE_GUIX_MODE" = upstream-probe-unresolved ]; then
                    code=503
                    transfer_status=0
                else
                    code=404
                    transfer_status=0
                fi
                printf '%s\t%s\t%s\n' \
                    "$request_url" "$code" "$transfer_status"
                if [ "$transfer_status" -ne 0 ]; then
                    batch_status="$transfer_status"
                fi
                request_url=""
                ;;
            *) exit 59 ;;
        esac
    done < "$config_file"
    [ -z "$request_url" ]
    [ "$request_count" -gt 0 ]
    exit "$batch_status"
fi

request_url="${arguments[${#arguments[@]} - 1]}"

case "$request_url" in
    https://ci.guix.gnu.org/*.narinfo)
        printf '404'
        exit 0
        ;;
    */nix-cache-info)
        if [ -n "$output_file" ] && [ "$output_file" != /dev/null ]; then
            printf '%s\n' 'StoreDir: /gnu/store' > "$output_file"
        fi
        ;;
    *.narinfo)
        [ -n "$output_file" ]
        [ -n "$header_file" ]
        case "${FAKE_GUIX_MODE:?}" in
            narinfo-bake-delay|narinfo-bake-timeout|publisher-dies-during-bake)
                if [ "$FAKE_GUIX_MODE" = publisher-dies-during-bake ]; then
                    : > "${FAKE_BAKE_STARTED_FILE:?}"
                fi
                attempts=0
                if [ -r "${FAKE_NARINFO_ATTEMPTS_FILE:?}" ]; then
                    read -r attempts < "$FAKE_NARINFO_ATTEMPTS_FILE"
                fi
                attempts=$((attempts + 1))
                printf '%s\n' "$attempts" > "$FAKE_NARINFO_ATTEMPTS_FILE"
                if [ "$FAKE_GUIX_MODE" != narinfo-bake-delay ] ||
                        [ "$attempts" -lt 2 ]; then
                    printf '%s\r\n%s\r\n\r\n' \
                        'HTTP/1.1 404 Not Found' 'X-Baking: 1' > "$header_file"
                    printf '404'
                    exit 0
                fi
                ;;
            narinfo-plain-404)
                printf '%s\r\n\r\n' 'HTTP/1.1 404 Not Found' > "$header_file"
                printf '404'
                exit 0
                ;;
        esac
        printf '%s\r\n\r\n' 'HTTP/1.1 200 OK' > "$header_file"
        {
            printf 'StorePath: %s\n' "${FAKE_STORE_PATH:?}"
            printf '%s\n' 'URL: nar/fake.nar.zst'
            if [ "${FAKE_GUIX_MODE:?}" != narinfo-missing-size ]; then
                printf '%s\n' 'FileSize: 4'
            fi
        } > "$output_file"
        printf '200'
        ;;
    */nar/fake.nar.zst)
        if [ "${FAKE_GUIX_MODE:?}" = nar-download-failure ]; then
            exit 56
        fi
        [ -n "$output_file" ]
        printf data > "$output_file"
        if [ -n "${FAKE_NAR_DOWNLOADED_FILE:-}" ]; then
            : > "$FAKE_NAR_DOWNLOADED_FILE"
        fi
        ;;
    *)
        printf 'unexpected fake curl URL: %s\n' "$request_url" >&2
        exit 57
        ;;
esac
EOF
chmod +x "$fake_curl"

# When enabled for the dedicated final-gap test, return the displaced cache's
# identity and then replace that path before the builder can quarantine it.
# All other stat calls are passed through unchanged.
cat > "$fake_stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_stat=/usr/bin/stat
if [ -n "${FAKE_STAT_SWAP_COUNTER:-}" ]; then
    arguments=("$@")
    target="${arguments[${#arguments[@]} - 1]}"
    case "$(basename -- "$target")" in
        .gap-site.tmp.*)
            count=0
            if [ -r "$FAKE_STAT_SWAP_COUNTER" ]; then
                read -r count < "$FAKE_STAT_SWAP_COUNTER"
            fi
            count=$((count + 1))
            printf '%s\n' "$count" > "$FAKE_STAT_SWAP_COUNTER"
            identity="$("$real_stat" "$@")"
            if [ "$count" -eq 2 ]; then
                mv -T -- "$target" "${FAKE_STAT_APPROVED_OUTPUT:?}"
                mv -T -- "${FAKE_STAT_REPLACEMENT:?}" "$target"
            fi
            printf '%s\n' "$identity"
            exit 0
            ;;
    esac
fi
exec "$real_stat" "$@"
EOF
chmod +x "$fake_stat"
: > "$fake_guix_log"
: > "$fake_curl_log"
: > "$fake_git_log"
export FAKE_GIT_LOG="$fake_git_log"

# A derivation reference closure contains .drv files, not their outputs.  Model
# the channel-composed modules output as a realized output of a nested
# derivation, with one runtime requisite that only the later gc -R can find.
closure_manifest="$work_dir/pull-closure-paths.json"
closure_log="$work_dir/pull-closure.log"
: > "$fake_guix_log"
closure_digest="$(
    env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE=pull-closure-fixture \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        GUIX="$fake_guix" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" prepare \
            --manifest "$closure_manifest" \
            "${security_options[@]}" \
            --variant normal 2> "$closure_log"
)" || {
    sed 's/^/pull closure: /' "$closure_log" >&2
    exit 1
}
[[ "$closure_digest" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'pull closure prepare returned an invalid manifest digest\n' >&2
    exit 1
}
grep -q '^repl -q$' "$fake_guix_log" || {
    printf 'pull closure preparation did not enumerate derivation outputs\n' >&2
    exit 1
}
python3 - \
    "$closure_manifest" \
    "$fake_modules_output" \
    "$fake_modules_runtime" \
    "$fake_derivation_source" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    paths = set(json.load(source)["store_paths"])

missing = set(sys.argv[2:]) - paths
if missing:
    raise SystemExit(f"prepared manifest omits pull closure paths: {missing}")
PY

# Probe all pending paths in one curl process, retain exact 200/404 results,
# and retry only transfers whose outcome was indeterminate.
mixed_manifest="$work_dir/upstream-mixed-paths.json"
mixed_log="$work_dir/upstream-mixed.log"
: > "$fake_curl_log"
rm -f -- "$fake_upstream_round" "$fake_upstream_requests"
mixed_digest="$(
    env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE=upstream-probe-mixed \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        FAKE_UPSTREAM_ROUND_FILE="$fake_upstream_round" \
        FAKE_UPSTREAM_REQUESTS_FILE="$fake_upstream_requests" \
        FAKE_UPSTREAM_PRESENT="$fake_upstream_present" \
        FAKE_UPSTREAM_MISSING="$fake_upstream_missing" \
        FAKE_UPSTREAM_HTTP_RETRY="$fake_upstream_http_retry" \
        FAKE_UPSTREAM_CURL_RETRY="$fake_upstream_curl_retry" \
        FAKE_UPSTREAM_NO_RESULT="$fake_upstream_no_result" \
        GUIX="$fake_guix" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" prepare \
            --manifest "$mixed_manifest" \
            "${security_options[@]}" \
            --variant normal 2> "$mixed_log"
)" || {
    sed 's/^/mixed upstream probe: /' "$mixed_log" >&2
    exit 1
}
[[ "$mixed_digest" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'mixed upstream probe returned an invalid manifest digest\n' >&2
    exit 1
}
[ "$(< "$fake_upstream_round")" -eq 2 ] || {
    printf 'mixed upstream probe did not stop after resolving round two\n' >&2
    exit 1
}
python3 - \
    "$mixed_manifest" \
    "$fake_upstream_missing" \
    "$fake_upstream_curl_retry" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    paths = set(json.load(source)["store_paths"])
expected = set(sys.argv[2:])
if paths != expected:
    raise SystemExit(f"wrong channel-specific paths: {paths} != {expected}")
PY
for path in \
        "$fake_upstream_present" \
        "$fake_upstream_missing"; do
    hash="${path##*/}"
    hash="${hash%%-*}"
    [ "$(grep -Fc "$hash.narinfo" "$fake_upstream_requests")" -eq 1 ] || {
        printf 'definitive upstream result was queried again: %s\n' "$hash" >&2
        exit 1
    }
done
for path in \
        "$fake_upstream_http_retry" \
        "$fake_upstream_curl_retry" \
        "$fake_upstream_no_result"; do
    hash="${path##*/}"
    hash="${hash%%-*}"
    [ "$(grep -Fc "$hash.narinfo" "$fake_upstream_requests")" -eq 2 ] || {
        printf 'indeterminate upstream result was not retried once: %s\n' \
            "$hash" >&2
        exit 1
    }
done
upstream_batch="$(grep -F -- '--config' "$fake_curl_log" | head -n 1)"
for expected in \
        '--proto =https' \
        '--proto-redir =https' \
        '--tlsv1.2' \
        '--connect-timeout 10' \
        '--max-time 30' \
        '--parallel ' \
        '--parallel-max 16'; do
    grep -Fq -- "$expected" <<< "$upstream_batch" || {
        printf 'batched upstream probe lost option: %s\n' "$expected" >&2
        exit 1
    }
done

# An upstream failure that never becomes definitive must exhaust the bounded
# rounds and fail before a path manifest can be published.
unresolved_manifest="$work_dir/upstream-unresolved-paths.json"
unresolved_log="$work_dir/upstream-unresolved.log"
: > "$fake_curl_log"
rm -f -- "$fake_upstream_round" "$fake_upstream_requests" \
    "$unresolved_manifest"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=upstream-probe-unresolved \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    FAKE_UPSTREAM_ROUND_FILE="$fake_upstream_round" \
    FAKE_UPSTREAM_REQUESTS_FILE="$fake_upstream_requests" \
    GUIX="$fake_guix" \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" prepare \
        --manifest "$unresolved_manifest" \
        "${security_options[@]}" \
        --variant normal > /dev/null 2> "$unresolved_log"; then
    printf 'unresolved upstream probe unexpectedly succeeded\n' >&2
    exit 1
fi
[ "$(< "$fake_upstream_round")" -eq 4 ] || {
    printf 'unresolved upstream probe did not run four bounded rounds\n' >&2
    exit 1
}
[ "$(wc -l < "$fake_upstream_requests" | tr -d ' ')" -eq 4 ] || {
    printf 'unresolved upstream path was not queried once per round\n' >&2
    exit 1
}
grep -Fq 'could not determine upstream status for 1 paths after 4 rounds' \
    "$unresolved_log" || {
    printf 'unresolved upstream failure was misdiagnosed\n' >&2
    exit 1
}
[ ! -e "$unresolved_manifest" ] || {
    printf 'unresolved upstream probe published a path manifest\n' >&2
    exit 1
}

# Prepare succeeds before either externally supplied signing-key file exists.
# It realizes and records all inputs, but cannot reach guix publish.
split_manifest="$work_dir/prepared-paths.json"
split_prepare_log="$work_dir/split-prepare.log"
split_digest="$(
    env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE=publisher-success \
        FAKE_GUIX_URL=https://codeberg.org/guix/guix.git \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        GUIX="$fake_guix" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" prepare \
            --manifest "$split_manifest" \
            "${security_options[@]}" \
            --variant normal 2> "$split_prepare_log"
)" || {
    sed 's/^/split prepare: /' "$split_prepare_log" >&2
    exit 1
}
[[ "$split_digest" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'prepare did not return one manifest SHA-256\n' >&2
    exit 1
}
[ "$(stat --format='%a' -- "$split_manifest")" = 400 ] || {
    printf 'prepare manifest is not read-only\n' >&2
    exit 1
}
if ! grep -q '^pull -C$' "$fake_guix_log" ||
        ! grep -q '^system build$' "$fake_guix_log"; then
    printf 'split prepare did not realize the pull profile and system\n' >&2
    exit 1
fi
if grep -q '^publish -p$' "$fake_guix_log"; then
    printf 'prepare reached guix publish without signing keys\n' >&2
    exit 1
fi
[ ! -e "$public_key" ] && [ ! -e "$private_key" ] || {
    printf 'signing-key fixture unexpectedly existed during prepare\n' >&2
    exit 1
}

# Only now make the signing material available.  Export must consume the
# concrete manifest and call publish directly: pull, describe, gc, and system
# build would all cross the private-key isolation boundary.
cp -- "$fixture_repo/config/substitute-cache/signing-key.pub" "$public_key"
printf '%s\n' private > "$private_key"
: > "$fake_guix_log"
: > "$fake_curl_log"
split_output="$work_dir/split-site"
split_export_log="$work_dir/split-export.log"
env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$work_dir/must-not-be-used-by-export" \
    GUIX_PUBLISH_PORT=18190 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" export \
        --manifest "$split_manifest" \
        --manifest-sha256 "$split_digest" \
        --output "$split_output" \
        --public-key "$public_key" \
        --private-key "$private_key" > "$split_export_log" 2>&1 || {
    sed 's/^/split export: /' "$split_export_log" >&2
    exit 1
}
if [ "$(wc -l < "$fake_guix_log" | tr -d ' ')" -ne 1 ] ||
        ! grep -q '^publish -p$' "$fake_guix_log"; then
    printf 'export invoked Guix operations other than publish\n' >&2
    sed 's/^/split export guix: /' "$fake_guix_log" >&2
    exit 1
fi
[ -s "$split_output/$fake_store_hash.narinfo" ] || {
    printf 'split export did not produce the static cache\n' >&2
    exit 1
}
grep -Fxq \
        'fetch --no-tags origin +refs/heads/master:refs/remotes/origin/master' \
        "$fake_git_log" || {
    printf 'prepare did not refresh the bootstrap-authenticated Guix checkout\n' \
        >&2
    exit 1
}

# Signing-capable export consumes only the manifest and never accepts either
# source-authentication input from prepare.
: > "$fake_guix_log"
export_security_log="$work_dir/export-security-options.log"
if "$build_script" export \
        --manifest "$split_manifest" \
        --manifest-sha256 "$split_digest" \
        --output "$split_output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" >"$export_security_log" 2>&1; then
    printf 'export accepted prepare-only Guix authentication options\n' >&2
    exit 1
fi
grep -q -- '--authenticated-guix-checkout is not accepted by export' \
        "$export_security_log" || {
    printf 'export misdiagnosed prepare-only Guix authentication options\n' >&2
    exit 1
}
[ ! -s "$fake_guix_log" ] || {
    printf 'rejected export authentication options reached Guix\n' >&2
    exit 1
}

# Even a syntactically harmless change is rejected against the digest carried
# out of the prepare step, before the signing-capable Guix is invoked.
tampered_manifest="$work_dir/tampered-paths.json"
cp -- "$split_manifest" "$tampered_manifest"
chmod u+w "$tampered_manifest"
printf ' \n' >> "$tampered_manifest"
chmod 0400 "$tampered_manifest"
: > "$fake_guix_log"
tampered_log="$work_dir/tampered-manifest.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" export \
        --manifest "$tampered_manifest" \
        --manifest-sha256 "$split_digest" \
        --output "$split_output" \
        --public-key "$public_key" \
        --private-key "$private_key" > "$tampered_log" 2>&1; then
    printf 'export accepted a modified prepare manifest\n' >&2
    exit 1
fi
grep -q 'SHA-256 does not match the prepare-step output' "$tampered_log" || {
    printf 'modified prepare manifest was misdiagnosed\n' >&2
    exit 1
}
[ ! -s "$fake_guix_log" ] || {
    printf 'modified prepare manifest reached Guix\n' >&2
    exit 1
}

# Strict path validation is independent of the digest handoff: even when a
# forged manifest is paired with its own digest, traversal cannot reach the
# signing-capable publisher.
injected_manifest="$work_dir/injected-paths.json"
sed "s|$fake_store_path|$work_dir/store/../private|" \
    "$split_manifest" > "$injected_manifest"
chmod 0400 "$injected_manifest"
injected_digest="$(sha256sum "$injected_manifest" | cut -d ' ' -f 1)"
: > "$fake_guix_log"
injected_log="$work_dir/injected-manifest.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" export \
        --manifest "$injected_manifest" \
        --manifest-sha256 "$injected_digest" \
        --output "$split_output" \
        --public-key "$public_key" \
        --private-key "$private_key" > "$injected_log" 2>&1; then
    printf 'export accepted a path-injecting prepare manifest\n' >&2
    exit 1
fi
grep -q 'is not a confined Guix store path' "$injected_log" || {
    printf 'path-injecting prepare manifest was misdiagnosed\n' >&2
    exit 1
}
[ ! -s "$fake_guix_log" ] || {
    printf 'path-injecting prepare manifest reached Guix\n' >&2
    exit 1
}

invalid_timeout_log="$work_dir/invalid-bake-timeout.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal \
        --bake-timeout 0 >"$invalid_timeout_log" 2>&1; then
    printf 'substitute-cache build accepted a zero bake timeout\n' >&2
    exit 1
fi
grep -q 'invalid --bake-timeout: 0' "$invalid_timeout_log" || {
    printf 'invalid bake timeout was misdiagnosed\n' >&2
    exit 1
}
[ ! -s "$fake_guix_log" ] || {
    printf 'invalid bake timeout was rejected only after invoking guix\n' >&2
    exit 1
}

assert_dirty_source_rejected() {
    local relative_path="$1"
    local label="$2"
    local backup="$work_dir/dirty-source-backup"
    local dirty_log="$work_dir/dirty-${label}.log"

    cp -- "$fixture_repo/$relative_path" "$backup"
    printf '%s\n' '# uncommitted provenance test change' >> \
        "$fixture_repo/$relative_path"
    : > "$fake_guix_log"
    if env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE=system-failure \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        GUIX="$fake_guix" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" \
            --output "$output" \
            --public-key "$public_key" \
            --private-key "$private_key" \
            "${security_options[@]}" \
            --variant normal >"$dirty_log" 2>&1; then
        printf 'substitute-cache build accepted dirty %s\n' "$relative_path" >&2
        return 1
    fi
    grep -q 'source changes must be committed' "$dirty_log" || {
        printf 'dirty %s was misdiagnosed\n' "$relative_path" >&2
        return 1
    }
    [ ! -s "$fake_guix_log" ] || {
        printf 'dirty %s reached Guix\n' "$relative_path" >&2
        return 1
    }
    mv -- "$backup" "$fixture_repo/$relative_path"
}

assert_dirty_source_rejected config/qubes-os-normal.scm system-config
assert_dirty_source_rejected scripts/lib.sh shell-library
assert_dirty_source_rejected scripts/git-tracked-tree.sh git-tree-library

: > "$fake_guix_log"
pull_mismatch_log="$work_dir/pull-commit-mismatch.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=pull-commit-mismatch \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >"$pull_mismatch_log" 2>&1; then
    printf 'substitute-cache build accepted a mismatched pulled Qubes commit\n' >&2
    exit 1
fi
grep -q '^pull -C$' "$fake_guix_log" || {
    printf 'pull mismatch test did not resolve the channel profile\n' >&2
    exit 1
}
grep -q '^describe --format=json$' "$fake_guix_log" || {
    printf 'pull mismatch test did not inspect the channel manifest\n' >&2
    exit 1
}
if grep -Eq '^(system build|publish -p)$' "$fake_guix_log"; then
    printf 'pull mismatch reached a system build or publication\n' >&2
    exit 1
fi
grep -q 'pulled Qubes channel commit does not match immutable source' \
        "$pull_mismatch_log" || {
    printf 'pull commit mismatch was misdiagnosed\n' >&2
    exit 1
}
[ "$(< "$output/sentinel")" = sentinel ] || {
    printf 'existing cache changed after pull commit mismatch\n' >&2
    exit 1
}
if find "$work_dir" -maxdepth 1 -name '.site.tmp.*' -print -quit |
        grep -q .; then
    printf 'staged cache leaked after pull commit mismatch\n' >&2
    exit 1
fi

assert_guix_provenance_rejected() {
    local mode="$1"
    local expected="$2"
    local manifest="$work_dir/$mode-manifest.json"
    local failure_log="$work_dir/$mode.log"

    : > "$fake_guix_log"
    : > "$fake_git_log"
    if env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE="$mode" \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        GUIX="$fake_guix" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" prepare \
            --manifest "$manifest" \
            "${security_options[@]}" \
            --variant normal >"$failure_log" 2>&1; then
        printf 'prepare accepted invalid Guix provenance mode %s\n' "$mode" >&2
        return 1
    fi
    grep -Fq -- "$expected" "$failure_log" || {
        printf 'Guix provenance failure %s was misdiagnosed\n' "$mode" >&2
        sed 's/^/provenance failure: /' "$failure_log" >&2
        return 1
    }
    grep -q '^describe --format=json$' "$fake_guix_log" || {
        printf 'Guix provenance failure %s skipped profile inspection\n' \
            "$mode" >&2
        return 1
    }
    if grep -Eq '^(system build|publish -p)$' "$fake_guix_log"; then
        printf 'Guix provenance failure %s reached realization or signing\n' \
            "$mode" >&2
        return 1
    fi
}

assert_guix_provenance_rejected \
    guix-duplicate \
    'pulled channel manifest must contain exactly one Guix channel'
assert_guix_provenance_rejected \
    guix-url-mismatch \
    'pulled Guix channel is not an approved official master channel'
assert_guix_provenance_rejected \
    guix-branch-mismatch \
    'pulled Guix channel is not an approved official master channel'
assert_guix_provenance_rejected \
    guix-commit-malformed \
    'pulled Guix channel commit is not a full lowercase object ID'
assert_guix_provenance_rejected \
    guix-floor-failure \
    "resolved Guix $FAKE_GUIX_COMMIT predates security floor $guix_security_floor"

: > "$fake_guix_log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=system-failure \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$unsafe_output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >/dev/null 2>&1; then
    printf 'substitute-cache build accepted a non-cache output directory\n' >&2
    exit 1
fi
[ ! -s "$fake_guix_log" ] || {
    printf 'non-cache output was rejected only after invoking guix\n' >&2
    exit 1
}
[ "$(< "$unsafe_output/unrelated-data")" = keep ] || {
    printf 'non-cache output directory was modified\n' >&2
    exit 1
}

assert_preserved_after_failure() {
    local mode="$1"
    local failure_log="$work_dir/$mode-preserved.log"

    : > "$fake_guix_log"

    if env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE="$mode" \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        GUIX="$fake_guix" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" \
            --output "$output" \
            --public-key "$public_key" \
            --private-key "$private_key" \
            "${security_options[@]}" \
            --variant normal >"$failure_log" 2>&1; then
        printf 'substitute-cache build unexpectedly succeeded in %s mode\n' \
            "$mode" >&2
        return 1
    fi

    grep -q '^pull -C$' "$fake_guix_log" || {
        printf 'guix pull was not reached in %s mode\n' "$mode" >&2
        return 1
    }
    case "$mode" in
        pull-failure)
            if grep -q '^system build$' "$fake_guix_log"; then
                printf 'system build was reached after %s\n' "$mode" >&2
                return 1
            fi
            ;;
        *)
            grep -q '^system build$' "$fake_guix_log" || {
                printf 'system build was not reached in %s mode\n' \
                    "$mode" >&2
                return 1
            }
            ;;
    esac
    if [ "$mode" = repl-incomplete ]; then
        grep -q '^repl -q$' "$fake_guix_log" || {
            printf 'derivation enumeration was not reached in %s mode\n' \
                "$mode" >&2
            return 1
        }
        grep -q 'derivation output resolution did not complete' \
            "$failure_log" || {
            printf 'incomplete derivation output was misdiagnosed\n' >&2
            return 1
        }
    fi

    [ "$(< "$output/sentinel")" = sentinel ] || {
        printf 'existing cache changed after %s\n' "$mode" >&2
        return 1
    }
    [ "$(find "$output" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ] || {
        printf 'partial cache exposed after %s\n' "$mode" >&2
        return 1
    }
    if find "$work_dir" -maxdepth 1 -name '.site.tmp.*' -print -quit |
            grep -q .; then
        printf 'staged cache leaked after %s\n' "$mode" >&2
        sed 's/^/failed build: /' "$failure_log" >&2
        return 1
    fi
}

assert_preserved_after_failure system-failure
assert_preserved_after_failure pull-failure
assert_preserved_after_failure repl-incomplete

: > "$fake_guix_log"
: > "$fake_curl_log"
collision_log="$work_dir/publisher-collision.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-collision \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    GUIX_PUBLISH_PORT=18181 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >"$collision_log" 2>&1; then
    printf 'dead publisher was mistaken for an unrelated HTTP service\n' >&2
    exit 1
fi
grep -q '^publish -p$' "$fake_guix_log" || {
    printf 'publisher collision test did not reach guix publish\n' >&2
    sed 's/^/collision test: /' "$collision_log" >&2
    sed 's/^/fake guix: /' "$fake_guix_log" >&2
    exit 1
}
grep -q 'guix publish exited before becoming ready (status 98)' \
    "$collision_log" || {
    printf 'publisher collision was not attributed to the spawned process\n' >&2
    sed 's/^/collision test: /' "$collision_log" >&2
    sed 's/^/fake guix: /' "$fake_guix_log" >&2
    exit 1
}
[ "$(< "$output/sentinel")" = sentinel ] || {
    printf 'existing cache changed after publisher collision\n' >&2
    exit 1
}

assert_bake_failure_preserved() {
    local mode="$1"
    local port="$2"
    local timeout="$3"
    local expected="$4"
    local bake_log="$work_dir/$mode.log"
    local started elapsed

    : > "$fake_guix_log"
    : > "$fake_curl_log"
    rm -f -- "$fake_narinfo_attempts" "$fake_bake_started"
    started="$(date +%s)"
    if env \
        FAKE_GUIX_LOG="$fake_guix_log" \
        FAKE_GUIX_MODE="$mode" \
        FAKE_STORE_PATH="$fake_store_path" \
        FAKE_PULL_TARGET="$fake_pull_target" \
        FAKE_DERIVER="$fake_deriver" \
        FAKE_CURL_LOG="$fake_curl_log" \
        FAKE_NARINFO_ATTEMPTS_FILE="$fake_narinfo_attempts" \
        FAKE_BAKE_STARTED_FILE="$fake_bake_started" \
        GUIX="$fake_guix" \
        GUIX_PUBLISH_PORT="$port" \
        PATH="$work_dir:$PATH" \
        TMPDIR="$work_dir" \
        "$build_script" \
            --output "$output" \
            --public-key "$public_key" \
            --private-key "$private_key" \
            "${security_options[@]}" \
            --variant normal \
            --bake-timeout "$timeout" >"$bake_log" 2>&1; then
        printf 'substitute-cache build unexpectedly accepted %s\n' "$mode" >&2
        return 1
    fi
    elapsed=$(( $(date +%s) - started ))

    grep -Fq "$expected" "$bake_log" || {
        printf 'bake failure was misdiagnosed in %s mode\n' "$mode" >&2
        sed 's/^/bake failure: /' "$bake_log" >&2
        return 1
    }
    if [ "$mode" = narinfo-bake-timeout ] &&
            { [ "$elapsed" -lt 1 ] || [ "$elapsed" -gt 6 ]; }; then
        printf 'bake timeout took %ss instead of approximately 2s\n' \
            "$elapsed" >&2
        return 1
    fi
    [ "$(< "$output/sentinel")" = sentinel ] || {
        printf 'existing cache changed after %s\n' "$mode" >&2
        return 1
    }
    if find "$work_dir" -maxdepth 1 -name '.site.tmp.*' -print -quit |
            grep -q .; then
        printf 'staged cache leaked after %s\n' "$mode" >&2
        return 1
    fi
}

assert_bake_failure_preserved \
    narinfo-bake-timeout 18184 2 \
    'could not bake narinfo'
assert_bake_failure_preserved \
    narinfo-plain-404 18185 10 \
    'HTTP 404 without X-Baking: 1'
assert_bake_failure_preserved \
    publisher-dies-during-bake 18186 10 \
    'guix publish exited while baking narinfo'
assert_bake_failure_preserved \
    narinfo-missing-size 18191 10 \
    'cached narinfo has no FileSize'
if ! grep -Fq 'timeout 2s' "$work_dir/narinfo-bake-timeout.log" ||
        ! grep -Fq 'last result HTTP 404' \
            "$work_dir/narinfo-bake-timeout.log"; then
    printf 'bounded bake timeout lost its final HTTP context\n' >&2
    exit 1
fi
grep -Fq "while baking narinfo for $fake_store_path (status 97)" \
        "$work_dir/publisher-dies-during-bake.log" || {
    printf 'publisher death lost its bake path or exit status\n' >&2
    exit 1
}

: > "$fake_guix_log"
: > "$fake_curl_log"
late_failure_log="$work_dir/late-download-failure.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=nar-download-failure \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    GUIX_PUBLISH_PORT=18182 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >"$late_failure_log" 2>&1; then
    printf 'substitute-cache build ignored a late nar download failure\n' >&2
    exit 1
fi
grep -q '/nar/fake.nar.zst' "$fake_curl_log" || {
    printf 'late failure test did not reach the nar download\n' >&2
    sed 's/^/late failure: /' "$late_failure_log" >&2
    exit 1
}
[ "$(< "$output/sentinel")" = sentinel ] || {
    printf 'existing cache changed after a late download failure\n' >&2
    exit 1
}
if find "$work_dir" -maxdepth 1 -name '.site.tmp.*' -print -quit |
        grep -q .; then
    printf 'staged cache leaked after a late download failure\n' >&2
    exit 1
fi

# Hold the same parent-directory lock used by publication until the build has
# completed its last download.  Replace OUTPUT while the builder is waiting,
# then verify that its locked revalidation preserves the unexpected tree.
(
    exec {lock_fd}<"$work_dir"
    flock --exclusive "$lock_fd"
    : > "$publication_lock_ready"
    while [ ! -e "$publication_lock_release" ]; do
        sleep 0.05
    done
) &
publication_lock_pid="$!"
for _ in {1..200}; do
    [ -e "$publication_lock_ready" ] && break
    kill -0 "$publication_lock_pid" 2>/dev/null || break
    sleep 0.05
done
[ -e "$publication_lock_ready" ] || {
    printf 'could not acquire the publication race test lock\n' >&2
    exit 1
}

: > "$fake_guix_log"
: > "$fake_curl_log"
late_replacement_log="$work_dir/late-output-replacement.log"
env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    FAKE_NAR_DOWNLOADED_FILE="$late_downloaded" \
    GUIX="$fake_guix" \
    GUIX_PUBLISH_PORT=18188 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$late_output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >"$late_replacement_log" 2>&1 &
publication_pid="$!"
for _ in {1..200}; do
    [ -e "$late_downloaded" ] && break
    kill -0 "$publication_pid" 2>/dev/null || break
    sleep 0.05
done
if [ ! -e "$late_downloaded" ] ||
        ! kill -0 "$publication_pid" 2>/dev/null; then
    : > "$publication_lock_release"
    wait "$publication_lock_pid" 2>/dev/null || true
    publication_lock_pid=""
    wait "$publication_pid" 2>/dev/null || true
    publication_pid=""
    printf 'late replacement test did not reach the locked publication step\n' \
        >&2
    sed 's/^/late replacement: /' "$late_replacement_log" >&2
    exit 1
fi

mv -T -- "$late_output" "$late_displaced"
mv -T -- "$late_replacement" "$late_output"
: > "$publication_lock_release"
wait "$publication_lock_pid"
publication_lock_pid=""
if wait "$publication_pid"; then
    publication_pid=""
    printf 'substitute-cache build replaced an unexpected late output\n' >&2
    exit 1
fi
publication_pid=""

grep -Fq 'refusing to replace non-cache output directory' \
        "$late_replacement_log" || {
    printf 'late output replacement was misdiagnosed\n' >&2
    sed 's/^/late replacement: /' "$late_replacement_log" >&2
    exit 1
}
[ "$(< "$late_output/nested/unrelated-data")" = preserve ] || {
    printf 'unexpected late output was modified or removed\n' >&2
    exit 1
}
[ "$(< "$late_displaced/sentinel")" = original ] || {
    printf 'previous cache was modified during late replacement test\n' >&2
    exit 1
}
if find "$work_dir" -maxdepth 1 -name '.late-site.tmp.*' -print -quit |
        grep -q .; then
    printf 'staged cache leaked after a late output replacement\n' >&2
    exit 1
fi

: > "$fake_guix_log"
: > "$fake_curl_log"
rm -f -- "$gap_stat_counter"
gap_replacement_log="$work_dir/final-gap-replacement.log"
if env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    FAKE_STAT_SWAP_COUNTER="$gap_stat_counter" \
    FAKE_STAT_APPROVED_OUTPUT="$gap_displaced" \
    FAKE_STAT_REPLACEMENT="$gap_replacement" \
    GUIX="$fake_guix" \
    GUIX_PUBLISH_PORT=18189 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$gap_output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >"$gap_replacement_log" 2>&1; then
    printf 'substitute-cache build deleted a final-gap replacement\n' >&2
    exit 1
fi

grep -Fq 'displaced output changed before cleanup; restored unexpected data' \
        "$gap_replacement_log" || {
    printf 'final-gap output replacement was misdiagnosed\n' >&2
    sed 's/^/final-gap replacement: /' "$gap_replacement_log" >&2
    exit 1
}
[ "$(< "$gap_displaced/sentinel")" = original ] || {
    printf 'approved displaced cache was lost during final-gap test\n' >&2
    exit 1
}
gap_preserved="$(
    find "$work_dir" -maxdepth 1 -type d -name '.gap-site.tmp.*' \
        -print -quit
)"
[ -n "$gap_preserved" ] &&
        [ "$(< "$gap_preserved/nested/unrelated-data")" = preserve ] || {
    printf 'unexpected final-gap replacement was modified or removed\n' >&2
    exit 1
}
if find "$work_dir" -maxdepth 1 -name '.gap-site.retired.*' -print -quit |
        grep -q .; then
    printf 'retirement directory leaked after restoring unexpected data\n' >&2
    exit 1
fi

: > "$fake_guix_log"
: > "$fake_curl_log"
success_log="$work_dir/publisher-success.log"
env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=publisher-success \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    GUIX="$fake_guix" \
    GUIX_PUBLISH_PORT=18183 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal >"$success_log" 2>&1 || {
    sed 's/^/successful publication: /' "$success_log" >&2
    exit 1
}

grep -Fq "upstream-url https://ci.guix.gnu.org/$fake_store_hash.narinfo" \
        "$fake_curl_log" || {
    printf 'successful publication did not query the upstream cache\n' >&2
    exit 1
}

[ ! -e "$output/sentinel" ] || {
    printf 'atomic cache exchange retained the previous payload\n' >&2
    exit 1
}
[ "$(< "$output/.qubes-template-guix-cache")" = \
        'qubes-template-guix static cache v1' ] || {
    printf 'published cache has no ownership marker\n' >&2
    exit 1
}
[ -s "$output/nix-cache-info" ] &&
        [ -s "$output/$fake_store_hash.narinfo" ] &&
        [ "$(< "$output/nar/fake.nar.zst")" = data ] || {
    printf 'published cache payload is incomplete\n' >&2
    exit 1
}
if find "$work_dir" -maxdepth 1 -name '.site.tmp.*' -print -quit |
        grep -q .; then
    printf 'old cache tree leaked after atomic exchange\n' >&2
    exit 1
fi

rm -f -- "$fake_narinfo_attempts"
delayed_log="$work_dir/publisher-delayed-bake.log"
env \
    FAKE_GUIX_LOG="$fake_guix_log" \
    FAKE_GUIX_MODE=narinfo-bake-delay \
    FAKE_STORE_PATH="$fake_store_path" \
    FAKE_PULL_TARGET="$fake_pull_target" \
    FAKE_DERIVER="$fake_deriver" \
    FAKE_CURL_LOG="$fake_curl_log" \
    FAKE_NARINFO_ATTEMPTS_FILE="$fake_narinfo_attempts" \
    GUIX="$fake_guix" \
    GUIX_PUBLISH_PORT=18187 \
    PATH="$work_dir:$PATH" \
    TMPDIR="$work_dir" \
    "$build_script" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        "${security_options[@]}" \
        --variant normal \
        --bake-timeout 10 >"$delayed_log" 2>&1 || {
    sed 's/^/delayed bake: /' "$delayed_log" >&2
    exit 1
}
[ "$(< "$fake_narinfo_attempts")" -eq 2 ] || {
    printf 'delayed bake did not retry exactly once\n' >&2
    exit 1
}
[ -s "$output/$fake_store_hash.narinfo" ] &&
        [ "$(< "$output/nar/fake.nar.zst")" = data ] || {
    printf 'delayed bake publication is incomplete\n' >&2
    exit 1
}

printf '%s\n' 'substitute-cache publication safety check passed'
