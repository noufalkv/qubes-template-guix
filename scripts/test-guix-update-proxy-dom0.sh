#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat <<'__QUBES_GUIX_USAGE__'
Usage: test-guix-update-proxy-dom0.sh [options]

Verify a Guix TemplateVM's Qubes updates-proxy wiring.  By default this checks
the service flag, forwarder, and daemon-backed Guix path.  With --download, it
also runs a real guix download through the Qubes updates proxy.  With --pull,
it runs guix pull through the official Guix channel into a temporary profile.

Options:
  -t, --template NAME       TemplateVM name. Default: guix.
      --download            Also fetch --download-url through the proxy.
      --pull                Also run guix pull through the official channel.
      --pull-commit COMMIT  Optional full 40-hex commit for the temporary pull profile.
      --pull-timeout SEC    Timeout for guix pull. Default: 3600.
  -u, --download-url URL    URL for the proxy probe and optional download.
                            Default: https://guix.gnu.org/
      --timeout SECONDS     Guest-side timeout for proxy probes/download.
                            Default: 240.
  -h, --help                Show this help.
__QUBES_GUIX_USAGE__
}

die() {
    printf 'test-guix-update-proxy failed: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_guest_script() {
    script=$1
    path=$2
    shift 2

    command=$(cat <<EOF
cat >$(quote "$path") <<'__QUBES_GUIX_TEST__'
$script
__QUBES_GUIX_TEST__
chmod 0700 $(quote "$path")
$(quote "$path")
EOF
)
    for arg in "$@"; do
        command="$command $(quote "$arg")"
    done

    qvm-run --pass-io --no-gui --user root "$template_name" "$command"
}

check_requirements() {
    need qvm-run
    need qvm-check
    need qvm-start
    need timeout
}

wait_for_qrexec() {
    vm=$1
    attempt=1

    while [ "$attempt" -le 90 ]; do
        if timeout 10 qvm-run --pass-io --no-gui --user root "$vm" ':' \
            >/dev/null 2>&1; then
            return 0
        fi
        printf 'waiting for qrexec in %s (%s/90)\n' "$vm" "$attempt" >&2
        attempt=$((attempt + 1))
        sleep 2
    done

    return 1
}

ensure_template_ready() {
    qvm-check "$template_name" >/dev/null 2>&1 ||
        die "template does not exist: $template_name"

    if ! qvm-check --running "$template_name" >/dev/null 2>&1; then
        qvm-start "$template_name" >/dev/null
    fi

    wait_for_qrexec "$template_name" ||
        die "qrexec did not become ready in template: $template_name"
}

positive_int() {
    name=$1
    value=$2

    case "$value" in
        ''|*[!0-9]*)
            die "$name must be a positive integer"
            ;;
    esac
    [ "$value" -gt 0 ] || die "$name must be greater than zero"
}

validate_git_commit() {
    name=$1
    value=$2

    case "$value" in
        ''|*[!0-9a-fA-F]*)
            die "$name must be a full 40-hex Git commit"
            ;;
    esac
    [ "${#value}" -eq 40 ] ||
        die "$name must be a full 40-hex Git commit"
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
preflight_script=$script_dir/guest-update-proxy-preflight.sh
template_name=guix
target_url=${GUIX_PROXY_DOWNLOAD_URL:-https://guix.gnu.org/}
proxy_timeout=${GUIX_PROXY_DOWNLOAD_TIMEOUT:-240}
run_download=0
run_pull=0
pull_commit=${GUIX_PROXY_PULL_COMMIT:-}
pull_timeout=${GUIX_PROXY_PULL_TIMEOUT:-3600}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -t|--template)
                require_arg "$@"
                template_name=$2
                shift 2
                ;;
            --download)
                run_download=1
                shift
                ;;
            --pull)
                run_pull=1
                shift
                ;;
            --pull-commit)
                require_arg "$@"
                pull_commit=$2
                shift 2
                ;;
            --pull-timeout)
                require_arg "$@"
                pull_timeout=$2
                shift 2
                ;;
            -u|--download-url)
                require_arg "$@"
                target_url=$2
                shift 2
                ;;
            --timeout)
                require_arg "$@"
                proxy_timeout=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

validate_options() {
    positive_int "--timeout" "$proxy_timeout"
    if [ "$run_pull" -eq 1 ]; then
        positive_int "--pull-timeout" "$pull_timeout"
        if [ -n "$pull_commit" ]; then
            validate_git_commit "--pull-commit" "$pull_commit"
        fi
    fi
}

guest_config_check() {
    cat <<'__QUBES_GUIX_GUEST__'
set -eu

guix=/run/current-system/profile/bin/guix

find_guix_daemon_pid() {
    if command -v pidof >/dev/null 2>&1; then
        set -- $(pidof guix-daemon 2>/dev/null || true)
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$1"
            return 0
        fi
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f '[g]uix-daemon' 2>/dev/null | head -n 1 || true
    fi
}

diagnose_proxy_config() {
    echo '== guix-daemon service status =='
    herd status guix-daemon 2>&1 || true
    echo '== guix-daemon processes =='
    ps -ef | grep '[g]uix-daemon' 2>&1 || true
    pid=$(find_guix_daemon_pid || true)
    if [ -n "$pid" ]; then
        echo "== guix-daemon environment pid=$pid =="
        tr '\0' '\n' <"/proc/$pid/environ" |
            grep -E '^(http|https|all|no)_proxy=|^(HTTP|HTTPS|ALL|NO)_PROXY=' || true
    fi
    echo '== guix version stderr =='
    cat /tmp/qubes-guix-version.err 2>/dev/null || true
    echo '== guix gc stderr =='
    cat /tmp/qubes-guix-gc-roots.err 2>/dev/null || true
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "guix update proxy config check failed with status $rc"; diagnose_proxy_config; fi; exit "$rc"' EXIT

echo 'checking Guix client command'
/run/current-system/profile/bin/env \
    -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
    "$guix" --version \
    >/tmp/qubes-guix-version.out \
    2>/tmp/qubes-guix-version.err

echo 'starting guix-daemon through direct guix command'
if ! "$guix" gc --list-roots >/tmp/qubes-guix-gc-roots.out \
    2>/tmp/qubes-guix-gc-roots.err; then
    echo 'guix gc --list-roots failed'
    cat /tmp/qubes-guix-gc-roots.err 2>/dev/null || true
    exit 1
fi

echo 'checking guix-daemon service state'
herd status guix-daemon >/tmp/qubes-guix-daemon.status
cat /tmp/qubes-guix-daemon.status
grep -F 'It is running' /tmp/qubes-guix-daemon.status >/dev/null

pid=$(find_guix_daemon_pid || true)
if [ -n "$pid" ]; then
    echo "observed guix-daemon environment pid=$pid"
    tr '\0' '\n' <"/proc/$pid/environ" \
        >/tmp/qubes-guix-daemon.environ
    grep -E '^(http|https|all|no)_proxy=|^(HTTP|HTTPS|ALL|NO)_PROXY=' \
        /tmp/qubes-guix-daemon.environ || true
    if grep -E '^(http|https|all)_proxy=|^(HTTP|HTTPS|ALL)_PROXY=' \
        /tmp/qubes-guix-daemon.environ >/dev/null; then
        echo 'guix-daemon must not inherit Qubes updates-proxy environment' >&2
        exit 1
    fi
    if ps -ef | grep '[g]uix-daemon' | grep -F '127.0.0.1:8082' >/dev/null; then
        echo 'guix-daemon command line must not force the local updates proxy' >&2
        exit 1
    fi
else
    echo 'guix-daemon has no persistent process after command; socket-activated service is idle'
    grep -F 'Systemd-style service listening on' /tmp/qubes-guix-daemon.status >/dev/null
    grep -F '/var/guix/daemon-socket/socket' /tmp/qubes-guix-daemon.status >/dev/null
fi

printf 'guix update proxy config check passed\n'
__QUBES_GUIX_GUEST__
}

guest_download_check() {
    cat <<'__QUBES_GUIX_GUEST__'
set -eu

target_url=$1
proxy_timeout=$2
payload=/tmp/qubes-guix-proxy-download.payload
stdout=/tmp/qubes-guix-proxy-download.out
stderr=/tmp/qubes-guix-proxy-download.err
proxy=http://127.0.0.1:8082/
guix=/run/current-system/profile/bin/guix

diagnose_proxy_download() {
    echo '== qubes service flags =='
    ls -la /run/qubes-service /var/run/qubes-service 2>&1 || true
    echo '== shepherd status =='
    herd status qubes-updates-proxy-forwarder 2>&1 || true
    herd status guix-daemon 2>&1 || true
    echo '== download stdout =='
    cat "$stdout" 2>/dev/null || true
    echo '== download stderr =='
    cat "$stderr" 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null || true
    if grep -Fq 'Request refused' /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null; then
        echo '== likely dom0 updates-proxy policy refusal =='
        echo 'The guest forwarder reached qrexec-client-vm, but dom0 refused qubes.UpdatesProxy.'
        echo 'Check that the standard Qubes qubes.UpdatesProxy policy is present'
        echo 'and that its default target, normally sys-net, exists and can'
        echo 'provide the updates proxy.'
    fi
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "guix update proxy download check failed with status $rc"; diagnose_proxy_download; fi; exit "$rc"' EXIT

rm -f "$payload" "$stdout" "$stderr"
echo "running guix download through Qubes updates proxy: $target_url"
if ! timeout "$proxy_timeout" /run/current-system/profile/bin/env \
    http_proxy="$proxy" https_proxy="$proxy" \
    HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" \
    all_proxy="$proxy" ALL_PROXY="$proxy" \
    no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
    "$guix" download \
    --output="$payload" "$target_url" >"$stdout" 2>"$stderr"; then
    cat "$stderr" 2>/dev/null || true
    exit 1
fi

test -s "$payload"
bytes=$(wc -c <"$payload" | tr -d ' ')
echo "downloaded $bytes bytes"
cat "$stdout"
printf 'guix update proxy download check passed\n'
__QUBES_GUIX_GUEST__
}

guest_pull_check() {
    cat <<'__QUBES_GUIX_GUEST__'
set -eu

pull_commit=$1
pull_timeout=$2
workdir=/tmp/qubes-guix-proxy-pull
channel_file=$workdir/channels.scm
profile=$workdir/current
stdout=$workdir/pull.out
stderr=$workdir/pull.err
proxy=http://127.0.0.1:8082/
guix=/run/current-system/profile/bin/guix

diagnose_proxy_pull() {
    echo '== qubes service flags =='
    ls -la /run/qubes-service /var/run/qubes-service 2>&1 || true
    echo '== shepherd status =='
    herd status qubes-updates-proxy-forwarder 2>&1 || true
    herd status guix-daemon 2>&1 || true
    echo '== pull stdout =='
    cat "$stdout" 2>/dev/null || true
    echo '== pull stderr =='
    cat "$stderr" 2>/dev/null || true
    echo '== proxy service logs =='
    cat /var/log/qubes-updates-proxy-forwarder.log 2>/dev/null || true
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "guix update proxy pull check failed with status $rc"; diagnose_proxy_pull; fi; exit "$rc"' EXIT

rm -rf "$workdir"
mkdir -p "$workdir/home" "$workdir/cache" "$workdir/config"

{
    cat <<'EOF'
(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
EOF
    if [ -n "$pull_commit" ]; then
        printf '       (commit "%s")\n' "$pull_commit"
    fi
    cat <<'EOF'
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
EOF
} >"$channel_file"

echo 'running guix pull through Qubes updates proxy'
timeout "$pull_timeout" /run/current-system/profile/bin/env \
    HOME="$workdir/home" \
    XDG_CACHE_HOME="$workdir/cache" \
    XDG_CONFIG_HOME="$workdir/config" \
    http_proxy="$proxy" https_proxy="$proxy" \
    HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" \
    all_proxy="$proxy" ALL_PROXY="$proxy" \
    no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
    "$guix" pull \
    -p "$profile" \
    --allow-downgrades \
    -C "$channel_file" \
    >"$stdout" 2>"$stderr"

test -x "$profile/bin/guix"
"$profile/bin/guix" --version
printf 'guix update proxy pull check passed\n'
__QUBES_GUIX_GUEST__
}

check_preflight_helper() {
    [ -r "$preflight_script" ] ||
        die "missing guest preflight helper: $preflight_script"
}

run_preflight_check() {
    run_guest_script \
        "$(cat "$preflight_script")" \
        /tmp/qubes-guix-update-proxy-preflight.sh \
        "$target_url" \
        "$proxy_timeout"
}

run_config_check() {
    run_guest_script \
        "$(guest_config_check)" \
        /tmp/qubes-guix-update-proxy-config-test.sh
}

run_download_check() {
    [ "$run_download" -eq 1 ] || return 0

    run_guest_script \
        "$(guest_download_check)" \
        /tmp/qubes-guix-update-proxy-download-test.sh \
        "$target_url" \
        "$proxy_timeout"
}

run_pull_check() {
    [ "$run_pull" -eq 1 ] || return 0

    run_guest_script \
        "$(guest_pull_check)" \
        /tmp/qubes-guix-update-proxy-pull-test.sh \
        "$pull_commit" \
        "$pull_timeout"
}

main() {
    parse_args "$@"
    validate_options
    check_requirements
    check_preflight_helper
    ensure_template_ready
    run_preflight_check
    run_config_check
    run_download_check
    run_pull_check
}

main "$@"
