#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d -p "$repo_root" .openqa-perl-check.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$workdir/lib/Mojo"

cat >"$workdir/lib/testapi.pm" <<'PERL'
package testapi;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(
    assert_and_click assert_screen assert_script_run autoinst_url check_screen
    check_var get_required_var get_var match_has_tag mouse_hide mouse_set
    record_info save_screenshot save_tmp_file script_output script_run
    select_console send_key set_var sleep type_password type_string upload_logs
    wait_serial wait_still_screen $password $serialdev $username
);
our ($serialdev, $username, $password);

sub assert_screen { return 1; }
sub assert_and_click { return 1; }
sub assert_script_run { return 1; }
sub autoinst_url { return $_[0]; }
sub check_screen { return 0; }
sub check_var { return 0; }
sub get_required_var { return $_[0]; }
sub get_var { return $_[1]; }
sub match_has_tag { return 0; }
sub mouse_hide { return 1; }
sub mouse_set { return 1; }
sub record_info { return 1; }
sub save_screenshot { return 1; }
sub save_tmp_file { return 1; }
sub script_output { return ""; }
sub script_run { return 0; }
sub select_console { return 1; }
sub send_key { return 1; }
sub set_var { return 1; }
sub type_password { return 1; }
sub type_string { return 1; }
sub upload_logs { return 1; }
sub wait_serial { return 1; }
sub wait_still_screen { return 1; }

1;
PERL

cat >"$workdir/lib/installedtest.pm" <<'PERL'
package installedtest;
use strict;
use warnings;
use base 'basetest';

sub select_gui_console { return 1; }
sub upload_packages_versions { return 1; }
sub save_and_upload_log { return 1; }

1;
PERL

cat >"$workdir/lib/basetest.pm" <<'PERL'
package basetest;
use strict;
use warnings;

sub new { return bless {}, shift; }
sub run { return 1; }

1;
PERL

cat >"$workdir/lib/networking.pm" <<'PERL'
package networking;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(become_root curl_via_netvm enable_dom0_network_netvm x11_start_program);

sub become_root { return 1; }
sub curl_via_netvm { return 1; }
sub enable_dom0_network_netvm { return 1; }
sub x11_start_program { return 1; }

1;
PERL

cat >"$workdir/lib/bootloader_setup.pm" <<'PERL'
package bootloader_setup;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(heads_boot_default);

sub heads_boot_default { return 1; }

1;
PERL

cat >"$workdir/lib/serial_terminal.pm" <<'PERL'
package serial_terminal;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(reset_consoles select_root_console);

sub reset_consoles { return 1; }
sub select_root_console { return 1; }

1;
PERL

cat >"$workdir/lib/utils.pm" <<'PERL'
package utils;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(us_colemak colemak_us);

sub us_colemak { return $_[0]; }
sub colemak_us { return $_[0]; }

1;
PERL

cat >"$workdir/lib/Mojo/File.pm" <<'PERL'
package Mojo::File;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(path);

sub path { return bless {path => $_[0]}, 'Mojo::File::Stub'; }

package Mojo::File::Stub;
use strict;
use warnings;

sub slurp { return ""; }
sub to_string { return $_[0]->{path}; }

1;
PERL

cat >"$workdir/lib/qubesdistribution.pm" <<'PERL'
package qubesdistribution;
use strict;
use warnings;

sub init { return 1; }
sub activate_console { return 1; }
sub console_selected { return 1; }

1;
PERL

if [ -d "$repo_root/.cache/openqa-tests-qubesos/tests" ]; then
    mkdir -p "$workdir/patched-official/tests"
    mkdir -p "$workdir/patched-official/lib"
    mkdir -p "$workdir/patched-official/extra-files/update"
    cp "$repo_root/.cache/openqa-tests-qubesos/lib/installedtest.pm" \
        "$workdir/patched-official/lib/installedtest.pm"
    cp "$repo_root/.cache/openqa-tests-qubesos/tests/update2.pm" \
        "$workdir/patched-official/tests/update2.pm"
    cp "$repo_root/.cache/openqa-tests-qubesos/tests/switch_template.pm" \
        "$workdir/patched-official/tests/switch_template.pm"
    cp "$repo_root/.cache/openqa-tests-qubesos/extra-files/update/zsystemtests.py" \
        "$workdir/patched-official/extra-files/update/zsystemtests.py"
    patch -d "$workdir/patched-official" -p0 \
        <"$repo_root/openqa/qubesos/patches/startup-recover-sys-net-before-gui.patch" \
        >/dev/null
    patch -d "$workdir/patched-official" -p0 \
        <"$repo_root/openqa/qubesos/patches/installedtest-bounded-log-uploads.patch" \
        >/dev/null
    patch -d "$workdir/patched-official" -p0 \
        <"$repo_root/openqa/qubesos/patches/update2-guix-sequential-vmupdate.patch" \
        >/dev/null
    patch -d "$workdir/patched-official" -p0 \
        <"$repo_root/openqa/qubesos/patches/switch-template-running-dispvms.patch" \
        >/dev/null
    patch -d "$workdir/patched-official" -p0 \
        <"$repo_root/openqa/qubesos/patches/zsystemtests-guix-no-package-install.patch" \
        >/dev/null
    grep -Fq '$self->recover_sys_net;' \
        "$workdir/patched-official/lib/installedtest.pm"
    grep -Fq 'net_bdf="$(for dev in /sys/bus/pci/devices/*' \
        "$workdir/patched-official/lib/installedtest.pm"
    grep -Fq 'GUIX_FAILOK_LOG_UPLOADS' \
        "$workdir/patched-official/lib/installedtest.pm"
    grep -Fq 'os_data["os_family"] == "Guix"' \
        "$workdir/patched-official/extra-files/update/zsystemtests.py"
    perl -I"$workdir/lib" -c "$workdir/patched-official/lib/installedtest.pm"
    perl -I"$workdir/lib" -c "$workdir/patched-official/tests/update2.pm"
    perl -I"$workdir/lib" -c "$workdir/patched-official/tests/switch_template.pm"
    python3 -m py_compile \
        "$workdir/patched-official/extra-files/update/zsystemtests.py"
fi

perl -I"$workdir/lib" -I"$repo_root/openqa/qubesos/lib" \
    -c "$repo_root/openqa/qubesos/lib/guixdom0distribution.pm"
perl -I"$workdir/lib" -I"$repo_root/openqa/qubesos/lib" \
    -c "$repo_root/openqa/qubesos/tests/guix_template.pm"

printf 'openQA Perl syntax check passed\n'
