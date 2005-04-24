#!/usr/bin/perl

use strict;
use Test::More;

eval "use Test::Pod::Coverage";

plan skip_all => "Test::Pod::Coverage required" if $@;


my %MODULES = (
  'Mozilla::Backup'                   => 0,
  'Mozilla::Backup::Plugin::Zip'      => 0,
  'Mozilla::Backup::Plugin::FileCopy' => 0,
  'Mozilla::Backup::Plugin::Tar'      => 0,
  'Mozilla::ProfilesIni'              => 0,
);

plan tests => scalar(keys %MODULES);

foreach my $module (sort keys %MODULES) {
  pod_coverage_ok($module);
}


