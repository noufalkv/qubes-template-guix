# SPDX-License-Identifier: GPL-3.0-or-later
package guixdom0distribution;

use strict;
use warnings;

require 'qubesdistribution.pm';
use parent -norequire, 'qubesdistribution';

use testapi qw(get_var type_password type_string wait_serial);

sub init {
    my ($self) = @_;
    $self->SUPER::init();
    $testapi::username = get_var('QUBES_DOM0_USER', 'user');
    $testapi::password = get_var('QUBES_DOM0_PASSWORD', 'qubes');
}

sub activate_console {
    my ($self, $console) = @_;

    if ($console eq 'root-virtio-terminal') {
        my $prompt = 'root# ';
        my $timeout = get_var('QUBES_LOGIN_TIMEOUT', 900);
        $testapi::password = get_var('QUBES_DOM0_PASSWORD', 'qubes');
        $self->{serial_term_prompt} = $prompt;

        type_string("\n");
        my $login = wait_serial(qr/login:|root@.*#|\Q$prompt\E/i, timeout => $timeout);
        die "root serial login prompt did not appear within $timeout seconds" unless $login;

        if ($login =~ m/login:\s*$/i) {
            type_string("root\n");
            wait_serial(qr/Passwor[dt]:/i, timeout => 60);
            type_password();
            type_string("\n");
        }

        type_string(qq/PS1="$prompt"\n/);
        wait_serial(qr/PS1="\Q$prompt\E"/, timeout => 60);
        type_string("export TERM=dumb; stty cols 2048 rows 25\n");
        wait_serial(qr/\Q$prompt\E/, timeout => 60);
        return;
    }

    return $self->SUPER::activate_console($console);
}

1;
