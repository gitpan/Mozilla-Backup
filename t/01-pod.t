#!/usr/bin/perl

# $Revision: 1.1 $

use strict;
use Test::More;

eval "use Test::Pod 1.00";

plan skip_all => "Test::Pod 1.00 required" if $@;

my @poddirs = qw( blib  );

all_pod_files_ok( all_pod_files( @poddirs ) );
