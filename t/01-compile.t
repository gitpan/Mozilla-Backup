#!/usr/bin/perl

# $Revision: 1.1 $

use strict;
use Test::More;

my %MODULES = (
  'Mozilla::Backup'                   => 0.04,
  'Mozilla::Backup::Plugin::Zip'      => 0.01,
  'Mozilla::Backup::Plugin::FileCopy' => 0.01,
);

plan tests => scalar(keys %MODULES);

foreach my $module (sort keys %MODULES) {
  my $version = $MODULES{$module};
  use_ok($module,$version);
}

