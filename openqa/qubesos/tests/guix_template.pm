# SPDX-License-Identifier: GPL-3.0-or-later
use strict;
use warnings;

use base 'basetest';
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use testapi qw(get_required_var get_var record_info select_console type_string upload_logs wait_serial);

my $serial_copy_counter = 0;
my $dom0_command_counter = 0;

sub shell_quote {
    my ($value) = @_;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub checked_shell_command {
    my ($script) = @_;
    return 'set +e +o pipefail; bash -euo pipefail -c ' . shell_quote($script);
}

sub dom0_script_run {
    my ($cmd, %args) = @_;
    my $timeout = exists $args{timeout} ? $args{timeout} : 90;
    my $quiet = $args{quiet};
    my $command_interval = get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50);
    my $script_path;
    my $marker;
    my $res;
    my $wrapped_cmd;

    $dom0_command_counter++;
    $marker = sprintf('OPENQA_RC_%06d_', $dom0_command_counter);

    if ($cmd =~ /\n/) {
        $script_path = stage_dom0_command_script($cmd);
        $cmd = shell_quote($script_path);
    }

    $wrapped_cmd = $cmd;
    if ($timeout > 0) {
        $wrapped_cmd .=
            "; __openqa_rc=\$?; printf '$marker%s\\n' \"\$__openqa_rc\" > /dev/$testapi::serialdev";
    }

    type_string("$wrapped_cmd\n", max_interval => $command_interval);
    return if $timeout <= 0;

    $res = wait_serial(qr/\Q$marker\E\d+/, timeout => $timeout, quiet => $quiet);
    return unless $res;
    return ($res =~ /\Q$marker\E(\d+)/)[0];
}

sub dom0_assert_script_run {
    my ($cmd, %args) = @_;
    my $status = dom0_script_run($cmd, %args);

    die "command '$cmd' timed out" unless defined $status;
    die "command '$cmd' failed with exit status $status" if $status != 0;
    return $status;
}

sub read_data_file {
    my ($name) = @_;
    my $path = get_required_var('CASEDIR') . "/data/$name";
    open(my $fh, '<:raw', $path) or die "cannot open $path: $!";
    local $/;
    my $content = <$fh>;
    close($fh) or die "cannot close $path: $!";
    return $content;
}

sub append_serial_heredoc {
    my ($dest, $content, $label) = @_;
    $serial_copy_counter++;

    my $done = "OPENQA_${label}_${serial_copy_counter}_DONE";
    my $quoted_dest = shell_quote($dest);
    my $copy_interval = get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50);

    type_string("cat >> $quoted_dest <<'OPENQA_EOF'\n", max_interval => $copy_interval);
    type_string($content, max_interval => $copy_interval);
    type_string("OPENQA_EOF\nprintf '%s\\n' $done > /dev/$testapi::serialdev\n", max_interval => $copy_interval);
    wait_serial(qr/\Q$done\E/, timeout => 180) or die "serial copy chunk did not finish: $dest";
}

sub stage_dom0_command_script {
    my ($cmd) = @_;
    my $script_path = sprintf('/tmp/openqa-dom0-cmd-%06d.sh', $dom0_command_counter);
    my $quoted_script_path = shell_quote($script_path);
    my $ready = sprintf('OPENQA_CMD_%06d_READY', $dom0_command_counter);
    my $mode = sprintf('OPENQA_CMD_%06d_MODE', $dom0_command_counter);

    type_string(": > $quoted_script_path && chmod 0600 $quoted_script_path && printf '%s\\n' $ready > /dev/$testapi::serialdev\n",
        max_interval => get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50));
    wait_serial(qr/\Q$ready\E/, timeout => 60)
        or die "dom0 command script could not be initialized: $script_path";

    append_serial_heredoc($script_path, "#!/usr/bin/env bash\n$cmd\n", 'CMD');

    type_string("chmod 0700 $quoted_script_path && printf '%s\\n' $mode > /dev/$testapi::serialdev\n",
        max_interval => get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50));
    wait_serial(qr/\Q$mode\E/, timeout => 60)
        or die "dom0 command script mode could not be set: $script_path";

    return $script_path;
}

sub stage_data_file {
    my ($name, $dest) = @_;
    my $content = read_data_file($name);
    my $sha256 = sha256_hex($content);
    my $b64 = encode_base64($content, '');
    my @lines = ($b64 =~ /.{1,76}/g);
    my $b64_dest = "$dest.b64";
    my $label = $name;
    $label =~ s/[^A-Za-z0-9]/_/g;

    record_info('stage', "Copying $name to dom0 serial console");
    dom0_assert_script_run(': > ' . shell_quote($b64_dest), timeout => 60);

    while (@lines) {
        my @chunk = splice @lines, 0, 40;
        append_serial_heredoc($b64_dest, join("\n", @chunk) . "\n", $label);
    }

    my $decode = join(' ',
        'base64 -d', shell_quote($b64_dest), '>', shell_quote($dest) . ';',
        'chmod 0700', shell_quote($dest) . ';',
        'actual="$(sha256sum ' . shell_quote($dest) . ' | awk ' . shell_quote('{print $1}') . ')";',
        'test "$actual" =', shell_quote($sha256) . ';',
        'rm -f', shell_quote($b64_dest));
    dom0_assert_script_run(checked_shell_command($decode), timeout => 120);
}

sub rpm_asset_mount_command {
    my ($rpm_device) = @_;

    return join("\n",
        'mkdir -p /mnt/guix-template-rpm;',
        'rpm_dev=;',
        'for cand in ' . join(' ',
            shell_quote($rpm_device),
            '/dev/disk/by-id/*guixrpm*',
            '/dev/disk/by-id/*QEMU*guixrpm*',
            '/dev/sdc /dev/vdc /dev/xvdc') . '; do',
        '[ -e "$cand" ] || continue;',
        'real="$(readlink -f "$cand")";',
        '[ -b "$real" ] || continue;',
        'rpm_dev="$real"; break;',
        'done;',
        '[ -n "$rpm_dev" ];',
        'if ! awk ' . shell_quote('$2 == "/mnt/guix-template-rpm" { found = 1 } END { exit !found }') . ' /proc/mounts; then',
        'mount -o ro "$rpm_dev" /mnt/guix-template-rpm;',
        'fi;');
}

sub stage_rpm_asset_files {
    my ($rpm_device) = @_;
    my @files = (
        'diagnose-guix-postinstall-dom0.sh',
        'import-native-rootfs-dom0.sh',
        'test-guix-update-proxy-config-dom0.sh',
        'test-guix-update-proxy-download-dom0.sh',
        'test-native-guix-template-dom0.sh',
    );

    push @files, 'python3-nose2.rpm'
        if get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1';

    my $file_words = join(' ', map { shell_quote($_) } @files);
    my $copy_files = join("\n",
        'for f in ' . $file_words . '; do',
        'cp "/mnt/guix-template-rpm/$f" "/root/$f";',
        'chmod 0700 "/root/$f";',
        'done;');

    record_info('stage', 'Copying helper files from attached RPM asset disk');
    dom0_assert_script_run(checked_shell_command(join("\n",
        rpm_asset_mount_command($rpm_device),
        $copy_files)),
        timeout => 300);
}

sub wait_for_dom0_serial_login {
    my $timeout = get_var('QUBES_LOGIN_TIMEOUT', 1200);

    record_info('boot', "Waiting up to $timeout seconds for dom0 serial login");
    wait_serial(qr/(?:dom0|localhost) login:/i, timeout => $timeout)
        or die "dom0 serial login prompt did not appear within $timeout seconds";
}

sub dom0_wait_for_qubes_cli {
    my $cmd = checked_shell_command(join("\n",
        'for attempt in $(seq 1 12); do',
        '    if timeout 20 qvm-ls --raw-list > /tmp/openqa-qvm-ls.out 2> /tmp/openqa-qvm-ls.err; then',
        '        cat /tmp/openqa-qvm-ls.out',
        '        exit 0',
        '    fi',
        '    rc=$?',
        '    printf "qvm-ls readiness attempt %s failed with status %s\n" "$attempt" "$rc" >&2',
        '    systemctl --no-pager --plain is-active qubesd qubes-db-dom0 qubes-qrexec-policy-daemon 2>&1 || true',
        '    systemctl --no-pager --plain --failed 2>&1 || true',
        '    sleep 10',
        'done',
        'cat /tmp/openqa-qvm-ls.err >&2 || true',
        'exit 1'));

    record_info('dom0', 'Waiting for qvm-ls to return before staging template assets');
    dom0_assert_script_run($cmd, timeout => 420);
}

sub run {
    my ($self) = @_;

    my $template = get_var('GUIX_TEMPLATE_NAME', 'guix-openqa-test');
    my $appvm = get_var('GUIX_APPVM_NAME', 'guix-openqa-test-app');
    my $root_device = get_var('GUIX_ROOT_DEVICE', '/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixroot');
    my $root_bytes = get_var('GUIX_ROOT_BYTES', '21474836480');
    my $root_size = get_var('GUIX_ROOT_SIZE', '20G');
    my $install_mode = get_var('GUIX_INSTALL_MODE', 'direct');
    my $rpm_device = get_var('GUIX_TEMPLATE_RPM_DEVICE', '/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixrpm');
    my $test_timeout = get_var('GUIX_TEST_TIMEOUT', 3600);
    my $expect_commands = get_var('GUIX_EXPECT_COMMANDS', '');
    my $expect_desktops = get_var('GUIX_EXPECT_DESKTOPS', '');
    my $dom0_console = get_var('QUBES_DOM0_CONSOLE', 'root-console');

    $testapi::username = get_var('QUBES_DOM0_USER', 'user');
    $testapi::password = get_var('QUBES_DOM0_PASSWORD', 'qubes');

    wait_for_dom0_serial_login() if $dom0_console eq 'root-console';
    select_console($dom0_console);
    record_info('dom0', "Nested Qubes dom0 console is ready: $dom0_console");

    dom0_assert_script_run('whoami | grep -x root', timeout => 60);
    dom0_wait_for_qubes_cli();
    dom0_assert_script_run('lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL', timeout => 60);

    if ($install_mode eq 'rpm') {
        stage_rpm_asset_files($rpm_device);
    } else {
        stage_data_file('import-native-rootfs-dom0.sh', '/root/import-native-rootfs-dom0.sh');
        stage_data_file('test-native-guix-template-dom0.sh', '/root/test-native-guix-template-dom0.sh');
        stage_data_file('test-guix-update-proxy-config-dom0.sh', '/root/test-guix-update-proxy-config-dom0.sh');
        stage_data_file('test-guix-update-proxy-download-dom0.sh', '/root/test-guix-update-proxy-download-dom0.sh');
        stage_data_file('diagnose-guix-postinstall-dom0.sh', '/root/diagnose-guix-postinstall-dom0.sh');
        if (get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1') {
            stage_data_file('python3-nose2.rpm', '/root/python3-nose2.rpm');
        }
    }

    my @cleanup_vms = (
        $appvm,
        $template,
        'guix-openqa-test-app',
        'guix-openqa-test',
        'guix-native-test-app',
        'guix-native-test',
        'guix',
        'guix-minimal',
    );
    my %seen_cleanup_vm;
    @cleanup_vms = grep { !$seen_cleanup_vm{$_}++ } grep { length } @cleanup_vms;
    my $cleanup_vm_words = join(' ', map { shell_quote($_) } @cleanup_vms);

    my $cleanup = join("\n",
        'for vm in ' . $cleanup_vm_words . '; do',
        'if timeout 60 qvm-ls --raw-list | grep -Fxq "$vm"; then',
        'qvm-shutdown --wait "$vm" >/dev/null 2>&1 || qvm-kill "$vm" >/dev/null 2>&1 || true;',
        'qvm-remove --force "$vm" || true;',
        'fi;',
        'done');
    dom0_assert_script_run(checked_shell_command($cleanup), timeout => 600);

    my $resolve_device = join("\n",
        'root_dev=;',
        'expected_bytes=' . shell_quote($root_bytes) . ';',
        'for cand in ' . join(' ',
            shell_quote($root_device),
            '/dev/disk/by-id/*guixroot*',
            '/dev/disk/by-id/*QEMU*guixroot*',
            '/dev/sdb /dev/vdb /dev/xvdb') . '; do',
        '[ -e "$cand" ] || continue;',
        'real="$(readlink -f "$cand")";',
        '[ -b "$real" ] || continue;',
        'size="$(blockdev --getsize64 "$real")";',
        'if [ "$size" = "$expected_bytes" ]; then root_dev="$cand"; break; fi;',
        'done;',
        '[ -n "$root_dev" ];',
        'echo "$root_dev" | tee /root/openqa-guix-root-device');
    dom0_assert_script_run(checked_shell_command($resolve_device), timeout => 120);

    if ($install_mode eq 'rpm') {
        my $rpm_install_cmd = join("\n",
            rpm_asset_mount_command($rpm_device),
            'rpm_path="$(find /mnt/guix-template-rpm -maxdepth 1 -type f -name ' . shell_quote('qubes-template-*.rpm') . ' -print -quit)";',
            '[ -n "$rpm_path" ];',
            'cp "$rpm_path" /root/;',
            'rpm_copy="/root/$(basename "$rpm_path")";',
            'qvm-template --yes install --nogpgcheck "$rpm_copy" 2>&1 | tee /root/openqa-guix-import.log');
        dom0_assert_script_run(checked_shell_command($rpm_install_cmd), timeout => 1800);
        my $postinstall_diag_cmd = join("\n",
            'if grep -q "qubes[.]PostInstall service failed" /root/openqa-guix-import.log; then',
            '/root/diagnose-guix-postinstall-dom0.sh ' . shell_quote($template) . ' 2>&1 | tee /root/openqa-guix-postinstall-diagnostics.log;',
            'fi');
        dom0_assert_script_run(checked_shell_command($postinstall_diag_cmd), timeout => 900);
        my $postinstall_status = dom0_script_run(checked_shell_command(
            '! grep -E "PermissionError|Failed to set default application list|qubes[.]PostInstall service failed" /root/openqa-guix-import.log'),
            timeout => 60);
        if ($postinstall_status != 0) {
            dom0_assert_script_run('tar czf /root/openqa-guix-logs.tgz /root/openqa-guix-*.log /root/openqa-guix-root-device 2>/dev/null || true', timeout => 120);
            upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
            die "qvm-template post-install failed";
        }

    } else {
        my $import_cmd = join(' ',
            'root_dev="$(cat /root/openqa-guix-root-device)";',
            '/root/import-native-rootfs-dom0.sh',
            '--image "$root_dev"',
            '--name', shell_quote($template),
            '--root-size', shell_quote($root_size),
            '2>&1 | tee /root/openqa-guix-import.log');
        dom0_assert_script_run(checked_shell_command($import_cmd), timeout => 1800);
    }

    my $system_tests = '';
    if (get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1') {
        $system_tests = join(' ',
            '--run-system-tests',
            '--system-tests',
            shell_quote(get_var('GUIX_QUBES_SYSTEM_TESTS', 'qubes.tests.integ.qrexec:14400 qubes.tests.integ.vm_qrexec_gui:14400')));
    }

    my $command_checks = '';
    for my $command (grep { length } split(/\s+/, $expect_commands)) {
        $command_checks .= ' --expect-command ' . shell_quote($command);
    }

    my $desktop_checks = '';
    for my $desktop (grep { length } split(/\s+/, $expect_desktops)) {
        $desktop_checks .= ' --expect-desktop ' . shell_quote($desktop);
    }

    my $test_cmd = join(' ',
        get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1'
            ? 'GUIX_NOSE2_RPM=/root/python3-nose2.rpm QUBES_DOM0_TEST_USER=' . shell_quote($testapi::username)
            : '',
        '/root/test-native-guix-template-dom0.sh',
        '--template', shell_quote($template),
        '--appvm', shell_quote($appvm),
        $command_checks,
        $desktop_checks,
        $system_tests,
        '2>&1 | tee /root/openqa-guix-smoke.log /dev/' . $testapi::serialdev);
    my $smoke_status = dom0_script_run(checked_shell_command($test_cmd), timeout => $test_timeout);
    if (!defined $smoke_status || $smoke_status != 0) {
        dom0_assert_script_run('tar czf /root/openqa-guix-logs.tgz /root/openqa-guix-*.log /root/openqa-guix-root-device 2>/dev/null || true', timeout => 120);
        upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
        die "native Guix TemplateVM smoke test failed";
    }

    my $proxy_config_cmd = join(' ',
        '/root/test-guix-update-proxy-config-dom0.sh',
        '--template', shell_quote($template),
        '2>&1 | tee /root/openqa-guix-update-proxy-config.log /dev/' . $testapi::serialdev);
    my $proxy_config_status = dom0_script_run(checked_shell_command($proxy_config_cmd), timeout => 900);
    if (!defined $proxy_config_status || $proxy_config_status != 0) {
        dom0_assert_script_run('tar czf /root/openqa-guix-logs.tgz /root/openqa-guix-*.log /root/openqa-guix-root-device 2>/dev/null || true', timeout => 120);
        upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
        die "Guix update proxy config check failed";
    }

    if (get_var('GUIX_RUN_PROXY_DOWNLOAD_TEST', '0') eq '1') {
        my $proxy_download_cmd = join(' ',
            '/root/test-guix-update-proxy-download-dom0.sh',
            '--template', shell_quote($template),
            '--download-url', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_URL', 'https://guix.gnu.org/')),
            '--timeout', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_TIMEOUT', '240')),
            '2>&1 | tee /root/openqa-guix-update-proxy-download.log /dev/' . $testapi::serialdev);
        my $proxy_download_status = dom0_script_run(checked_shell_command($proxy_download_cmd), timeout => 900);
        if (!defined $proxy_download_status || $proxy_download_status != 0) {
            dom0_assert_script_run('tar czf /root/openqa-guix-logs.tgz /root/openqa-guix-*.log /root/openqa-guix-root-device 2>/dev/null || true', timeout => 120);
            upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
            die "Guix update proxy download check failed";
        }
    }

    dom0_assert_script_run('timeout 60 qvm-ls --raw-list | grep -Fx ' . shell_quote($template), timeout => 90);
    dom0_assert_script_run('tar czf /root/openqa-guix-logs.tgz /root/openqa-guix-*.log /root/openqa-guix-root-device 2>/dev/null || true', timeout => 120);
    upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
}

sub test_flags {
    return {fatal => 1};
}

1;
