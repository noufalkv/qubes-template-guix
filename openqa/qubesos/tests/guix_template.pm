# SPDX-License-Identifier: GPL-3.0-or-later
use strict;
use warnings;

use base 'basetest';
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use testapi qw(get_var record_info select_console send_key type_string upload_logs wait_serial);

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

sub positive_int_var {
    my ($name, $default) = @_;
    my $value = get_var($name, $default);

    die "$name must be a positive integer" unless defined $value && $value =~ /\A[1-9][0-9]*\z/;
    return $value;
}

sub enabled_var {
    my ($name) = @_;
    my $value = get_var($name, '0');

    die "$name must be 0 or 1" unless defined $value && $value =~ /\A[01]\z/;
    return $value eq '1';
}

sub validate_git_commit {
    my ($name, $value) = @_;

    die "$name must be a full 40-hex Git commit"
        if length $value && $value !~ /\A[0-9a-fA-F]{40}\z/;
}

sub shell_simple_path {
    my ($path) = @_;
    die "unsupported serial output path: $path" unless $path =~ m{\A/[A-Za-z0-9_./-]+\z};
    return $path;
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
        'tar --create --gzip --file /root/openqa-guix-logs.tgz --ignore-failed-read /root/openqa-guix-*.log /root/openqa-guix-central-vmupdate* 2>/dev/null || true',
        timeout => 120);
    upload_logs('/root/openqa-guix-logs.tgz', failok => 1);
}

sub dom0_run_or_upload {
    my ($cmd, $timeout, $failure) = @_;
    my $status = dom0_script_run(checked_shell_command($cmd), timeout => $timeout);

    return if defined $status && $status == 0;
    upload_dom0_logs();
    die $failure;
}

sub append_serial_heredoc {
    my ($dest, $content) = @_;
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
    my ($content, $dest, $mode) = @_;
    my $sha256 = sha256_hex($content);
    my $b64 = encode_base64($content, '');
    my @lines = ($b64 =~ /.{1,76}/g);
    my $b64_dest = "$dest.b64";
    my $tmp_dest = "$dest.tmp";
    my $lines_per_chunk = positive_int_var('QUBES_DOM0_B64_LINES_PER_CHUNK', 8);
    my $transfer_attempts = positive_int_var('QUBES_DOM0_B64_TRANSFER_ATTEMPTS', 3);

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
            append_serial_heredoc($b64_dest, join("\n", @chunk) . "\n");
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

    stage_dom0_file_b64($content, $script_path, '0700');
    return $script_path;
}

sub rpm_asset_mount_command {
    my ($rpm_device) = @_;
    my @device_candidates = grep { defined } (
        defined $rpm_device && length $rpm_device ? shell_quote($rpm_device) : undef,
        '/dev/disk/by-id/*guixrpm*',
        '/dev/sdb /dev/vdb /dev/xvdb /dev/sdc /dev/vdc /dev/xvdc',
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
    my $copy_files = join("\n",
        'echo "RPM asset contents:";',
        'find /mnt/guix-template-rpm -maxdepth 2 -mindepth 1 -printf "%y %p\n" | sort;',
        'found_helper=0;',
        'for f in /mnt/guix-template-rpm/*.sh; do',
        '[ -e "$f" ] || continue;',
        'found_helper=1;',
        'install -m 0700 "$f" "/root/$(basename "$f")";',
        'done;',
        '[ "$found_helper" = 1 ] || { echo "no helper scripts in RPM asset"; exit 1; }');

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

sub cleanup_guix_vms {
    my ($template, $appvm) = @_;
    my @cleanup_vms = (
        $appvm,
        $template,
        'guix-openqa-test-app',
        'guix-openqa-test',
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
}

sub install_template_rpm {
    my ($rpm_device, $template) = @_;
    my $rpm_install_cmd = join("\n",
        rpm_asset_mount_command($rpm_device),
        'rpm_path="$(find /mnt/guix-template-rpm -maxdepth 1 -type f -name ' . shell_quote('qubes-template-*.rpm') . ' -print -quit)";',
        '[ -n "$rpm_path" ];',
        'cp "$rpm_path" /root/;',
        'rpm_copy="/root/$(basename "$rpm_path")";',
        'qvm-template --yes install --nogpgcheck "$rpm_copy" 2>&1 | tee /root/openqa-guix-import.log');
    my $postinstall_diag_cmd = join("\n",
        'if grep -q -i "qubes[.]postinstall service failed" /root/openqa-guix-import.log; then',
        '/root/diagnose-guix-postinstall-dom0.sh ' . shell_quote($template) . ' 2>&1 | tee /root/openqa-guix-postinstall-diagnostics.log;',
        'fi');
    my $postinstall_status;

    dom0_assert_script_run(checked_shell_command($rpm_install_cmd), timeout => 1800);
    dom0_assert_script_run(checked_shell_command($postinstall_diag_cmd), timeout => 900);

    $postinstall_status = dom0_script_run(checked_shell_command(
        '! grep -q -i -e "permissionerror" -e "failed to set default application list" -e "qubes[.]postinstall service failed" /root/openqa-guix-import.log'),
        timeout => 60);
    if (!defined $postinstall_status || $postinstall_status != 0) {
        upload_dom0_logs();
        die "qvm-template post-install failed";
    }
}

sub run_template_smoke {
    my ($template, $appvm, $appvm_netvm, $test_timeout, $serial_output) = @_;
    my $appvm_netvm_arg = '';

    if (length $appvm_netvm) {
        $appvm_netvm_arg = '--appvm-netvm ' . shell_quote($appvm_netvm);
    }

    my $test_cmd = join(' ',
        '/root/test-native-guix-template-dom0.sh',
        '--template', shell_quote($template),
        '--appvm', shell_quote($appvm),
        $appvm_netvm_arg,
        '2>&1 | tee /root/openqa-guix-smoke.log ' . $serial_output);
    dom0_run_or_upload($test_cmd, $test_timeout, 'native Guix TemplateVM smoke test failed');
}

sub run_update_proxy_checks {
    my ($template, $run_proxy_download, $run_proxy_pull, $serial_output) = @_;
    my @proxy_args = (
        '/root/test-guix-update-proxy-dom0.sh',
        '--template', shell_quote($template));
    my $proxy_cmd_timeout = 900;

    if ($run_proxy_download) {
        my $download_timeout = positive_int_var('GUIX_PROXY_DOWNLOAD_TIMEOUT', 240);
        push @proxy_args,
            '--download',
            '--download-url', shell_quote(get_var('GUIX_PROXY_DOWNLOAD_URL', 'https://guix.gnu.org/')),
            '--timeout', shell_quote($download_timeout);
    }
    if ($run_proxy_pull) {
        my $pull_commit = get_var('GUIX_PROXY_PULL_COMMIT', '');
        my $pull_timeout = positive_int_var('GUIX_PROXY_PULL_TIMEOUT', 3600);
        validate_git_commit('GUIX_PROXY_PULL_COMMIT', $pull_commit);
        push @proxy_args,
            '--pull',
            '--pull-timeout', shell_quote($pull_timeout);
        push @proxy_args, '--pull-commit', shell_quote($pull_commit)
            if length $pull_commit;
        $proxy_cmd_timeout = $pull_timeout + 600
            if $proxy_cmd_timeout < $pull_timeout + 600;
    }
    push @proxy_args, '2>&1 | tee /root/openqa-guix-update-proxy.log ' . $serial_output;
    dom0_run_or_upload(join(' ', @proxy_args), $proxy_cmd_timeout, 'Guix update proxy check failed');
}

sub run_central_vmupdate_check {
    my ($template, $run_central_vmupdate, $serial_output) = @_;
    return unless $run_central_vmupdate;

    my $central_vmupdate_timeout = positive_int_var('GUIX_CENTRAL_VMUPDATE_TIMEOUT', 3600);
    my $central_vmupdate_cmd = join(' ',
        '/root/test-guix-central-vmupdate-dom0.sh',
        '--template', shell_quote($template),
        '--timeout', shell_quote($central_vmupdate_timeout),
        '--proxy-probe-url', shell_quote(get_var('GUIX_CENTRAL_VMUPDATE_PROXY_PROBE_URL', 'https://codeberg.org/guix/guix.git')),
        '--log-dir', shell_quote('/root/openqa-guix-central-vmupdate'),
        '2>&1 | tee /root/openqa-guix-central-vmupdate.log ' . $serial_output);
    dom0_run_or_upload($central_vmupdate_cmd, $central_vmupdate_timeout + 600, 'Guix central vmupdate check failed');
}

sub run {
    my ($self) = @_;

    my $template = get_var('GUIX_TEMPLATE_NAME', 'guix');
    my $appvm = get_var('GUIX_APPVM_NAME', 'guix-openqa-test-app');
    my $appvm_netvm = get_var('GUIX_APPVM_NETVM', '');
    my $serial_output = shell_simple_path(serial_output_path());
    my $rpm_device = get_var('GUIX_TEMPLATE_RPM_DEVICE', '/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_guixrpm');
    my $test_timeout = get_var('GUIX_TEST_TIMEOUT', 3600);
    my $dom0_console = get_var('QUBES_DOM0_CONSOLE', 'root-console');
    my $run_proxy_download = enabled_var('GUIX_RUN_PROXY_DOWNLOAD_TEST');
    my $run_proxy_pull = enabled_var('GUIX_RUN_PROXY_PULL_TEST');
    my $run_central_vmupdate = enabled_var('GUIX_RUN_CENTRAL_VMUPDATE_TEST');

    $testapi::username = get_var('QUBES_DOM0_USER', 'user');
    $testapi::password = get_var('QUBES_DOM0_PASSWORD', 'qubes');

    wait_for_dom0_serial_login() if $dom0_console eq 'root-console';
    select_console($dom0_console);
    record_info('dom0', "Nested Qubes dom0 console is ready: $dom0_console");
    prepare_serial_output_path();

    dom0_assert_script_run(':', timeout => 60, attempts => 3);
    dom0_wait_for_qubes_cli();

    stage_rpm_asset_files($rpm_device);
    cleanup_guix_vms($template, $appvm);
    install_template_rpm($rpm_device, $template);
    run_template_smoke($template, $appvm, $appvm_netvm, $test_timeout, $serial_output);
    run_update_proxy_checks($template, $run_proxy_download, $run_proxy_pull, $serial_output);
    run_central_vmupdate_check($template, $run_central_vmupdate, $serial_output);

    dom0_assert_script_run('timeout 60 qvm-ls --raw-list | grep -Fx ' . shell_quote($template), timeout => 90);
    upload_dom0_logs();
}

sub test_flags {
    return {fatal => 1};
}

1;
