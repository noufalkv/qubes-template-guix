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
case " $* " in
    *' --write-out '*)
        printf '404'
        exit 0
        ;;
esac

output_file=""
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    if [ "${arguments[index]}" = --output ]; then
        output_file="${arguments[index + 1]:?}"
    fi
done
request_url="${arguments[${#arguments[@]} - 1]}"

case "$request_url" in
    */nix-cache-info)
        if [ -n "$output_file" ] && [ "$output_file" != /dev/null ]; then
            printf '%s\n' 'StoreDir: /gnu/store' > "$output_file"
        fi
        ;;
    *.narinfo)
        [ -n "$output_file" ]
        {
            printf 'StorePath: %s\n' "${FAKE_STORE_PATH:?}"
            printf '%s\n' 'URL: nar/fake.nar.zst' 'FileSize: 4'
        } > "$output_file"
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

printf '%s\n' 'substitute-cache publication safety check passed'
