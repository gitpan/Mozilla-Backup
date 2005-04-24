#!/usr/bin/perl

use strict;
use Test::More;

eval "use Test::Portability::Files";

plan skip_all => "Test::Portability::Files required for testing filenames portability" if $@;

options( test_mac_length => 0 );

run_tests();
