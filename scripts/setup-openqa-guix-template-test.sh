#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
PATH="/usr/sbin:/sbin:$PATH"
export PATH

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tests_source="$repo_root/.cache/openqa-tests-qubesos"
tests_dest="/var/lib/openqa/share/tests/qubesos"
factory_hdd="/var/lib/openqa/share/factory/hdd"
worker_cache_hdd="/var/lib/openqa/cache/localhost"
nose2_rpm="${QUBES_OPENQA_NOSE2_RPM:-$repo_root/.cache/python3-nose2-0.15.1-3.fc41.noarch.rpm}"
nose2_rpm_url="${QUBES_OPENQA_NOSE2_RPM_URL:-https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/41/Everything/x86_64/os/Packages/p/python3-nose2-0.15.1-3.fc41.noarch.rpm}"
qubes_version="${QUBES_VERSION:-4.3.0}"
nested_workdir="${QUBES_NESTED_WORKDIR:-$HOME/qubes-nested}"
qubes_disk="${QUBES_OPENQA_QUBES_DISK:-$nested_workdir/vm/qubes-r${qubes_version}.qcow2}"
guix_root_image="${QUBES_OPENQA_GUIX_ROOT_IMAGE:-$repo_root/root.img}"
guix_template_rpm="${QUBES_OPENQA_GUIX_TEMPLATE_RPM:-}"
update_target_template_rpm="${QUBES_OPENQA_UPDATE_TARGET_TEMPLATE_RPM:-}"
qubes_asset_name="${QUBES_OPENQA_QUBES_ASSET:-qubes-r${qubes_version}.qcow2}"
guix_asset_name="${QUBES_OPENQA_GUIX_ASSET:-guix-root.img}"
guix_rpm_asset_name="${QUBES_OPENQA_GUIX_RPM_ASSET:-guix-template-rpm.img}"
openqa_url="${QUBES_OPENQA_URL:-http://localhost:9526}"
build="${QUBES_OPENQA_BUILD:-guix-$(date -u +%Y%m%d%H%M%S)}"
template_name="${QUBES_OPENQA_TEMPLATE_NAME:-}"
appvm_name="${QUBES_OPENQA_APPVM_NAME:-guix-openqa-test-app}"
appvm_netvm="${QUBES_OPENQA_APPVM_NETVM:-${QUBES_GUIX_APPVM_NETVM:-}}"
dom0_password="${QUBES_NESTED_DOM0_PASSWORD:-qubes}"
dom0_console="${QUBES_OPENQA_DOM0_CONSOLE:-root-console}"
dom0_type_max_interval="${QUBES_OPENQA_DOM0_TYPE_MAX_INTERVAL:-100}"
dom0_ready_type_max_interval="${QUBES_OPENQA_DOM0_READY_TYPE_MAX_INTERVAL:-${QUBES_DOM0_READY_TYPE_MAX_INTERVAL:-$dom0_type_max_interval}}"
dom0_serial_settle_delay="${QUBES_OPENQA_DOM0_SERIAL_SETTLE_DELAY:-${QUBES_DOM0_SERIAL_SETTLE_DELAY:-3}}"
qemu_ram="${QUBES_OPENQA_RAM:-32768}"
qemu_cpus="${QUBES_OPENQA_CPUS:-8}"
qemu_append="${QUBES_OPENQA_QEMU_APPEND:-}"
max_job_time="${QUBES_OPENQA_MAX_JOB_TIME:-}"
install_mode="${GUIX_INSTALL_MODE:-}"
run_qubes_system_tests="${GUIX_RUN_QUBES_SYSTEM_TESTS:-0}"
qubes_system_tests="${GUIX_QUBES_SYSTEM_TESTS:-qubes.tests.integ.qrexec:14400 qubes.tests.integ.vm_qrexec_gui:14400}"
run_proxy_download_test="${GUIX_RUN_PROXY_DOWNLOAD_TEST:-0}"
run_proxy_stub_download_test="${GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST:-0}"
run_central_vmupdate_test="${GUIX_RUN_CENTRAL_VMUPDATE_TEST:-0}"
bootstrap_update_target="${GUIX_BOOTSTRAP_UPDATE_TARGET:-0}"
update_target_name="${QUBES_OPENQA_UPDATE_TARGET_NAME:-sys-net}"
update_target_network_mode="${QUBES_OPENQA_UPDATE_TARGET_NETWORK_MODE:-nat}"
guix_proxy_download_url="${GUIX_PROXY_DOWNLOAD_URL:-https://guix.gnu.org/}"
guix_proxy_stub_download_url="${GUIX_PROXY_STUB_DOWNLOAD_URL:-http://qubes-guix-test/}"
guix_proxy_download_timeout="${GUIX_PROXY_DOWNLOAD_TIMEOUT:-240}"
guix_central_vmupdate_timeout="${GUIX_CENTRAL_VMUPDATE_TIMEOUT:-3600}"
guix_central_vmupdate_proxy_probe_url="${GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL:-https://git.savannah.gnu.org/git/guix.git}"
guix_vmupdate_qrexec_timeout="${GUIX_VMUPDATE_QREXEC_TIMEOUT:-600}"
guix_vmupdate_service_vm_timeout="${GUIX_VMUPDATE_SERVICE_VM_TIMEOUT:-300}"
core_admin_linux_tree="${GUIX_CORE_ADMIN_LINUX_TREE:-}"
guix_expect_commands="${GUIX_EXPECT_COMMANDS:-}"
guix_expect_desktops="${GUIX_EXPECT_DESKTOPS:-}"
if [ -n "${GUIX_TEST_TIMEOUT:-}" ]; then
    guix_test_timeout="$GUIX_TEST_TIMEOUT"
elif [ "$run_qubes_system_tests" = "1" ]; then
    guix_test_timeout=21600
else
    guix_test_timeout=5400
fi
schedule_job=1
wait_job=0
rpm_asset_image=""
rpm_staging=""
core_admin_vmupdate_archive=""

usage() {
    cat <<'EOF'
Usage: setup-openqa-guix-template-test.sh [options]

Prepare an openQA host to test the native Guix System TemplateVM in a nested
Qubes dom0 VM, then schedule the job by default.

Options:
  --tests-source DIR       Qubes openQA test checkout. Default: .cache/openqa-tests-qubesos
  --qubes-disk FILE        Installed nested Qubes dom0 qcow2.
  --guix-root-image FILE   Native Guix root image. Default: ./root.img
  --template-rpm FILE      qvm-template RPM to install and test.
  --no-schedule            Only install tests/assets/openQA config.
  --wait                   Wait until the scheduled openQA job finishes.
  -h, --help               Show this help.
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

ensure_nose2_rpm() {
    local tmp

    [ "$run_qubes_system_tests" = "1" ] || return 0
    if [ -r "$nose2_rpm" ]; then
        return
    fi

    need curl
    mkdir -p "$(dirname "$nose2_rpm")"
    tmp="$nose2_rpm.tmp.$$"
    rm -f "$tmp"
    curl -fL "$nose2_rpm_url" -o "$tmp"
    mv "$tmp" "$nose2_rpm"
}

apply_openqa_guix_patches() {
    local installedtest="$tests_dest/lib/installedtest.pm"
    local update2="$tests_dest/tests/update2.pm"
    local switch_template="$tests_dest/tests/switch_template.pm"
    local zsystemtests="$tests_dest/extra-files/update/zsystemtests.py"

    # Keep reviewable diffs in openqa/qubesos/patches/:
    # startup-recover-sys-net-before-gui.patch,
    # installedtest-bounded-log-uploads.patch,
    # update2-guix-sequential-vmupdate.patch,
    # switch-template-running-dispvms.patch and
    # zsystemtests-guix-no-package-install.patch. Apply them with Perl/Python
    # because minimal openQA hosts may not have patch(1).
    sudo perl -0pi -e "$(cat <<'PERL'
my $helper = q%sub recover_sys_net {
    my ($self) = @_;

    return if script_run('qvm-check --running sys-net') == 0;
    if (script_run("qvm-start sys-net", timeout => 180) != 0) {
        assert_script_run(q!net_bdf="$(for dev in /sys/bus/pci/devices/*; do class="$(cat "$dev/class" 2>/dev/null || true)"; case "$class" in 0x02*) basename "$dev"; break;; esac; done)"; test -n "$net_bdf"; net_id="${net_bdf#*:}"; net_id="${net_id/:/_}"; net_dev="dom0:$net_id"; echo "Using $net_dev for sys-net"; qvm-pci dt sys-net "$net_dev" >/dev/null 2>&1 || true; qvm-pci at sys-net "$net_dev" -p -o no-strict-reset=True!, timeout => 120);
        assert_script_run("qvm-start sys-net", timeout => 180);
    }
    # don't fail if whonix is not installed
    script_run("qvm-start sys-whonix", timeout => 90);
}

sub nested_network_stack_ready {
    my ($self) = @_;

    return 0 unless check_var('GUIX_ACCEPT_RUNNING_SERVICE_NET', '1');
    select_root_console();
    my $ready = script_run('qvm-check --running sys-net') == 0
        && script_run('qvm-check --running sys-firewall') == 0;
    select_console(get_var('GUI_CONSOLE', 'x11'), await_console => 0);
    return $ready;
}

%;
s/\n\nsub handle_system_startup \{/\n\n$helper\nsub handle_system_startup {/ or die "failed to apply installedtest startup sys-net recovery helper patch\n";

my $old_before_gui = q%    assert_screen ["login-prompt-user-selected"], 600;

    $self->init_gui_session;
%;
my $new_before_gui = q%    assert_screen ["login-prompt-user-selected"], 600;

    select_root_console();
    $self->recover_sys_net;
    select_console(get_var('GUI_CONSOLE', 'x11'), await_console => 0);

    $self->init_gui_session;
%;
s/\Q$old_before_gui\E/$new_before_gui/ or die "failed to apply installedtest startup sys-net recovery ordering patch\n";

my $old_recovery = q%    # WTF part
    if (script_run('qvm-check --running sys-net') != 0) {
        assert_script_run('qvm-pci dt sys-net dom0:00_04.0');
        assert_script_run('qvm-pci at sys-net dom0:00_04.0 -p -o no-strict-reset=True');
        assert_script_run('qvm-start sys-net');
        # don't fail if whonix is not installed
        script_run('qvm-start sys-whonix', timeout => 90);
    }
%;
my $new_recovery = q%    # WTF part
    if (script_run('qvm-check --running sys-net') != 0) {
        $self->recover_sys_net;
    }
%;
s/\Q$old_recovery\E/$new_recovery/ or die "failed to apply installedtest startup sys-net recovery patch\n";

my $old_nm = q%    if (check_var("CONNECT_WIFI", "1")) {
        $self->connect_wifi;
    } else {
        assert_screen(["nm-connection-established", "nm-applet-connected"], 150);
    }
%;
my $new_nm = q%    if (check_var("CONNECT_WIFI", "1")) {
        $self->connect_wifi;
    } else {
        if (!check_screen(["nm-connection-established", "nm-applet-connected"], 150)) {
            die "network stack is running but NetworkManager applet needle is missing" unless $self->nested_network_stack_ready;
        }
    }
%;
s/\Q$old_nm\E/$new_nm/ or die "failed to apply installedtest nested network stack readiness patch\n";
PERL
)" "$installedtest"

    sudo grep -Fq '$self->recover_sys_net;' "$installedtest" ||
        die "installedtest startup sys-net recovery patch did not apply"
    sudo grep -Fq "await_console => 0" "$installedtest" ||
        die "installedtest startup GUI handoff patch did not apply"
    sudo grep -Fq 'net_bdf="$(for dev in /sys/bus/pci/devices/*' "$installedtest" ||
        die "installedtest dynamic sys-net PCI patch did not apply"
    sudo grep -Fq "GUIX_ACCEPT_RUNNING_SERVICE_NET" "$installedtest" ||
        die "installedtest nested network stack readiness patch did not apply"

    sudo perl -0pi -e '
my $old = q%sub save_and_upload_log {
    my ($self, $cmd, $file, $args) = @_;
    script_run("$cmd > $file", timeout=>$args->{timeout});
    my $ret = upload_logs(
        $file,
        timeout=>$args->{timeout},
        failok=>$args->{failok}
    ) unless $args->{noupload};
    save_screenshot if $args->{screenshot};
    return undef if ($args->{failok} and !-e "ulogs/$ret");
    return $ret;
}
%;
my $new = q%sub save_and_upload_log {
    my ($self, $cmd, $file, $args) = @_;
    my $upload_failok = $args->{failok}
        || check_var('\''GUIX_FAILOK_LOG_UPLOADS'\'', '\''1'\'');
    script_run("$cmd > $file", timeout=>$args->{timeout});
    my $ret = upload_logs(
        $file,
        timeout=>$args->{timeout},
        failok=>$upload_failok
    ) unless $args->{noupload};
    save_screenshot if $args->{screenshot};
    return undef if ($upload_failok and !-e "ulogs/$ret");
    return $ret;
}
%;
s/\Q$old\E/$new/ or die "failed to apply installedtest bounded log upload patch\n";
' "$installedtest"

    sudo grep -Fq "GUIX_FAILOK_LOG_UPLOADS" "$installedtest" ||
        die "installedtest bounded log upload patch did not apply"

    sudo perl -0pi -e '
my $old = q%    if (get_var("SALT_SYSTEM_TESTS")) {
        assert_script_run("cp /root/extra-files/update/zsystemtests.py /usr/lib/python3.*/site-packages/vmupdate/agent/source/plugins/");
    }

    assert_script_run("script -c '\''qubes-vm-update --force-update --log DEBUG --max-concurrency=2 $targets --show-output'\'' -a -e qubesctl-upgrade.log", timeout => 14400);
    upload_logs("qubesctl-upgrade.log");
%;
my $new = q%    if (get_var("SALT_SYSTEM_TESTS")) {
        assert_script_run("cp /root/extra-files/update/zsystemtests.py /usr/lib/python3.*/site-packages/vmupdate/agent/source/plugins/");
    }
    assert_script_run("if [ -r /root/extra-files/update/core-admin-guix-vmupdate.tgz ]; then tar -C /usr/lib/python3.*/site-packages/vmupdate/agent -xzf /root/extra-files/update/core-admin-guix-vmupdate.tgz; fi");

    my $vmupdate_status;
    if (get_var('\''GUIX_SEQUENTIAL_VMUPDATE'\'', '\''0'\'') eq '\''1'\'' && $targets =~ /guix/) {
        my @vmupdate_targets = split(/,/, $targets =~ s/^--targets=//r);
        my $qrexec_timeout = get_var('\''GUIX_VMUPDATE_QREXEC_TIMEOUT'\'', '\''600'\'');
        foreach my $target (@vmupdate_targets) {
            if ($target =~ /^guix(?:-minimal)?$/) {
                assert_script_run("qvm-prefs $target qrexec_timeout $qrexec_timeout", timeout => 90);
            }
        }
        foreach my $target (@vmupdate_targets) {
            my $log = "qubesctl-upgrade-$target.log";
            $vmupdate_status = script_run("script -c '\''qubes-vm-update --force-update --log DEBUG --max-concurrency=1 --targets=$target --show-output'\'' -a -e $log", timeout => 14400);
            upload_logs($log, failok => 1);
            die "qubes-vm-update failed for $target with status $vmupdate_status" if $vmupdate_status != 0;
            if ($target =~ /^guix(?:-minimal)?$/) {
                assert_script_run("qvm-shutdown --wait $target >/dev/null 2>&1 || qvm-kill $target >/dev/null 2>&1 || true", timeout => 900);
            }
        }
    } else {
        $vmupdate_status = script_run("script -c '\''qubes-vm-update --force-update --log DEBUG --max-concurrency=2 $targets --show-output'\'' -a -e qubesctl-upgrade.log", timeout => 14400);
        upload_logs("qubesctl-upgrade.log", failok => 1);
        die "qubes-vm-update failed with status $vmupdate_status" if $vmupdate_status != 0;
    }
%;
s/\Q$old\E/$new/ or die "failed to apply update2 Guix sequential vmupdate patch\n";
' "$update2"

    sudo perl -0pi -e '
my $old = q%    if (!get_var("DISTUPGRADE_TEMPLATES")) {
        $self->upload_packages_versions;
    }
%;
my $new = q%    if (!get_var("DISTUPGRADE_TEMPLATES")) {
        if (get_var('\''GUIX_SEQUENTIAL_VMUPDATE'\'', '\''0'\'') eq '\''1'\'' && $targets =~ /guix/) {
            my @package_inventory_templates = split(/,/, $targets =~ s/^--targets=//r);
            $self->upload_packages_versions(templates => \@package_inventory_templates);
        } else {
            $self->upload_packages_versions;
        }
    }
%;
s/\Q$old\E/$new/ or die "failed to apply update2 Guix package inventory patch\n";
' "$update2"

    sudo perl -0pi -e '
my $old = q%        assert_script_run('\''qvm-start sys-firewall'\'', timeout => 90);
        assert_script_run('\''if qvm-check sys-whonix; then qvm-start sys-whonix; fi'\'', timeout => 90);
%;
my $new = q%        if (get_var('\''GUIX_SEQUENTIAL_VMUPDATE'\'', '\''0'\'') eq '\''1'\'' && $targets =~ /guix/) {
            my $service_vm_timeout = get_var('\''GUIX_VMUPDATE_SERVICE_VM_TIMEOUT'\'', '\''300'\'');
            assert_script_run('\''qvm-start sys-firewall'\'', timeout => $service_vm_timeout);
            assert_script_run('\''if qvm-check sys-whonix; then qvm-start sys-whonix; fi'\'', timeout => $service_vm_timeout);
        } else {
            assert_script_run('\''qvm-start sys-firewall'\'', timeout => 90);
            assert_script_run('\''if qvm-check sys-whonix; then qvm-start sys-whonix; fi'\'', timeout => 90);
        }
%;
s/\Q$old\E/$new/ or die "failed to apply update2 Guix service VM timeout patch\n";
' "$update2"

    sudo grep -Fq "GUIX_VMUPDATE_QREXEC_TIMEOUT" "$update2" ||
        die "update2 Guix sequential vmupdate patch did not apply"
    sudo grep -Fq "upload_packages_versions(templates => \\@package_inventory_templates)" "$update2" ||
        die "update2 Guix package inventory patch did not apply"
    sudo grep -Fq "GUIX_VMUPDATE_SERVICE_VM_TIMEOUT" "$update2" ||
        die "update2 Guix service VM timeout patch did not apply"

    sudo python3 - "$zsystemtests" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'import os\nimport subprocess\nimport time\n',
    'import os\nimport subprocess\nimport shutil\nimport time\n',
    1,
)
old = '''    elif os_data["os_family"] == "ArchLinux":
        subprocess.check_call(["pacman", "--noconfirm", "-Sy"] + pkgs,
                              stdin=subprocess.DEVNULL,
                              env=environ)
    else:
        assert False
'''
new = '''    elif os_data["os_family"] == "ArchLinux":
        subprocess.check_call(["pacman", "--noconfirm", "-Sy"] + pkgs,
                              stdin=subprocess.DEVNULL,
                              env=environ)
    elif os_data["os_family"] == "Guix":
        # Native Guix System templates do not use an imperative distro package
        # manager.  The Qubes system-test tools are part of the template system
        # profile, so there is no install command to run here.
        pass
    else:
        assert False
'''
if old not in text:
    raise SystemExit("failed to apply zsystemtests Guix package-manager patch")
text = text.replace(old, new, 1)
old = '''    # workaround for https://github.com/QubesOS/qubes-issues/issues/9581
    with open("/etc/udev/rules.d/99-network-workaround.rules", "w") as f:
        f.write('SUBSYSTEM=="net", DRIVERS=="e1000e", RUN+="/usr/bin/ethtool -K $name sg off"\\n')

    setup_dist_dir = "/usr/share/setup-dist/status-files"
'''
new = '''    # workaround for https://github.com/QubesOS/qubes-issues/issues/9581
    if os_data["os_family"] != "Guix":
        os.makedirs("/etc/udev/rules.d", exist_ok=True)
        with open("/etc/udev/rules.d/99-network-workaround.rules", "w") as f:
            f.write('SUBSYSTEM=="net", DRIVERS=="e1000e", RUN+="/usr/bin/ethtool -K $name sg off"\\n')

    systemctl = shutil.which("systemctl")
    setup_dist_dir = "/usr/share/setup-dist/status-files"
'''
if old not in text:
    raise SystemExit("failed to apply zsystemtests udev/systemctl setup patch")
text = text.replace(old, new, 1)
old = '''    subprocess.call(["systemctl", "disable", "dnsmasq"],
                    stdin=subprocess.DEVNULL)

    if (
        os.path.exists("/usr/share/anon-gw-base-files/gateway")
        or os.path.exists("/usr/share/anon-ws-base-files/workstation")
    ):
        subprocess.call(["systemctl", "enable", "check-user-slice-on-shutdown.service"],
                        stdin=subprocess.DEVNULL)
'''
new = '''    if systemctl is not None:
        subprocess.call([systemctl, "disable", "dnsmasq"],
                        stdin=subprocess.DEVNULL)

    if (
        os.path.exists("/usr/share/anon-gw-base-files/gateway")
        or os.path.exists("/usr/share/anon-ws-base-files/workstation")
    ) and systemctl is not None:
        subprocess.call([systemctl, "enable", "check-user-slice-on-shutdown.service"],
                        stdin=subprocess.DEVNULL)
'''
if old not in text:
    raise SystemExit("failed to apply zsystemtests systemctl guard patch")
path.write_text(text.replace(old, new, 1))
PY
    sudo grep -Fq 'os_data["os_family"] == "Guix"' "$zsystemtests" ||
        die "zsystemtests Guix package-manager patch did not apply"
    sudo grep -Fq 'os_data["os_family"] != "Guix"' "$zsystemtests" ||
        die "zsystemtests Guix read-only /etc guard did not apply"
    sudo grep -Fq 'shutil.which("systemctl")' "$zsystemtests" ||
        die "zsystemtests systemctl guard patch did not apply"

    sudo perl -0pi -e '
my $old_dvm = q%    dvm_tpls=\$(qvm-ls --raw-data --fields=name,template,template_for_dispvms|grep "\$default_template|True\$"|cut -f 1 -d '\''|'\'')
    for dvmtpl in \$dvm_tpls; do
        running=\$(qvm-ls --raw-data --fields=name,template,state|grep "\$dvmtpl|Running\$"|cut -f 1 -d '\''|'\'')
        if [ -n "\$running" ]; then
            echo "Shutting down" \$running
            qvm-shutdown --force --wait \$running
            qvm-prefs "\$dvmtpl" template "\$new_template" || return 1
            echo "Starting up" \$running
            qvm-start --skip-if-running \$running || return 1
        else
            qvm-prefs "\$dvmtpl" template "\$new_template" || return 1
        fi
    done
%;
my $new_dvm = q%    wait_vm_halted() {
        vm="\$1"
        for _ in \$(seq 1 60); do
            if ! qvm-check --running "\$vm" >/dev/null 2>&1; then
                return 0
            fi
            sleep 1
        done
        echo "\$vm is still running"
        return 1
    }
    keep_service_template() {
        vm="\$1"
        case "\$vm" in
            sys-net|sys-firewall|sys-usb|sys-whonix)
                return 0
                ;;
        esac
        [ "\$(qvm-prefs "\$vm" provides_network 2>/dev/null || true)" = "True" ]
    }

    dvm_tpls=\$(qvm-ls --raw-data --fields=name,template,template_for_dispvms|grep "\$default_template|True\$"|cut -f 1 -d '\''|'\'')
    for dvmtpl in \$dvm_tpls; do
        running=\$(qvm-ls --raw-data --fields=name,template,state|grep "\$dvmtpl|Running\$"|cut -f 1 -d '\''|'\'')
        if [ -n "\$running" ]; then
            restart_running=
            for vm in \$running; do
                echo "Shutting down" "\$vm"
                vm_klass="\$(qvm-prefs "\$vm" klass)"
                vm_provides_network="\$(qvm-prefs "\$vm" provides_network)"
                if [ "\$vm_klass" = "DispVM" ]; then
                    qvm-kill "\$vm" || return 1
                else
                    qvm-shutdown --force --wait "\$vm" || qvm-kill "\$vm" || return 1
                fi
                wait_vm_halted "\$vm" || return 1
                if [ "\$vm_klass" = "DispVM" ] || [ "\$vm_provides_network" = "True" ]; then
                    echo "Leaving \$vm halted after template switch"
                else
                    restart_running="\$restart_running \$vm"
                fi
            done
            qvm-prefs "\$dvmtpl" template "\$new_template" || return 1
            if [ -n "\$restart_running" ]; then
                echo "Starting up" \$restart_running
                qvm-start --skip-if-running \$restart_running || return 1
            fi
        else
            qvm-prefs "\$dvmtpl" template "\$new_template" || return 1
        fi
    done
%;
s/\Q$old_dvm\E/$new_dvm/ or die "failed to apply switch_template running DispVM patch\n";

my $old_not_running = q%    not_running=\$(qvm-ls --raw-data --fields=name,template,state|grep "\$default_template|Halted\$"|cut -f 1 -d '\''|'\'')
    for vm in \$not_running; do
        echo "Switching \$vm"
        qvm-prefs "\$vm" template "\$new_template" || return 1
        if [ "\$(get_appmenus "\$vm")" = "\$old_default_appmenus" ]; then
            set_appmenus "\$vm" "\$new_default_appmenus"
            qvm-appmenus --update "\$vm"
        fi
    done
%;
my $new_not_running = q%    not_running=\$(qvm-ls --raw-data --fields=name,template,state|grep "\$default_template|Halted\$"|cut -f 1 -d '\''|'\'')
    for vm in \$not_running; do
        if keep_service_template "\$vm"; then
            echo "Keeping service VM \$vm on \$default_template"
            continue
        fi
        echo "Switching \$vm"
        qvm-prefs "\$vm" template "\$new_template" || return 1
        if [ "\$(get_appmenus "\$vm")" = "\$old_default_appmenus" ]; then
            set_appmenus "\$vm" "\$new_default_appmenus"
            qvm-appmenus --update "\$vm"
        fi
    done
%;
s/\Q$old_not_running\E/$new_not_running/ or die "failed to apply switch_template service VM skip patch\n";

my $old_running = q%    running=\$(qvm-ls --raw-data --fields=name,template,state|grep "\$default_template|Running\$"|cut -f 1 -d '\''|'\'')
    if [ -n "\$running" ]; then
        echo "Shutting down" \$running
        qvm-shutdown --force --wait \$running
        for vm in \$running; do
            echo "Switching \$vm"
            qvm-prefs "\$vm" template "\$new_template" || return 1
        done
        echo "Starting up" \$running
        qvm-start --skip-if-running \$running || return 1
    fi
%;
my $new_running = q%    running=\$(qvm-ls --raw-data --fields=name,template,state|grep "\$default_template|Running\$"|cut -f 1 -d '\''|'\'')
    if [ -n "\$running" ]; then
        restart_running=
        for vm in \$running; do
            if keep_service_template "\$vm"; then
                echo "Keeping service VM \$vm on \$default_template"
                continue
            fi
            echo "Shutting down" "\$vm"
            qvm-shutdown --force --wait "\$vm" || qvm-kill "\$vm" || return 1
            wait_vm_halted "\$vm" || return 1
            echo "Switching \$vm"
            qvm-prefs "\$vm" template "\$new_template" || return 1
            restart_running="\$restart_running \$vm"
        done
        if [ -n "\$restart_running" ]; then
            echo "Starting up" \$restart_running
            qvm-start --skip-if-running \$restart_running || return 1
        fi
    fi
%;
s/\Q$old_running\E/$new_running/ or die "failed to apply switch_template running AppVM patch\n";
' "$switch_template"

    sudo grep -Fq "wait_vm_halted" "$switch_template" ||
        die "switch_template running DispVM patch did not apply"
    sudo grep -Fq "keep_service_template" "$switch_template" ||
        die "switch_template service VM skip patch did not apply"
}

cleanup() {
    if [ -n "$rpm_asset_image" ] && [ -e "$rpm_asset_image" ]; then
        rm -f "$rpm_asset_image"
    fi
    if [ -n "$rpm_staging" ] && [ -d "$rpm_staging" ]; then
        rm -rf "$rpm_staging"
    fi
    if [ -n "$core_admin_vmupdate_archive" ] && [ -e "$core_admin_vmupdate_archive" ]; then
        rm -f "$core_admin_vmupdate_archive"
    fi
}
trap cleanup EXIT

append_qemu_append() {
    local argument="$1"

    if [ -n "$qemu_append" ]; then
        qemu_append="$qemu_append -$argument"
    else
        qemu_append="$argument"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tests-source)
            require_arg "$@"
            tests_source="$2"
            shift 2
            ;;
        --qubes-disk)
            require_arg "$@"
            qubes_disk="$2"
            shift 2
            ;;
        --guix-root-image)
            require_arg "$@"
            guix_root_image="$2"
            shift 2
            ;;
        --template-rpm)
            require_arg "$@"
            guix_template_rpm="$2"
            shift 2
            ;;
        --no-schedule)
            schedule_job=0
            shift
            ;;
        --wait)
            wait_job=1
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

[ -n "$install_mode" ] || {
    if [ -n "$guix_template_rpm" ]; then
        install_mode="rpm"
    else
        install_mode="direct"
    fi
}
case "$install_mode" in
    direct|rpm) ;;
    *) die "unsupported GUIX_INSTALL_MODE: $install_mode" ;;
esac
case "$update_target_network_mode" in
    auto|pci|bridge|nat) ;;
    *) die "unsupported QUBES_OPENQA_UPDATE_TARGET_NETWORK_MODE: $update_target_network_mode" ;;
esac
if [ -z "$template_name" ]; then
    case "$install_mode" in
        rpm) template_name="guix" ;;
        *) template_name="guix-openqa-test" ;;
    esac
fi
if [ "$run_central_vmupdate_test" = "1" ]; then
    cat >&2 <<'EOF'
warning: GUIX_RUN_CENTRAL_VMUPDATE_TEST=1 requires the nested dom0 to have a
warning: standard Internet-capable Qubes updates-proxy target, normally sys-net.
warning: A controlled/stub updates-proxy target is not sufficient proof for this gate.
EOF
fi

[ -d "$tests_source" ] || die "missing Qubes openQA tests source: $tests_source"
[ -r "$tests_source/main.pm" ] || die "invalid Qubes openQA tests source: $tests_source"
[ -r "$qubes_disk" ] || die "missing nested Qubes disk: $qubes_disk"
[ -r "$guix_root_image" ] || die "missing Guix root image: $guix_root_image"
if [ "$install_mode" = "rpm" ]; then
    [ -r "$guix_template_rpm" ] || die "missing Guix template RPM: $guix_template_rpm"
fi
if [ "$bootstrap_update_target" = "1" ]; then
    [ "$install_mode" = "rpm" ] ||
        die "GUIX_BOOTSTRAP_UPDATE_TARGET=1 requires GUIX_INSTALL_MODE=rpm"
    [ -r "$update_target_template_rpm" ] ||
        die "missing update target template RPM: $update_target_template_rpm"
    qemu_append="${qemu_append:-device intel-iommu,intremap=on}"
    if [ "$update_target_network_mode" = "nat" ] || [ "$update_target_network_mode" = "auto" ]; then
        case "$qemu_append" in
            *guixnat*) ;;
            *)
                append_qemu_append 'netdev user,id=guixnat'
                append_qemu_append 'device qemu-xhci,id=guixusb'
                append_qemu_append 'device usb-net,bus=guixusb.0,netdev=guixnat,mac=52:54:00:67:89:ab'
                ;;
        esac
    fi
    if [ -z "$appvm_netvm" ]; then
        appvm_netvm="$update_target_name"
    fi
fi
if [ -z "$max_job_time" ] && [ "$run_central_vmupdate_test" = "1" ]; then
    max_job_time=21600
fi
if [ -n "$core_admin_linux_tree" ]; then
    [ -r "$core_admin_linux_tree/vmupdate/agent/entrypoint.py" ] ||
        die "missing core-admin entrypoint in: $core_admin_linux_tree"
    [ -r "$core_admin_linux_tree/vmupdate/agent/source/utils.py" ] ||
        die "missing core-admin source utils in: $core_admin_linux_tree"
    [ -r "$core_admin_linux_tree/vmupdate/agent/source/common/package_manager.py" ] ||
        die "missing core-admin package-manager API in: $core_admin_linux_tree"
    [ -r "$core_admin_linux_tree/vmupdate/agent/source/guix/__init__.py" ] ||
        die "missing core-admin Guix package init in: $core_admin_linux_tree"
    [ -r "$core_admin_linux_tree/vmupdate/agent/source/guix/guix_cli.py" ] ||
        die "missing core-admin Guix backend in: $core_admin_linux_tree"
fi
need openqa-cli
need jq
need rsync
need stat
need tar

if ! perl -MText::Glob -e1 >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y libtext-glob-perl
fi
ensure_nose2_rpm

if [ -n "$core_admin_linux_tree" ]; then
    core_admin_vmupdate_archive="$(mktemp "${TMPDIR:-/tmp}/core-admin-guix-vmupdate.XXXXXX.tgz")"
    tar --exclude='__pycache__' --exclude='*.pyc' \
        -czf "$core_admin_vmupdate_archive" \
        -C "$core_admin_linux_tree/vmupdate/agent" .
fi

sudo install -d -o geekotest -g root -m 0755 "$tests_dest" "$factory_hdd"
sudo rsync -a --delete --exclude .git "$tests_source"/ "$tests_dest"/
sudo rsync -a "$repo_root/openqa/qubesos"/ "$tests_dest"/
apply_openqa_guix_patches
sudo install -d -o geekotest -g root -m 0755 "$tests_dest/data"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/import-native-rootfs-dom0.sh" \
    "$tests_dest/data/import-native-rootfs-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-native-guix-template-dom0.sh" \
    "$tests_dest/data/test-native-guix-template-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-guix-update-proxy-config-dom0.sh" \
    "$tests_dest/data/test-guix-update-proxy-config-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-guix-update-proxy-download-dom0.sh" \
    "$tests_dest/data/test-guix-update-proxy-download-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-guix-update-proxy-stub-download-dom0.sh" \
    "$tests_dest/data/test-guix-update-proxy-stub-download-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" \
    "$tests_dest/data/test-guix-central-vmupdate-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/bootstrap-qubes-update-target-dom0.sh" \
    "$tests_dest/data/bootstrap-qubes-update-target-dom0.sh"
sudo install -o geekotest -g root -m 0644 \
    "$repo_root/scripts/diagnose-guix-postinstall-dom0.sh" \
    "$tests_dest/data/diagnose-guix-postinstall-dom0.sh"
if [ -n "$core_admin_linux_tree" ]; then
    sudo install -o geekotest -g root -m 0644 \
        "$core_admin_vmupdate_archive" \
        "$tests_dest/data/core-admin-guix-vmupdate.tgz"
fi
if [ "$run_qubes_system_tests" = "1" ]; then
    sudo install -o geekotest -g root -m 0644 \
        "$nose2_rpm" \
        "$tests_dest/data/python3-nose2.rpm"
fi
sudo chown -R geekotest:root "$tests_dest"

copy_asset() {
    local src="$1"
    local name="$2"
    local dst="$factory_hdd/$name"
    local tmp="$dst.tmp.$$"

    if [ "$(readlink -f "$src")" = "$(readlink -f "$dst" 2>/dev/null || printf '%s' "$dst")" ]; then
        return
    fi

    # Snapshots are disabled for host-CPU nested virtualization, so the openQA
    # HDD asset is mutable. Refresh it on every scheduled run to avoid leaking
    # VM metadata or storage state from previous jobs.
    sudo cp -f --reflink=auto --sparse=always "$src" "$tmp"
    sudo chown geekotest:root "$tmp"
    sudo chmod 0644 "$tmp"
    sudo mv "$tmp" "$dst"
}

seed_worker_cache_asset() {
    local src="$1"
    local name="$2"
    local dst="$worker_cache_hdd/$name"
    local tmp="$dst.tmp.$$"
    local owner_group
    local etag
    local size
    local sqlite_db="$worker_cache_hdd/../cache.sqlite"
    local copy_asset=1

    [ -d "$worker_cache_hdd" ] || return 0
    if [ -e "$dst" ] && [ "$src" -ot "$dst" ]; then
        copy_asset=0
    fi

    if [ "$copy_asset" -eq 1 ]; then
        owner_group="$(
            stat -c '%U:%G' "$worker_cache_hdd" 2>/dev/null || printf '_openqa-worker:nogroup'
        )"
        sudo cp -f --reflink=auto --sparse=always "$src" "$tmp"
        sudo chown "$owner_group" "$tmp"
        sudo chmod 0600 "$tmp"
        sudo mv "$tmp" "$dst"
    fi

    if command -v sqlite3 >/dev/null 2>&1 &&
        command -v curl >/dev/null 2>&1 &&
        [ -e "$sqlite_db" ]; then
        size="$(stat -c '%s' "$src")"
        etag="$(
            curl -fsSI -L "$openqa_url/assets/hdd/$name" 2>/dev/null |
                awk 'BEGIN { IGNORECASE = 1 } /^ETag:/ { sub(/\r$/, ""); sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'
        )"
        if [ -n "$etag" ]; then
            sudo sqlite3 "$sqlite_db" \
                "INSERT INTO assets (filename, etag, size, last_use, pending)
                 VALUES ('$dst', '$etag', $size, strftime('%s','now'), 0)
                 ON CONFLICT(filename) DO UPDATE SET
                   etag=excluded.etag,
                   size=excluded.size,
                   last_use=excluded.last_use,
                   pending=0;"
        fi
    fi
}

copy_qcow2_overlay_asset() {
    local src="$1"
    local name="$2"
    local dst="$factory_hdd/$name"
    local tmp="$dst.tmp.$$"
    local base="$factory_hdd/${name%.qcow2}-base.qcow2"
    local base_tmp="$base.tmp.$$"
    local backing_file

    if [ "$(readlink -f "$src")" = "$(readlink -f "$dst" 2>/dev/null || printf '%s' "$dst")" ]; then
        return
    fi

    # The nested Qubes HDD is large and mutable under openQA because snapshots
    # are disabled for host-CPU nested virtualization. Keep one pristine,
    # worker-readable base image in the openQA asset tree, then use a fresh
    # qcow2 overlay for each job so scheduling does not recopy the full image.
    if [ ! -r "$base" ] || [ "$src" -nt "$base" ]; then
        sudo cp -f --reflink=auto --sparse=always "$src" "$base_tmp"
        sudo chown geekotest:root "$base_tmp"
        sudo chmod 0644 "$base_tmp"
        sudo mv "$base_tmp" "$base"
    fi

    backing_file="$(readlink -f "$base")"
    sudo rm -f "$tmp"
    if sudo qemu-img create -q -f qcow2 -F qcow2 -b "$backing_file" "$tmp"; then
        sudo chown geekotest:root "$tmp"
        sudo chmod 0644 "$tmp"
        sudo mv "$tmp" "$dst"
    else
        sudo rm -f "$tmp"
        copy_asset "$src" "$name"
    fi
}

need qemu-img
copy_qcow2_overlay_asset "$qubes_disk" "$qubes_asset_name"
copy_asset "$guix_root_image" "$guix_asset_name"
seed_worker_cache_asset "$factory_hdd/$guix_asset_name" "$guix_asset_name"

if [ "$install_mode" = "rpm" ]; then
    need cp
    need mke2fs
    need mktemp
    need truncate
    rpm_asset_image="$(mktemp "$repo_root/work.openqa-rpm.XXXXXX.img")"
    rpm_staging="$(mktemp -d "$repo_root/work.openqa-rpm.XXXXXX")"
    rpm_bytes="$(stat -c '%s' "$guix_template_rpm")"
    rpm_payload_bytes="$rpm_bytes"
    if [ "$bootstrap_update_target" = "1" ]; then
        update_target_rpm_bytes="$(stat -c '%s' "$update_target_template_rpm")"
        rpm_payload_bytes=$((rpm_payload_bytes + update_target_rpm_bytes))
    fi
    rpm_image_overhead=$((rpm_payload_bytes / 10 + 268435456))
    rpm_image_bytes=$(( ((rpm_payload_bytes + rpm_image_overhead + 1048575) / 1048576) * 1048576 ))
    truncate -s "$rpm_image_bytes" "$rpm_asset_image"
    cp "$guix_template_rpm" "$rpm_staging/$(basename "$guix_template_rpm")"
    if [ "$bootstrap_update_target" = "1" ]; then
        mkdir -p "$rpm_staging/update-target"
        cp "$update_target_template_rpm" \
            "$rpm_staging/update-target/$(basename "$update_target_template_rpm")"
    fi
    cp "$repo_root/scripts/bootstrap-qubes-update-target-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/import-native-rootfs-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-native-guix-template-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-guix-update-proxy-config-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-guix-update-proxy-download-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-guix-update-proxy-stub-download-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/test-guix-central-vmupdate-dom0.sh" "$rpm_staging/"
    cp "$repo_root/scripts/diagnose-guix-postinstall-dom0.sh" "$rpm_staging/"
    if [ -n "$core_admin_linux_tree" ]; then
        cp "$core_admin_vmupdate_archive" \
            "$rpm_staging/core-admin-guix-vmupdate.tgz"
    fi
    if [ "$run_qubes_system_tests" = "1" ]; then
        cp "$nose2_rpm" "$rpm_staging/python3-nose2.rpm"
    fi
    mke2fs -q -t ext4 -m 0 -d "$rpm_staging" "$rpm_asset_image"
    rm -rf "$rpm_staging"
    copy_asset "$rpm_asset_image" "$guix_rpm_asset_name"
fi

client_key="$(openssl rand -hex 16)"
client_secret="$(openssl rand -hex 32)"
sudo install -d -o root -g root -m 0755 /etc/openqa
sudo tee /etc/openqa/client.conf >/dev/null <<EOF
[localhost]
key = $client_key
secret = $client_secret

[localhost:9526]
key = $client_key
secret = $client_secret

[http://localhost]
key = $client_key
secret = $client_secret

[http://localhost:9526]
key = $client_key
secret = $client_secret
EOF
if getent group _openqa-worker >/dev/null 2>&1; then
    sudo chown root:_openqa-worker /etc/openqa/client.conf
    sudo chmod 0640 /etc/openqa/client.conf
else
    sudo chown root:root /etc/openqa/client.conf
    sudo chmod 0644 /etc/openqa/client.conf
fi

sudo -u geekotest psql openqa >/dev/null <<SQL
INSERT INTO users (username, provider, email, fullname, nickname, is_operator, is_admin, t_created, t_updated)
VALUES ('openqa-worker', 'script', '', 'openQA Worker', 'openqa-worker', 1, 1, now(), now())
ON CONFLICT (username, provider) DO UPDATE
SET is_operator = 1, is_admin = 1, t_updated = now();

DELETE FROM api_keys
WHERE user_id = (SELECT id FROM users WHERE username = 'openqa-worker' AND provider = 'script');

INSERT INTO api_keys (key, secret, user_id, t_created, t_updated)
SELECT '$client_key', '$client_secret', id, now(), now()
FROM users
WHERE username = 'openqa-worker' AND provider = 'script';
SQL

sudo tee /etc/openqa/workers.ini >/dev/null <<EOF
[global]
HOST = http://localhost:9526
CACHEDIRECTORY = /var/lib/openqa/cache
KEY = $client_key
SECRET = $client_secret

[1]
WORKER_CLASS = qemu_x86_64,qemu_x86_64_staging
EOF
if getent group _openqa-worker >/dev/null 2>&1; then
    sudo chown root:_openqa-worker /etc/openqa/workers.ini
else
    sudo chown root:root /etc/openqa/workers.ini
fi
sudo chmod 0644 /etc/openqa/workers.ini

sudo systemctl reset-failed openqa-webui openqa-scheduler openqa-websockets openqa-livehandler openqa-worker-plain@1 >/dev/null 2>&1 || true
sudo systemctl restart openqa-webui openqa-scheduler openqa-websockets openqa-livehandler
sudo systemctl restart openqa-worker-cacheservice openqa-worker-cacheservice-minion >/dev/null 2>&1 || true
sudo systemctl restart openqa-worker-plain@1

for _ in $(seq 1 60); do
    if curl -fsS "$openqa_url/api/v1/jobs/overview" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl -fsS "$openqa_url/api/v1/jobs/overview" >/dev/null ||
    die "openQA web UI API did not become reachable"
sudo systemctl is-active --quiet openqa-worker-plain@1 ||
    die "openQA worker did not become active"

if [ "$schedule_job" -eq 0 ]; then
    printf 'openQA Guix template tests installed without scheduling a job\n'
    exit 0
fi

guix_root_bytes="$(stat -c '%s' "$guix_root_image")"
job_args=(
    DISTRI=qubesos
    VERSION=4.3
    FLAVOR=guix-template
    ARCH=x86_64
    BUILD="$build"
    TEST=guix_template
    MACHINE=qemu_x86_64
    BACKEND=qemu
    CASEDIR="$tests_dest"
    BOOTFROM=disk
    HDD_1="$qubes_asset_name"
    HDD_2="$guix_asset_name"
    NUMDISKS=2
    HDDMODEL=scsi-hd
    HDDMODEL_2=scsi-hd
    HDDSERIAL_2=guixroot
    QEMU_DISABLE_SNAPSHOTS=1
    QEMUMACHINE=q35,kernel-irqchip=split
    QEMUCPU=host,+vmx,+invtsc
    QEMURAM="$qemu_ram"
    QEMUCPUS="$qemu_cpus"
    VIRTIO_CONSOLE=1
    SERIALDEV=hvc0
    NICTYPE=user
    NICMODEL=e1000e
    WORKER_CLASS=qemu_x86_64
    QUBES_DOM0_USER=user
    QUBES_DOM0_PASSWORD="$dom0_password"
    QUBES_DOM0_CONSOLE="$dom0_console"
    QUBES_DOM0_TYPE_MAX_INTERVAL="$dom0_type_max_interval"
    QUBES_DOM0_READY_TYPE_MAX_INTERVAL="$dom0_ready_type_max_interval"
    QUBES_DOM0_SERIAL_SETTLE_DELAY="$dom0_serial_settle_delay"
    QUBES_LOGIN_TIMEOUT=1200
    GUIX_INSTALL_MODE="$install_mode"
    GUIX_ROOT_DEVICE=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixroot
    GUIX_ROOT_BYTES="$guix_root_bytes"
    GUIX_ROOT_SIZE=20G
    GUIX_TEMPLATE_NAME="$template_name"
    GUIX_APPVM_NAME="$appvm_name"
    GUIX_APPVM_NETVM="$appvm_netvm"
    GUIX_RUN_QUBES_SYSTEM_TESTS="$run_qubes_system_tests"
    GUIX_QUBES_SYSTEM_TESTS="$qubes_system_tests"
    GUIX_RUN_PROXY_DOWNLOAD_TEST="$run_proxy_download_test"
    GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST="$run_proxy_stub_download_test"
    GUIX_RUN_CENTRAL_VMUPDATE_TEST="$run_central_vmupdate_test"
    GUIX_BOOTSTRAP_UPDATE_TARGET="$bootstrap_update_target"
    GUIX_UPDATE_TARGET_NAME="$update_target_name"
    GUIX_UPDATE_TARGET_NETWORK_MODE="$update_target_network_mode"
    GUIX_PROXY_DOWNLOAD_URL="$guix_proxy_download_url"
    GUIX_PROXY_STUB_DOWNLOAD_URL="$guix_proxy_stub_download_url"
    GUIX_PROXY_DOWNLOAD_TIMEOUT="$guix_proxy_download_timeout"
    GUIX_CENTRAL_VMUPDATE_TIMEOUT="$guix_central_vmupdate_timeout"
    GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL="$guix_central_vmupdate_proxy_probe_url"
    GUIX_VMUPDATE_QREXEC_TIMEOUT="$guix_vmupdate_qrexec_timeout"
    GUIX_VMUPDATE_SERVICE_VM_TIMEOUT="$guix_vmupdate_service_vm_timeout"
    GUIX_EXPECT_COMMANDS="$guix_expect_commands"
    GUIX_EXPECT_DESKTOPS="$guix_expect_desktops"
    GUIX_TEST_TIMEOUT="$guix_test_timeout"
)

if [ -n "$core_admin_linux_tree" ]; then
    job_args+=(
        GUIX_CORE_ADMIN_BACKEND=1
    )
fi

if [ -n "$qemu_append" ]; then
    job_args+=(
        QEMU_APPEND="$qemu_append"
    )
fi

if [ -n "$max_job_time" ]; then
    job_args+=(
        MAX_JOB_TIME="$max_job_time"
    )
fi

if [ "$install_mode" = "rpm" ]; then
    job_args=("${job_args[@]/NUMDISKS=2/NUMDISKS=3}")
    job_args+=(
        HDD_3="$guix_rpm_asset_name"
        HDDMODEL_3=scsi-hd
        HDDSERIAL_3=guixrpm
        GUIX_TEMPLATE_RPM_DEVICE=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixrpm
    )
fi

job_json="$(
    sudo openqa-cli api --host "$openqa_url" -X POST jobs "${job_args[@]}"
)"
job_id="$(printf '%s\n' "$job_json" | jq -r '.id // .ids[0] // .job_id // empty')"
[ -n "$job_id" ] || die "could not parse openQA job id from: $job_json"
printf 'scheduled openQA job %s\n' "$job_id"

if [ "$wait_job" -eq 0 ]; then
    exit 0
fi

while true; do
    job_state="$(sudo openqa-cli api --host "$openqa_url" "jobs/$job_id" | jq -r '.job.state + " " + (.job.result // "")')"
    printf '%s job %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_id" "$job_state"
    case "$job_state" in
        "done passed")
            exit 0
            ;;
        done\ *)
            exit 1
            ;;
    esac
    sleep 30
done
