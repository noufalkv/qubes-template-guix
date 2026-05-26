#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
openqa_test="$repo_root/openqa/qubesos/tests/guix_template.pm"
setup_script="$repo_root/scripts/setup-openqa-guix-template-test.sh"
perl_syntax_check="$repo_root/tests/openqa-perl-syntax-check.sh"

require_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -Fq -- "$pattern" "$file"; then
        printf '%s: missing %s\npattern: %s\n' \
            "${file#$repo_root/}" "$description" "$pattern" >&2
        exit 1
    fi
}

require_contains "$openqa_test" \
    "'test-native-guix-template-dom0.sh'," \
    'native dom0 smoke script in RPM asset manifest'
require_contains "$openqa_test" \
    "'test-guix-central-vmupdate-dom0.sh'," \
    'central vmupdate script in RPM asset manifest'
require_contains "$openqa_test" \
    "'core-admin-guix-vmupdate.tgz'," \
    'core-admin Guix vmupdate archive in RPM manifest'
require_contains "$openqa_test" \
    "'bootstrap-qubes-update-target-dom0.sh'," \
    'update-target bootstrap script in RPM asset manifest'
for script in \
    test-guix-update-proxy-config-dom0.sh \
    test-guix-update-proxy-download-dom0.sh \
    test-guix-update-proxy-stub-download-dom0.sh
do
    require_contains "$openqa_test" "'$script'," \
        "update-proxy script in RPM asset manifest: $script"
done
require_contains "$openqa_test" \
    "stage_data_file('test-native-guix-template-dom0.sh', '/root/test-native-guix-template-dom0.sh')" \
    'native dom0 smoke script staging in direct-rootfs mode'
require_contains "$openqa_test" \
    "stage_data_file('test-guix-central-vmupdate-dom0.sh', '/root/test-guix-central-vmupdate-dom0.sh')" \
    'central vmupdate script staging in direct-rootfs mode'
require_contains "$openqa_test" \
    "stage_data_file('core-admin-guix-vmupdate.tgz', '/root/core-admin-guix-vmupdate.tgz')" \
    'core-admin Guix vmupdate archive staging in direct-rootfs mode'
require_contains "$openqa_test" \
    "stage_data_file('bootstrap-qubes-update-target-dom0.sh', '/root/bootstrap-qubes-update-target-dom0.sh')" \
    'update-target bootstrap script staging in direct-rootfs mode'
for script in \
    test-guix-update-proxy-config-dom0.sh \
    test-guix-update-proxy-download-dom0.sh \
    test-guix-update-proxy-stub-download-dom0.sh
do
    require_contains "$openqa_test" \
        "stage_data_file('$script', '/root/$script')" \
        "update-proxy script staging in direct-rootfs mode: $script"
done
require_contains "$openqa_test" \
    "'/root/test-native-guix-template-dom0.sh'," \
    'native dom0 smoke script execution'
require_contains "$openqa_test" \
    "'--appvm', shell_quote(\$appvm)," \
    'AppVM argument passed to native smoke script'
require_contains "$openqa_test" \
    "\$appvm_netvm_arg," \
    'optional AppVM NetVM argument passed to native smoke script'
require_contains "$openqa_test" \
    "\$system_tests," \
    'optional Qubes system-test arguments passed to native smoke script'
require_contains "$openqa_test" \
    "\$command_checks," \
    'expected-command assertions passed to native smoke script'
require_contains "$openqa_test" \
    "\$desktop_checks," \
    'expected-desktop assertions passed to native smoke script'
require_contains "$openqa_test" \
    'die "native Guix TemplateVM smoke test failed"' \
    'hard failure on native smoke script failure'
require_contains "$openqa_test" \
    "'/root/test-guix-update-proxy-config-dom0.sh'," \
    'update-proxy config script execution'
require_contains "$openqa_test" \
    'die "Guix update proxy config check failed"' \
    'hard failure on update-proxy config failure'
require_contains "$openqa_test" \
    "if (get_var('GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST', '0') eq '1')" \
    'update-proxy stub-download opt-in gate'
require_contains "$openqa_test" \
    "'/root/test-guix-update-proxy-stub-download-dom0.sh'," \
    'update-proxy stub-download script execution'
require_contains "$openqa_test" \
    "'--download-url', shell_quote(get_var('GUIX_PROXY_STUB_DOWNLOAD_URL'" \
    'update-proxy stub-download URL argument'
require_contains "$openqa_test" \
    'die "Guix update proxy stub download check failed"' \
    'hard failure on update-proxy stub-download failure'
require_contains "$openqa_test" \
    "if (get_var('GUIX_RUN_PROXY_DOWNLOAD_TEST', '0') eq '1')" \
    'update-proxy real-download opt-in gate'
require_contains "$openqa_test" \
    "'/root/test-guix-update-proxy-download-dom0.sh'," \
    'update-proxy real-download script execution'
require_contains "$openqa_test" \
    "'--download-url', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_URL'" \
    'update-proxy real-download URL argument'
require_contains "$openqa_test" \
    'die "Guix update proxy download check failed"' \
    'hard failure on update-proxy real-download failure'
require_contains "$openqa_test" \
    "if (get_var('GUIX_RUN_CENTRAL_VMUPDATE_TEST', '0') eq '1')" \
    'central vmupdate opt-in gate'
require_contains "$openqa_test" \
    "'/root/test-guix-central-vmupdate-dom0.sh'," \
    'central vmupdate script execution'
require_contains "$openqa_test" \
    "'--proxy-probe-url', shell_quote(get_var('GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL'" \
    'central vmupdate proxy probe URL argument'
require_contains "$openqa_test" \
    'die "Guix central vmupdate check failed"' \
    'hard failure on central vmupdate failure'
require_contains "$openqa_test" \
    "if (get_var('GUIX_CORE_ADMIN_BACKEND', '0') eq '1')" \
    'core-admin Guix backend opt-in gate'
require_contains "$openqa_test" \
    'install_core_admin_guix_backend();' \
    'core-admin Guix backend install hook'
require_contains "$openqa_test" \
    'with tarfile.open(archive_path, "r:gz") as archive:' \
    'core-admin vmupdate archive extraction in openQA'
require_contains "$openqa_test" \
    'assert hasattr(package_manager, "AgentType")' \
    'core-admin package-manager API smoke assertion in openQA'
require_contains "$openqa_test" \
    'assert guix_cli.GUIXCLI.CHANNELS_FILE == "/etc/guix/channels.scm"' \
    'core-admin Guix backend smoke assertion in openQA'
require_contains "$openqa_test" \
    "if (get_var('GUIX_BOOTSTRAP_UPDATE_TARGET', '0') eq '1')" \
    'update-target bootstrap opt-in gate'
require_contains "$openqa_test" \
    'die "GUIX_BOOTSTRAP_UPDATE_TARGET=1 requires GUIX_INSTALL_MODE=rpm"' \
    'RPM install-mode guard for update-target bootstrap'
require_contains "$openqa_test" \
    "'/root/bootstrap-qubes-update-target-dom0.sh'," \
    'update-target bootstrap script execution'
require_contains "$openqa_test" \
    "'--target', shell_quote(get_var('GUIX_UPDATE_TARGET_NAME'" \
    'update-target bootstrap target argument'
require_contains "$openqa_test" \
    "'--network-mode', shell_quote(get_var('GUIX_UPDATE_TARGET_NETWORK_MODE'" \
    'update-target bootstrap network-mode argument'
require_contains "$openqa_test" \
    "'--template-rpm \"\$update_target_rpm\"'," \
    'update-target bootstrap template RPM argument'
require_contains "$openqa_test" \
    'die "Qubes update target bootstrap failed"' \
    'hard failure on update-target bootstrap failure'

require_contains "$setup_script" \
    'bootstrap_update_target="${GUIX_BOOTSTRAP_UPDATE_TARGET:-0}"' \
    'setup bootstrap opt-in default'
require_contains "$setup_script" \
    'die "GUIX_BOOTSTRAP_UPDATE_TARGET=1 requires GUIX_INSTALL_MODE=rpm"' \
    'setup RPM install-mode guard for update-target bootstrap'
for path in \
    'vmupdate/agent/entrypoint.py' \
    'vmupdate/agent/source/utils.py' \
    'vmupdate/agent/source/common/package_manager.py' \
    'vmupdate/agent/source/guix/__init__.py' \
    'vmupdate/agent/source/guix/guix_cli.py'
do
    require_contains "$setup_script" "$path" \
        "setup validates/copies core-admin Guix backend file: $path"
done
require_contains "$setup_script" \
    'appvm_netvm="$update_target_name"' \
    'setup maps empty AppVM NetVM to bootstrapped update target'
require_contains "$setup_script" \
    "append_qemu_append 'netdev user,id=guixnat'" \
    'setup adds QEMU user-net backend for NAT update target bootstrap'
require_contains "$setup_script" \
    "append_qemu_append 'device qemu-xhci,id=guixusb'" \
    'setup adds QEMU USB controller for NAT update target bootstrap'
require_contains "$setup_script" \
    "append_qemu_append 'device usb-net,bus=guixusb.0,netdev=guixnat,mac=52:54:00:67:89:ab'" \
    'setup adds QEMU USB NIC for NAT update target bootstrap'
require_contains "$setup_script" \
    '"$repo_root/scripts/bootstrap-qubes-update-target-dom0.sh"' \
    'setup copies update-target bootstrap script into openQA data'
require_contains "$setup_script" \
    'installedtest startup sys-net recovery patch' \
    'setup applies installedtest startup sys-net recovery openQA patch'
require_contains "$setup_script" \
    'update2-guix-sequential-vmupdate.patch' \
    'setup applies Guix sequential vmupdate openQA patch'
require_contains "$setup_script" \
    'failed to apply switch_template running DispVM patch' \
    'setup applies switch_template running DispVM openQA patch'
require_contains "$repo_root/openqa/qubesos/patches/update2-guix-sequential-vmupdate.patch" \
    'GUIX_VMUPDATE_QREXEC_TIMEOUT' \
    'update2 patch exposes qrexec timeout setting'
require_contains "$repo_root/openqa/qubesos/patches/update2-guix-sequential-vmupdate.patch" \
    'qvm-shutdown --wait $target' \
    'update2 patch shuts down each Guix target after sequential update'
require_contains "$repo_root/openqa/qubesos/patches/update2-guix-sequential-vmupdate.patch" \
    'upload_packages_versions(templates => \@package_inventory_templates)' \
    'update2 patch limits package inventory to Guix sequential targets'
require_contains "$repo_root/openqa/qubesos/patches/update2-guix-sequential-vmupdate.patch" \
    'GUIX_VMUPDATE_SERVICE_VM_TIMEOUT' \
    'update2 patch exposes service VM restart timeout setting'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    '$self->recover_sys_net;' \
    'startup patch recovers sys-net before GUI login'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    "select_console(get_var('GUI_CONSOLE', 'x11'), await_console => 0)" \
    'startup patch returns to GUI login console without waiting for desktop'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    'net_bdf="$(for dev in /sys/bus/pci/devices/*' \
    'startup patch discovers sys-net PCI device from dom0 sysfs'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    'net_dev="dom0:$net_id"' \
    'startup patch preserves dom0 prefix while normalizing PCI BDF for qvm-pci'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    'qvm-start sys-net", timeout => 180' \
    'startup patch tries normal sys-net start before PCI reattach'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    'GUIX_ACCEPT_RUNNING_SERVICE_NET' \
    'startup patch gates nested NM needle tolerance on explicit setting'
require_contains "$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
    'network stack is running but NetworkManager applet needle is missing' \
    'startup patch only tolerates NM needle absence after service VM proof'
require_contains "$repo_root/openqa/qubesos/patches/installedtest-bounded-log-uploads.patch" \
    'GUIX_FAILOK_LOG_UPLOADS' \
    'bounded log upload patch gates fail-open uploads on explicit setting'
require_contains "$setup_script" \
    'failed to apply installedtest bounded log upload patch' \
    'setup applies bounded log upload openQA patch'
require_contains "$repo_root/openqa/qubesos/patches/switch-template-running-dispvms.patch" \
    'wait_vm_halted' \
    'switch_template patch waits for running DispVM shutdown'
require_contains "$repo_root/openqa/qubesos/patches/switch-template-running-dispvms.patch" \
    'qvm-kill "\$vm" || return 1' \
    'switch_template patch kills running DispVMs before retargeting their template'
require_contains "$repo_root/openqa/qubesos/patches/switch-template-running-dispvms.patch" \
    'qvm-prefs "\$vm" provides_network' \
    'switch_template patch identifies network-providing VMs'
require_contains "$repo_root/openqa/qubesos/patches/switch-template-running-dispvms.patch" \
    'keep_service_template' \
    'switch_template patch keeps service VMs on Fedora template'
require_contains "$repo_root/openqa/qubesos/patches/switch-template-running-dispvms.patch" \
    'Leaving \$vm halted after template switch' \
    'switch_template patch avoids restarting fragile service VMs after retargeting'
require_contains "$perl_syntax_check" \
    'patched-official/tests/update2.pm' \
    'Perl syntax check compiles freshly patched upstream update2 test'
require_contains "$perl_syntax_check" \
    'patched-official/tests/switch_template.pm' \
    'Perl syntax check compiles freshly patched upstream switch_template test'
require_contains "$perl_syntax_check" \
    'update2-guix-sequential-vmupdate.patch' \
    'Perl syntax check applies reviewable update2 patch before compiling'
require_contains "$perl_syntax_check" \
    'startup-recover-sys-net-before-gui.patch' \
    'Perl syntax check applies reviewable sys-net startup patch before compiling'
require_contains "$perl_syntax_check" \
    'installedtest-bounded-log-uploads.patch' \
    'Perl syntax check applies reviewable bounded log upload patch before compiling'
require_contains "$perl_syntax_check" \
    'switch-template-running-dispvms.patch' \
    'Perl syntax check applies reviewable switch_template patch before compiling'
require_contains "$setup_script" \
    'failed to apply update2 Guix package inventory patch' \
    'setup applies Guix package inventory openQA patch'
require_contains "$setup_script" \
    'failed to apply update2 Guix service VM timeout patch' \
    'setup applies Guix service VM timeout openQA patch'
require_contains "$setup_script" \
    'failed to apply installedtest nested network stack readiness patch' \
    'setup applies nested service-network readiness openQA patch'
require_contains "$setup_script" \
    'failed to apply zsystemtests Guix package-manager patch' \
    'setup applies Guix package-manager branch in official zsystemtests plugin'
require_contains "$setup_script" \
    'failed to apply zsystemtests systemctl guard patch' \
    'setup prevents zsystemtests from calling systemctl in native Guix templates'
require_contains "$setup_script" \
    'Native Guix System templates do not use an imperative distro package' \
    'setup documents why zsystemtests skips package installation for Guix'
require_contains "$setup_script" \
    'os_data["os_family"] != "Guix"' \
    'setup avoids zsystemtests writing under read-only Guix /etc'
require_contains "$repo_root/openqa/qubesos/patches/zsystemtests-guix-no-package-install.patch" \
    'os_data["os_family"] == "Guix"' \
    'reviewable zsystemtests patch adds Guix package-manager branch'
require_contains "$repo_root/openqa/qubesos/patches/zsystemtests-guix-no-package-install.patch" \
    'os_data["os_family"] != "Guix"' \
    'reviewable zsystemtests patch avoids read-only Guix /etc writes'
require_contains "$repo_root/openqa/qubesos/patches/zsystemtests-guix-no-package-install.patch" \
    'shutil.which("systemctl")' \
    'reviewable zsystemtests patch guards systemd-only calls'
require_contains "$perl_syntax_check" \
    'zsystemtests-guix-no-package-install.patch' \
    'Perl syntax check also applies zsystemtests Guix patch'
require_contains "$perl_syntax_check" \
    'python3 -m py_compile' \
    'Perl syntax check validates patched zsystemtests Python syntax'
require_contains "$setup_script" \
    'cp "$repo_root/scripts/bootstrap-qubes-update-target-dom0.sh" "$rpm_staging/"' \
    'setup copies update-target bootstrap helper into RPM staging'
require_contains "$setup_script" \
    '"$tests_dest/data/core-admin-guix-vmupdate.tgz"' \
    'setup stages core-admin vmupdate archive into openQA data'
require_contains "$setup_script" \
    '"$rpm_staging/core-admin-guix-vmupdate.tgz"' \
    'setup copies core-admin vmupdate archive into RPM staging'
require_contains "$setup_script" \
    'QEMU_APPEND="$qemu_append"' \
    'setup forwards bootstrap QEMU append arguments into scheduled openQA job'
require_contains "$setup_script" \
    'GUIX_CORE_ADMIN_BACKEND=1' \
    'setup forwards core-admin backend opt-in into scheduled openQA job'

for setting in \
    'GUIX_APPVM_NAME="$appvm_name"' \
    'GUIX_APPVM_NETVM="$appvm_netvm"' \
    'GUIX_BOOTSTRAP_UPDATE_TARGET="$bootstrap_update_target"' \
    'GUIX_UPDATE_TARGET_NAME="$update_target_name"' \
    'GUIX_UPDATE_TARGET_NETWORK_MODE="$update_target_network_mode"' \
    'GUIX_RUN_QUBES_SYSTEM_TESTS="$run_qubes_system_tests"' \
    'GUIX_QUBES_SYSTEM_TESTS="$qubes_system_tests"' \
    'GUIX_RUN_PROXY_DOWNLOAD_TEST="$run_proxy_download_test"' \
    'GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST="$run_proxy_stub_download_test"' \
    'GUIX_PROXY_DOWNLOAD_URL="$guix_proxy_download_url"' \
    'GUIX_PROXY_STUB_DOWNLOAD_URL="$guix_proxy_stub_download_url"' \
    'GUIX_PROXY_DOWNLOAD_TIMEOUT="$guix_proxy_download_timeout"' \
    'GUIX_RUN_CENTRAL_VMUPDATE_TEST="$run_central_vmupdate_test"' \
    'GUIX_CENTRAL_VMUPDATE_TIMEOUT="$guix_central_vmupdate_timeout"' \
    'GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL="$guix_central_vmupdate_proxy_probe_url"' \
    'GUIX_VMUPDATE_QREXEC_TIMEOUT="$guix_vmupdate_qrexec_timeout"' \
    'GUIX_VMUPDATE_SERVICE_VM_TIMEOUT="$guix_vmupdate_service_vm_timeout"' \
    'GUIX_EXPECT_COMMANDS="$guix_expect_commands"' \
    'GUIX_EXPECT_DESKTOPS="$guix_expect_desktops"' \
    'GUIX_TEST_TIMEOUT="$guix_test_timeout"'
do
    require_contains "$setup_script" "$setting" "openQA scheduler setting $setting"
done

printf 'openQA Guix template wiring check passed\n'
