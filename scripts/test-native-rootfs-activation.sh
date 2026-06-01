#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="$repo_root/root.img"
work_dir=""
test_image=""
mount_dir=""
PATH="/usr/sbin:/sbin:$PATH"
export PATH

usage() {
    cat <<'EOF'
Usage: test-native-rootfs-activation.sh [options]

Run the Guix activation script inside a disposable writable copy of a native
Qubes root image and verify runtime-only compatibility paths.  This catches
issues that are invisible in the immutable system profile, such as generated
/etc content hiding Qubes PAM service files.

Options:
  --image FILE  Root image to test. Default: root.img
  -h, --help    Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_arg() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --image)
                require_arg "$@"
                image="$2"
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
    if [ "$(id -u)" -ne 0 ]; then
        need sudo
    fi
    need chroot
    need cp
    need mount

    [ -r "$image" ] || die "missing readable image: $image"
}

cleanup() {
    if [ -n "$mount_dir" ]; then
        as_root umount -R "$mount_dir" 2>/dev/null || true
    fi
    if [ -n "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

prepare_writable_root() {
    work_dir="$(mktemp -d "$repo_root/activation.XXXXXX")"
    test_image="$work_dir/root.img"
    mount_dir="$work_dir/mnt"

    mkdir -p "$mount_dir"
    cp --reflink=auto --sparse=always "$image" "$test_image"
    as_root mount -o loop,rw "$test_image" "$mount_dir"
    as_root mkdir -p "$mount_dir/proc" "$mount_dir/dev" "$mount_dir/sys" \
        "$mount_dir/run" "$mount_dir/tmp"
    as_root mount -t proc proc "$mount_dir/proc"
    as_root mount --rbind /dev "$mount_dir/dev"
    as_root mount --make-rslave "$mount_dir/dev"
    as_root mount --rbind /sys "$mount_dir/sys"
    as_root mount --make-rslave "$mount_dir/sys"
}

run_activation() {
    as_root chroot "$mount_dir" /bin/sh -lc \
        'GUIX_NEW_SYSTEM=/var/guix/profiles/system /var/guix/profiles/system/activate'
}

run_activation_twice() {
    run_activation
    # Activation must be idempotent because AppVM starts and reconfigure runs can
    # revisit the same mutable paths.
    run_activation
}

verify_activation_paths() {
    as_root chroot "$mount_dir" /bin/sh -lc '
    set -eu
    test -d /rw
    test -d /usr/local
    test -L /etc/ssl
    test -s /etc/ssl/certs/ca-certificates.crt
    test -r /etc/qubes-guix-channel/.guix-channel
    test -r /etc/qubes-guix-channel/modules/qubes/packages.scm
    test -r /etc/qubes-guix-channel/modules/qubes/files/qvm-template-repo-query-guix.py
    test -d /etc/qubes-guix-channel/modules/qubes/patches
    test -f /etc/fstab
    test ! -L /etc/fstab
    printf "\n# qubes-guix activation fstab write check\n" >> /etc/fstab
    test -L /usr/lib/qubes
    test -L /usr/lib/qubes-bind-dirs.d
    test -d /etc/qubes-rpc
    test ! -L /etc/qubes-rpc
    printf "#!/bin/sh\nexit 0\n" > /etc/qubes-rpc/test.GuixWritable
    chmod 755 /etc/qubes-rpc/test.GuixWritable
    test -x /etc/qubes-rpc/test.GuixWritable
    test -d /etc/qubes/post-install.d
    test ! -L /etc/qubes/post-install.d
    printf "#!/bin/sh\nexit 0\n" > /etc/qubes/post-install.d/50-test.sh
    chmod 755 /etc/qubes/post-install.d/50-test.sh
    test -x /etc/qubes/post-install.d/50-test.sh
    test -d /etc/pam.d
    test -f /etc/pam.d/qrexec
    test -f /etc/pam.d/qubes-gui-agent
    test -f /etc/qubes/rpc-config/qubes.PostInstall
    grep -q "force-user[[:space:]]*=[[:space:]]*'\''root'\''" /etc/qubes/rpc-config/qubes.PostInstall
    test -x /etc/qubes-rpc/qubes.PostInstall
    test -x /etc/qubes-rpc/qubes.VMShell
    test -x /etc/qubes-rpc/qubes.VMRootShell
    /bin/sh -c true
    /bin/bash -lc true
    test -r /etc/os-release
    grep -qx "ID=guix" /etc/os-release
    grep -qx "PRETTY_NAME=\"Guix System\"" /etc/os-release
'
}

verify_pam_services() {
    local libpam_path

    libpam_path="$(
        as_root chroot "$mount_dir" /bin/sh -lc \
            'find /gnu/store -path "*/lib/libpam.so.0" -print -quit'
    )"
    [ -n "$libpam_path" ] || die "missing libpam.so.0 in guest image"

    as_root chroot "$mount_dir" /bin/python3 - "$libpam_path" <<'PY'
import ctypes
import sys


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


Conversation = ctypes.CFUNCTYPE(
    ctypes.c_int,  # return code
    ctypes.c_int,  # message count
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)

libc = ctypes.CDLL("libc.so.6")
libpam = ctypes.CDLL(sys.argv[1])
libpam.pam_strerror.restype = ctypes.c_char_p


@Conversation
def converse(count, _messages, responses, _data):
    array = (PamResponse * count)()
    for index in range(count):
        array[index].resp = ctypes.cast(libc.strdup(b""), ctypes.c_char_p)
        array[index].resp_retcode = 0
    responses[0] = ctypes.cast(array, ctypes.POINTER(PamResponse))
    return 0


class PamConv(ctypes.Structure):
    _fields_ = [("conv", Conversation), ("appdata_ptr", ctypes.c_void_p)]


def check(call, handle, code):
    if code != 0:
        message = libpam.pam_strerror(handle, code).decode(errors="replace")
        raise SystemExit(f"{call} failed: {message} ({code})")


for service in (b"qrexec", b"qubes-gui-agent"):
    for user in (b"root", b"user"):
        handle = ctypes.c_void_p()
        conv = PamConv(converse, None)
        check(
            "pam_start",
            handle,
            libpam.pam_start(service, user, ctypes.byref(conv), ctypes.byref(handle)),
        )
        status = 0
        try:
            for name, function, flags in (
                ("pam_authenticate", libpam.pam_authenticate, 0),
                ("pam_setcred", libpam.pam_setcred, 2),
                ("pam_open_session", libpam.pam_open_session, 0),
            ):
                status = function(handle, flags)
                check(name, handle, status)
        finally:
            libpam.pam_end(handle, status)
PY
}

verify_qrexec_shell_wrapper() {
    as_root chroot "$mount_dir" /bin/python3 - <<'PY'
import os
import pwd
import select
import sys


QREXEC_SHELL_WRAPPER = """set -e
unset QREXEC_SERVICE_FULL_NAME QREXEC_REMOTE_DOMAIN QREXEC_REQUESTED_TARGET_TYPE QREXEC_SERVICE_ARGUMENT QREXEC_REQUESTED_TARGET QREXEC_REQUESTED_TARGET_KEYWORD
export "QREXEC_SERVICE_FULL_NAME=$2" "QREXEC_REMOTE_DOMAIN=$3" QREXEC_REQUESTED_TARGET_TYPE=
exec "$1"
"""


def close_all(*fds):
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


def read_fd(fd):
    chunks = []
    while True:
        ready, _, _ = select.select([fd], [], [], 10)
        if not ready:
            raise SystemExit("timed out reading qrexec shell wrapper output")
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def run_vmshell_as(user):
    account = pwd.getpwnam(user)
    stdin_read, stdin_write = os.pipe()
    stdout_read, stdout_write = os.pipe()
    stderr_read, stderr_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.dup2(stdin_read, 0)
            os.dup2(stdout_write, 1)
            os.dup2(stderr_write, 2)
            close_all(stdin_read, stdin_write, stdout_read, stdout_write,
                      stderr_read, stderr_write)
            os.initgroups(account.pw_name, account.pw_gid)
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
            try:
                os.chdir(account.pw_dir)
            except OSError:
                pass
            env = {
                "HOME": account.pw_dir,
                "SHELL": account.pw_shell,
                "USER": account.pw_name,
                "LOGNAME": account.pw_name,
                "PATH": "/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            }
            os.execve(
                "/bin/sh",
                [
                    "/bin/sh",
                    "-lc",
                    QREXEC_SHELL_WRAPPER,
                    "sh",
                    "/etc/qubes-rpc/qubes.VMShell",
                    "qubes.VMShell+",
                    "dom0",
                    "",
                ],
                env,
            )
        except BaseException as error:
            print(f"child setup failed for {user}: {error}", file=sys.stderr)
            os._exit(125)

    close_all(stdin_read, stdout_write, stderr_write)
    os.write(stdin_write, f"printf 'qrexec-vmshell-ok-{user}\\n'; exit\n".encode())
    os.close(stdin_write)
    stdout = read_fd(stdout_read)
    stderr = read_fd(stderr_read)
    close_all(stdout_read, stderr_read)
    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        raise SystemExit(f"{user} qrexec shell wrapper died on signal {os.WTERMSIG(status)}: {stderr!r}")
    exit_code = os.WEXITSTATUS(status)
    expected = f"qrexec-vmshell-ok-{user}\n".encode()
    if exit_code != 0 or expected not in stdout:
        raise SystemExit(
            f"{user} qrexec shell wrapper failed: exit={exit_code} stdout={stdout!r} stderr={stderr!r}"
        )


for name in ("root", "user"):
    run_vmshell_as(name)
PY
}

verify_home_initialization() {
    as_root chroot "$mount_dir" /bin/sh -lc '
    set -eu
    rm -rf /rw/home
    . /usr/lib/qubes/init/functions
    initialize_home /rw/home ifneeded
    test -d /rw/home/user
    test ! -L /rw/home/user/.config
    test ! -L /rw/home/user/.cache
    if [ -e /var/guix/profiles/per-user/user ]; then
        test "$(stat -c %d /var/guix/profiles/per-user/user)" != "$(stat -c %d /rw)"
    fi
'

    as_root chroot --userspec=user:users "$mount_dir" /bin/sh -lc '
    set -eu
    export HOME=/rw/home/user
    test -w "$HOME"
    mkdir -p "$HOME/.config/guix" "$HOME/.cache/guix"
'
}

main() {
    parse_args "$@"
    check_requirements
    prepare_writable_root
    run_activation_twice
    verify_activation_paths
    verify_pam_services
    verify_qrexec_shell_wrapper
    verify_home_initialization
    printf 'native root image activation check passed: %s\n' "$image"
}

main "$@"
