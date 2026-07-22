#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "$repo_root/work.cache-failure.XXXXXX")"

cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

fake_guix="$work_dir/guix"
fake_guix_log="$work_dir/guix.log"
fake_curl="$work_dir/curl"
fake_curl_log="$work_dir/curl.log"
fake_narinfo_attempts="$work_dir/narinfo-attempts"
fake_bake_started="$work_dir/bake-started"
fake_store_path="$work_dir/store/system"
fake_pull_target="$work_dir/store/pull-profile"
fake_deriver="$work_dir/store/pull-profile.drv"
public_key="$work_dir/signing-key.pub"
private_key="$work_dir/signing-key.sec"
output="$work_dir/site"
unsafe_output="$work_dir/not-a-cache"

mkdir -p "$fake_store_path" "$fake_pull_target" "$output" "$unsafe_output"
: > "$fake_deriver"
printf '%s\n' 'qubes-template-guix static cache v1' > \
    "$output/.qubes-template-guix-cache"
printf '%s\n' sentinel > "$output/sentinel"
printf '%s\n' keep > "$unsafe_output/unrelated-data"
printf '%s\n' public > "$public_key"
printf '%s\n' private > "$private_key"

cat > "$fake_guix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s %s\n' "${1:-}" "${2:-}" >> "${FAKE_GUIX_LOG:?}"

case "${1:-} ${2:-}" in
    'system build')
        if [ "${FAKE_GUIX_MODE:?}" = system-failure ]; then
            exit 23
        fi
        printf '%s\n' "${FAKE_STORE_PATH:?}"
        ;;
    'pull -C')
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
    'gc --derivers')
        printf '%s\n' "${FAKE_DERIVER:?}"
        ;;
    'gc -R')
        printf '%s\n' "${FAKE_STORE_PATH:?}"
        ;;
    'publish -p')
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

cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${FAKE_CURL_LOG:?}"
printf '\n' >> "${FAKE_CURL_LOG:?}"

output_file=""
header_file=""
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    case "${arguments[index]}" in
        --output) output_file="${arguments[index + 1]:?}" ;;
        --dump-header) header_file="${arguments[index + 1]:?}" ;;
    esac
done
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
            printf '%s\n' 'URL: nar/fake.nar.zst' 'FileSize: 4'
        } > "$output_file"
        printf '200'
        ;;
    */nar/fake.nar.zst)
        if [ "${FAKE_GUIX_MODE:?}" = nar-download-failure ]; then
            exit 56
        fi
        [ -n "$output_file" ]
        printf data > "$output_file"
        ;;
    *)
        printf 'unexpected fake curl URL: %s\n' "$request_url" >&2
        exit 57
        ;;
esac
EOF
chmod +x "$fake_curl"
: > "$fake_guix_log"
: > "$fake_curl_log"

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
    "$repo_root/scripts/build-substitute-cache.sh" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
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
    "$repo_root/scripts/build-substitute-cache.sh" \
        --output "$unsafe_output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
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
        "$repo_root/scripts/build-substitute-cache.sh" \
            --output "$output" \
            --public-key "$public_key" \
            --private-key "$private_key" \
            --variant normal >/dev/null 2>&1; then
        printf 'substitute-cache build unexpectedly succeeded in %s mode\n' \
            "$mode" >&2
        return 1
    fi

    grep -q '^system build$' "$fake_guix_log" || {
        printf 'system build was not reached in %s mode\n' "$mode" >&2
        return 1
    }
    if [ "$mode" = pull-failure ]; then
        grep -q '^pull -C$' "$fake_guix_log" || {
            printf 'guix pull was not reached in %s mode\n' "$mode" >&2
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
        return 1
    fi
}

assert_preserved_after_failure system-failure
assert_preserved_after_failure pull-failure

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
    "$repo_root/scripts/build-substitute-cache.sh" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
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
        "$repo_root/scripts/build-substitute-cache.sh" \
            --output "$output" \
            --public-key "$public_key" \
            --private-key "$private_key" \
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
    "$repo_root/scripts/build-substitute-cache.sh" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
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
    "$repo_root/scripts/build-substitute-cache.sh" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        --variant normal >"$success_log" 2>&1 || {
    sed 's/^/successful publication: /' "$success_log" >&2
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
[ -s "$output/nix-cache-info" ] && [ -s "$output/system.narinfo" ] &&
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
    "$repo_root/scripts/build-substitute-cache.sh" \
        --output "$output" \
        --public-key "$public_key" \
        --private-key "$private_key" \
        --variant normal \
        --bake-timeout 10 >"$delayed_log" 2>&1 || {
    sed 's/^/delayed bake: /' "$delayed_log" >&2
    exit 1
}
[ "$(< "$fake_narinfo_attempts")" -eq 2 ] || {
    printf 'delayed bake did not retry exactly once\n' >&2
    exit 1
}
[ -s "$output/system.narinfo" ] &&
        [ "$(< "$output/nar/fake.nar.zst")" = data ] || {
    printf 'delayed bake publication is incomplete\n' >&2
    exit 1
}

printf '%s\n' 'substitute-cache publication safety check passed'
