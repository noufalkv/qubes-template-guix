# SPDX-License-Identifier: GPL-3.0-or-later
package guixdom0distribution;

use strict;
use warnings;

require 'qubesdistribution.pm';
use parent -norequire, 'qubesdistribution';

use testapi qw(assert_screen get_var match_has_tag send_key type_password type_string wait_serial);

sub init {
    my ($self) = @_;
    $self->SUPER::init();
    $testapi::username = get_var('QUBES_DOM0_USER', 'user');
    $testapi::password = get_var('QUBES_DOM0_PASSWORD', 'qubes');
}

sub activate_console {
    my ($self, $console) = @_;

    if ($console eq 'root-console') {
        $testapi::password = get_var('QUBES_DOM0_PASSWORD', 'qubes');

        assert_screen ['tty3-selected', 'text-logged-in-root', 'text-login'], 60;
        if (match_has_tag('tty3-selected') || match_has_tag('text-login')) {
            type_string("root\n");
            assert_screen 'password-prompt', 30;
            type_password();
            send_key('ret');
        }
        assert_screen 'text-logged-in-root', 60;
        type_string("\n", max_interval => 100);
        sleep 2;
        type_string("export TERM=dumb; PS1='root# '\n", max_interval => 100);
        sleep 2;
        return;
    }

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

sub console_selected {
    my ($self, $console, %args) = @_;

    return if $console eq 'root-console';
    return $self->SUPER::console_selected($console, %args);
}

1;
