# SPDX-License-Identifier: GPL-3.0-or-later
use strict;
use warnings;

use base 'basetest';
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use testapi qw(get_required_var get_var record_info select_console send_key type_string upload_logs wait_serial);

my $serial_copy_counter = 0;
my $dom0_command_counter = 0;

sub settle_dom0_console {
    sleep get_var('QUBES_DOM0_SERIAL_SETTLE_DELAY', 3);
}

sub shell_quote {
    my ($value) = @_;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub checked_shell_command {
    my ($script) = @_;
    return 'set +e +o pipefail; bash -euo pipefail -c ' . shell_quote($script);
}

sub serial_output_path {
    return get_var('QUBES_DOM0_SERIAL_OUTPUT_PATH', '/root/openqa-guix-serial-output');
}

sub shell_simple_path {
    my ($path) = @_;
    die "unsupported serial output path: $path" unless $path =~ m{\A/[A-Za-z0-9_./-]+\z};
    return $path;
}

sub shell_word_safe_for_vnc {
    my ($word) = @_;
    return if !defined $word || $word =~ /[A-Z]/;
    return shell_quote($word);
}

sub prepare_serial_output_path {
    my $serial_path = "/dev/$testapi::serialdev";
    my $output_path = serial_output_path();
    my $command_interval = get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50);
    my @candidates = ($serial_path, '/dev/console', '/dev/ttyS0', '/dev/xvc0');
    my %seen;

    @candidates = grep { !$seen{$_}++ } @candidates;

    for my $candidate (@candidates) {
        my $safe_candidate = shell_simple_path($candidate);
        my $safe_output = shell_simple_path($output_path);

        for my $attempt (1 .. 3) {
            my $ready = sprintf('oqserial%06d', ++$serial_copy_counter);
            my $prepare_cmd;

            if ($output_path =~ m{\A/dev/}) {
                next unless $output_path eq $candidate;
                $prepare_cmd = "test -w $safe_candidate && echo $ready > $safe_candidate";
            } else {
                $prepare_cmd = "test -w $safe_candidate && ln -sf $safe_candidate $safe_output && echo $ready > $safe_output";
            }

            type_string("$prepare_cmd\n", max_interval => $command_interval);
            if (wait_serial(qr/\Q$ready\E/, timeout => 60, quiet => 1)) {
                settle_dom0_console();
                return;
            }
            send_key('ctrl-c');
            settle_dom0_console();
        }
    }

    die "dom0 serial output path could not be prepared: $output_path";
}

sub dom0_script_run {
    my ($cmd, %args) = @_;
    my $timeout = exists $args{timeout} ? $args{timeout} : 90;
    my $quiet = $args{quiet};
    my $command_interval = get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50);
    my $serial_output = shell_simple_path(serial_output_path());
    my $script_path;
    my $marker;
    my $res;
    my $wrapped_cmd;

    $dom0_command_counter++;
    $marker = sprintf('oqrc%06d', $dom0_command_counter);

    if ($cmd =~ /\n/) {
        $script_path = stage_dom0_command_script($cmd);
        $cmd = shell_quote($script_path);
    }

    $wrapped_cmd = $cmd;
    if ($timeout > 0) {
        $wrapped_cmd = "$wrapped_cmd; echo ${marker}\$? > $serial_output";
    }

    type_string("$wrapped_cmd\n", max_interval => $command_interval);
    return if $timeout <= 0;

    $res = wait_serial(qr/\Q$marker\E\d+/, timeout => $timeout, quiet => $quiet);
    if (!$res) {
        send_key('ctrl-c');
        settle_dom0_console();
        return;
    }
    settle_dom0_console();
    return ($res =~ /\Q$marker\E(\d+)/)[0];
}

sub dom0_assert_script_run {
    my ($cmd, %args) = @_;
    my $attempts = delete $args{attempts} // 1;
    my $status;

    for my $attempt (1 .. $attempts) {
        $status = dom0_script_run($cmd, %args);
        last if defined $status;
    }

    die "command '$cmd' timed out" unless defined $status;
    die "command '$cmd' failed with exit status $status" if $status != 0;
    return $status;
}

sub upload_dom0_logs {
    dom0_assert_script_run(
        'tar --create --gzip --file /root/openqa-guix-logs.tgz --ignore-failed-read /root/openqa-guix-*.log /root/openqa-guix-root-device /root/openqa-guix-central-vmupdate* 2>/dev/null || true',
        timeout => 120);
    upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
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

    my $done = sprintf('oqcopy%06d', $serial_copy_counter);
    my $quoted_dest = shell_quote($dest);
    my $serial_output = shell_simple_path(serial_output_path());
    my $copy_interval = get_var('QUBES_DOM0_TYPE_MAX_INTERVAL', 50);

    type_string("cat >> $quoted_dest <<'oqeof'\n", max_interval => $copy_interval);
    type_string($content, max_interval => $copy_interval);
    type_string("oqeof\necho $done > $serial_output\n", max_interval => $copy_interval);
    wait_serial(qr/\Q$done\E/, timeout => 180) or die "serial copy chunk did not finish: $dest";
    settle_dom0_console();
}

sub stage_dom0_file_b64 {
    my ($content, $dest, $mode, $label) = @_;
    my $sha256 = sha256_hex($content);
    my $b64 = encode_base64($content, '');
    my @lines = ($b64 =~ /.{1,76}/g);
    my $b64_dest = "$dest.b64";
    my $tmp_dest = "$dest.tmp";
    my $lines_per_chunk = get_var('QUBES_DOM0_B64_LINES_PER_CHUNK', 8);
    my $transfer_attempts = get_var('QUBES_DOM0_B64_TRANSFER_ATTEMPTS', 3);

    $label =~ s/[^A-Za-z0-9]/_/g;

    if ($lines_per_chunk !~ /\A[1-9][0-9]*\z/) {
        $lines_per_chunk = 8;
    }
    if ($transfer_attempts !~ /\A[1-9][0-9]*\z/) {
        $transfer_attempts = 3;
    }

    my $decode = join(' ',
        'rm -f', shell_quote($tmp_dest) . ';',
        'base64 -d', shell_quote($b64_dest), '>', shell_quote($tmp_dest) . ';',
        'actual="$(sha256sum ' . shell_quote($tmp_dest) . ' | awk ' . shell_quote('{print $1}') . ')";',
        'if [ "$actual" !=', shell_quote($sha256), ']; then',
        'echo', shell_quote("hash mismatch for $dest: expected $sha256 actual \$actual") . ';',
        'exit 1;',
        'fi;',
        'chmod', shell_quote($mode), shell_quote($tmp_dest) . ';',
        'mv -f', shell_quote($tmp_dest), shell_quote($dest) . ';',
        'rm -f', shell_quote($b64_dest));

    for my $attempt (1 .. $transfer_attempts) {
        my @pending = @lines;
        dom0_assert_script_run('rm -f ' . shell_quote($tmp_dest) . ' ' . shell_quote($b64_dest) . ' && : > ' . shell_quote($b64_dest),
            timeout => 60);

        while (@pending) {
            my @chunk = splice @pending, 0, $lines_per_chunk;
            append_serial_heredoc($b64_dest, join("\n", @chunk) . "\n", $label);
        }

        my $status = dom0_script_run(checked_shell_command($decode), timeout => 120);
        return if defined $status && $status == 0;

        last if $attempt >= $transfer_attempts;
        record_info('stage', "Retrying checked dom0 transfer for $dest after checksum/decode failure");
    }

    die "checked dom0 transfer failed for $dest";
}

sub stage_dom0_command_script {
    my ($cmd) = @_;
    my $script_path = sprintf('/tmp/openqa-dom0-cmd-%06d.sh', $dom0_command_counter);
    my $content = "#!/usr/bin/env bash\n$cmd\n";

    stage_dom0_file_b64($content, $script_path, '0700', 'CMD');
    return $script_path;
}

sub stage_data_file {
    my ($name, $dest) = @_;
    my $content = read_data_file($name);

    record_info('stage', "Copying $name to dom0 serial console");
    stage_dom0_file_b64($content, $dest, '0700', $name);
}

sub rpm_asset_mount_command {
    my ($rpm_device) = @_;
    my @device_candidates = grep { defined } (
        shell_word_safe_for_vnc($rpm_device),
        '/dev/disk/by-id/*guixrpm*',
        '/dev/sdc /dev/vdc /dev/xvdc',
    );

    return join("\n",
        'mkdir -p /mnt/guix-template-rpm;',
        'rpm_dev=;',
        'for cand in ' . join(' ', @device_candidates) . '; do',
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
    my $serial_output = shell_simple_path(serial_output_path());
    my @files = (
        'diagnose-guix-postinstall-dom0.sh',
        'import-native-rootfs-dom0.sh',
        'test-guix-update-proxy-config-dom0.sh',
        'test-guix-update-proxy-download-dom0.sh',
        'test-guix-update-proxy-stub-download-dom0.sh',
        'test-guix-central-vmupdate-dom0.sh',
        'bootstrap-qubes-update-target-dom0.sh',
        'test-native-guix-template-dom0.sh',
    );

    push @files, 'python3-nose2.rpm'
        if get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1';
    push @files, 'core-admin-guix-vmupdate.tgz'
        if get_var('GUIX_CORE_ADMIN_BACKEND', '0') eq '1';

    my $file_words = join(' ', map { shell_quote($_) } @files);
    my $copy_files = join("\n",
        'echo "RPM asset contents:";',
        'find /mnt/guix-template-rpm -maxdepth 2 -mindepth 1 -printf "%y %p\n" | sort;',
        'for f in ' . $file_words . '; do',
        'test -r "/mnt/guix-template-rpm/$f" || { echo "missing RPM asset file: $f"; exit 1; }',
        'cp "/mnt/guix-template-rpm/$f" "/root/$f";',
        'chmod 0700 "/root/$f";',
        'done;');

    record_info('stage', 'Copying helper files from attached RPM asset disk');
    dom0_assert_script_run(checked_shell_command(join("\n",
        '{',
        rpm_asset_mount_command($rpm_device),
        $copy_files,
        '} 2>&1 | tee ' . $serial_output)),
        timeout => 300);
}

sub wait_for_dom0_serial_login {
    my $timeout = get_var('QUBES_LOGIN_TIMEOUT', 1200);

    record_info('boot', "Waiting up to $timeout seconds for dom0 serial login");
    # Dom0 audit output can interleave with the serial getty prompt in nested
    # runs, splitting "dom0 login:" across unrelated log text.
    wait_serial(qr/login:/i, timeout => $timeout)
        or die "dom0 serial login prompt did not appear within $timeout seconds";
}

sub dom0_wait_for_qubes_cli {
    my $deadline = time + 300;

    record_info('dom0', 'Waiting for qvm-ls to return before staging template assets');
    while (time < $deadline) {
        my $status = dom0_script_run('qvm-ls --raw-list', timeout => 90, quiet => 1);
        return if defined $status && $status == 0;
        sleep 10;
    }

    die "qvm-ls did not return before timeout";
}

sub install_core_admin_guix_backend {
    my $serial_output = shell_simple_path(serial_output_path());
    my $patch_core_admin_cmd = join("\n",
        'set -eu',
        'python3 - <<\'PY\'',
        'import importlib',
        'import importlib.util',
        'import os',
        'import pathlib',
        'import shutil',
        'import sys',
        'import tarfile',
        '',
        'agent_spec = importlib.util.find_spec("vmupdate.agent")',
        'assert agent_spec is not None, "vmupdate.agent package not found"',
        'agent_dirs = list(agent_spec.submodule_search_locations or [])',
        'assert agent_dirs, "vmupdate.agent package has no source directory"',
        'agent_dir = pathlib.Path(agent_dirs[0])',
        'agent_dir_real = agent_dir.resolve()',
        'archive_path = pathlib.Path("/root/core-admin-guix-vmupdate.tgz")',
        'assert archive_path.is_file(), f"missing {archive_path}"',
        '',
        'with tarfile.open(archive_path, "r:gz") as archive:',
        '    for member in archive.getmembers():',
        '        target = (agent_dir / member.name).resolve()',
        '        assert target == agent_dir_real or str(target).startswith(str(agent_dir_real) + os.sep), member.name',
        '    archive.extractall(agent_dir)',
        '',
        'source_dir = agent_dir / "source"',
        'guix_dir = source_dir / "guix"',
        'for path in (agent_dir, source_dir, guix_dir):',
        '    shutil.rmtree(path / "__pycache__", ignore_errors=True)',
        '',
        'sys.path.insert(0, str(agent_dir))',
        'package_manager = importlib.import_module("source.common.package_manager")',
        'assert hasattr(package_manager, "AgentType")',
        'guix_cli = importlib.import_module("source.guix.guix_cli")',
        'assert guix_cli.GUIXCLI.CHANNELS_FILE == "/etc/guix/channels.scm"',
        'assert "/run/qubes/bin/guix" not in guix_cli.GUIXCLI.GUIX_CANDIDATES',
        'print(f"patched full core-admin Guix vmupdate agent: {agent_dir}")',
        'PY');

    dom0_assert_script_run(checked_shell_command(join("\n",
        '{',
        $patch_core_admin_cmd,
        '} 2>&1 | tee ' . $serial_output)),
        timeout => 120);
}

sub run {
    my ($self) = @_;

    my $template = get_var('GUIX_TEMPLATE_NAME', 'guix-openqa-test');
    my $appvm = get_var('GUIX_APPVM_NAME', 'guix-openqa-test-app');
    my $appvm_netvm = get_var('GUIX_APPVM_NETVM', '');
    my $serial_output = shell_simple_path(serial_output_path());
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
    prepare_serial_output_path();

    dom0_assert_script_run(':', timeout => 60, attempts => 3);
    dom0_wait_for_qubes_cli();

    if ($install_mode eq 'rpm') {
        stage_rpm_asset_files($rpm_device);
    } else {
        stage_data_file('import-native-rootfs-dom0.sh', '/root/import-native-rootfs-dom0.sh');
        stage_data_file('test-native-guix-template-dom0.sh', '/root/test-native-guix-template-dom0.sh');
        stage_data_file('test-guix-update-proxy-config-dom0.sh', '/root/test-guix-update-proxy-config-dom0.sh');
        stage_data_file('test-guix-update-proxy-download-dom0.sh', '/root/test-guix-update-proxy-download-dom0.sh');
        stage_data_file('test-guix-update-proxy-stub-download-dom0.sh', '/root/test-guix-update-proxy-stub-download-dom0.sh');
        stage_data_file('test-guix-central-vmupdate-dom0.sh', '/root/test-guix-central-vmupdate-dom0.sh');
        stage_data_file('bootstrap-qubes-update-target-dom0.sh', '/root/bootstrap-qubes-update-target-dom0.sh');
        stage_data_file('diagnose-guix-postinstall-dom0.sh', '/root/diagnose-guix-postinstall-dom0.sh');
        if (get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1') {
            stage_data_file('python3-nose2.rpm', '/root/python3-nose2.rpm');
        }
        if (get_var('GUIX_CORE_ADMIN_BACKEND', '0') eq '1') {
            stage_data_file('core-admin-guix-vmupdate.tgz', '/root/core-admin-guix-vmupdate.tgz');
        }
    }

    if (get_var('GUIX_CORE_ADMIN_BACKEND', '0') eq '1') {
        install_core_admin_guix_backend();
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

    my @root_device_candidates = grep { defined } (
        shell_word_safe_for_vnc($root_device),
        '/dev/disk/by-id/*guixroot*',
        '/dev/sdb /dev/vdb /dev/xvdb',
    );
    my $resolve_device = join("\n",
        'root_dev=;',
        'expected_bytes=' . shell_quote($root_bytes) . ';',
        'for cand in ' . join(' ', @root_device_candidates) . '; do',
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
            'if grep -q -i "qubes[.]postinstall service failed" /root/openqa-guix-import.log; then',
            '/root/diagnose-guix-postinstall-dom0.sh ' . shell_quote($template) . ' 2>&1 | tee /root/openqa-guix-postinstall-diagnostics.log;',
            'fi');
        dom0_assert_script_run(checked_shell_command($postinstall_diag_cmd), timeout => 900);
        my $postinstall_status = dom0_script_run(checked_shell_command(
            '! grep -q -i -e "permissionerror" -e "failed to set default application list" -e "qubes[.]postinstall service failed" /root/openqa-guix-import.log'),
            timeout => 60);
        if (!defined $postinstall_status || $postinstall_status != 0) {
            upload_dom0_logs();
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

    if (get_var('GUIX_BOOTSTRAP_UPDATE_TARGET', '0') eq '1') {
        die "GUIX_BOOTSTRAP_UPDATE_TARGET=1 requires GUIX_INSTALL_MODE=rpm"
            unless $install_mode eq 'rpm';
        my $bootstrap_update_target_invocation = join(' ',
            '/root/bootstrap-qubes-update-target-dom0.sh',
            '--target', shell_quote(get_var('GUIX_UPDATE_TARGET_NAME', 'sys-net')),
            '--network-mode', shell_quote(get_var('GUIX_UPDATE_TARGET_NETWORK_MODE', 'auto')),
            '--template-rpm "$update_target_rpm"',
            '2>&1 | tee /root/openqa-guix-update-target-bootstrap.log ' . $serial_output);
        my $bootstrap_update_target_cmd = join("\n",
            rpm_asset_mount_command($rpm_device),
            'update_target_rpm="$(find /mnt/guix-template-rpm/update-target -maxdepth 1 -type f -name ' . shell_quote('qubes-template-*.rpm') . ' -print -quit)";',
            '[ -n "$update_target_rpm" ];',
            $bootstrap_update_target_invocation);
        my $bootstrap_update_target_status = dom0_script_run(checked_shell_command($bootstrap_update_target_cmd), timeout => 1800);
        if (!defined $bootstrap_update_target_status || $bootstrap_update_target_status != 0) {
            upload_dom0_logs();
            die "Qubes update target bootstrap failed";
        }
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

    my $appvm_netvm_arg = '';
    if (length $appvm_netvm) {
        $appvm_netvm_arg = '--appvm-netvm ' . shell_quote($appvm_netvm);
    }

    my $test_cmd = join(' ',
        get_var('GUIX_RUN_QUBES_SYSTEM_TESTS', '0') eq '1'
            ? 'GUIX_NOSE2_RPM=/root/python3-nose2.rpm QUBES_DOM0_TEST_USER=' . shell_quote($testapi::username)
            : '',
        '/root/test-native-guix-template-dom0.sh',
        '--template', shell_quote($template),
        '--appvm', shell_quote($appvm),
        $appvm_netvm_arg,
        $command_checks,
        $desktop_checks,
        $system_tests,
        '2>&1 | tee /root/openqa-guix-smoke.log ' . $serial_output);
    my $smoke_status = dom0_script_run(checked_shell_command($test_cmd), timeout => $test_timeout);
    if (!defined $smoke_status || $smoke_status != 0) {
        upload_dom0_logs();
        die "native Guix TemplateVM smoke test failed";
    }

    my $proxy_config_cmd = join(' ',
        '/root/test-guix-update-proxy-config-dom0.sh',
        '--template', shell_quote($template),
        '2>&1 | tee /root/openqa-guix-update-proxy-config.log ' . $serial_output);
    my $proxy_config_status = dom0_script_run(checked_shell_command($proxy_config_cmd), timeout => 900);
    if (!defined $proxy_config_status || $proxy_config_status != 0) {
        upload_dom0_logs();
        die "Guix update proxy config check failed";
    }

    if (get_var('GUIX_RUN_PROXY_STUB_DOWNLOAD_TEST', '0') eq '1') {
        my $proxy_stub_download_cmd = join(' ',
            '/root/test-guix-update-proxy-stub-download-dom0.sh',
            '--template', shell_quote($template),
            '--download-url', shell_quote(get_var('GUIX_PROXY_STUB_DOWNLOAD_URL', 'http://qubes-guix-test/')),
            '--timeout', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_TIMEOUT', '240')),
            '2>&1 | tee /root/openqa-guix-update-proxy-stub-download.log ' . $serial_output);
        my $proxy_stub_download_status = dom0_script_run(checked_shell_command($proxy_stub_download_cmd), timeout => 1200);
        if (!defined $proxy_stub_download_status || $proxy_stub_download_status != 0) {
            upload_dom0_logs();
            die "Guix update proxy stub download check failed";
        }
    }

    if (get_var('GUIX_RUN_PROXY_DOWNLOAD_TEST', '0') eq '1') {
        my $proxy_download_cmd = join(' ',
            '/root/test-guix-update-proxy-download-dom0.sh',
            '--template', shell_quote($template),
            '--download-url', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_URL', 'https://guix.gnu.org/')),
            '--timeout', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_TIMEOUT', '240')),
            '2>&1 | tee /root/openqa-guix-update-proxy-download.log ' . $serial_output);
        my $proxy_download_status = dom0_script_run(checked_shell_command($proxy_download_cmd), timeout => 900);
        if (!defined $proxy_download_status || $proxy_download_status != 0) {
            upload_dom0_logs();
            die "Guix update proxy download check failed";
        }
    }

    if (get_var('GUIX_RUN_CENTRAL_VMUPDATE_TEST', '0') eq '1') {
        my $central_vmupdate_cmd = join(' ',
            '/root/test-guix-central-vmupdate-dom0.sh',
            '--template', shell_quote($template),
            '--timeout', shell_quote(get_var('GUIX_CENTRAL_VMUPDATE_TIMEOUT', '3600')),
            '--proxy-probe-url', shell_quote(get_var('GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL', 'https://git.savannah.gnu.org/git/guix.git')),
            '--log-dir', shell_quote('/root/openqa-guix-central-vmupdate'),
            '2>&1 | tee /root/openqa-guix-central-vmupdate.log ' . $serial_output);
        my $central_vmupdate_status = dom0_script_run(checked_shell_command($central_vmupdate_cmd), timeout => get_var('GUIX_CENTRAL_VMUPDATE_TIMEOUT', '3600') + 600);
        if (!defined $central_vmupdate_status || $central_vmupdate_status != 0) {
            upload_dom0_logs();
            die "Guix central vmupdate check failed";
        }
    }

    dom0_assert_script_run('timeout 60 qvm-ls --raw-list | grep -Fx ' . shell_quote($template), timeout => 90);
    upload_dom0_logs();
}

sub test_flags {
    return {fatal => 1};
}

1;
