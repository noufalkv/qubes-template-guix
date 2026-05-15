# SPDX-License-Identifier: GPL-3.0-or-later
use strict;
use warnings;
use testapi;
use autotest;

require 'guixdom0distribution.pm';

testapi::set_distribution(guixdom0distribution->new());

autotest::loadtest 'tests/guix_template.pm';

1;
