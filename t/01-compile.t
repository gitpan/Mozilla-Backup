#!/usr/bin/perl

# $Revision: 1.6 $

use strict;
use Test::More;

my %MODULES = (
  'Mozilla::Backup'                   => 0.06,
  'Mozilla::ProfilesIni'              => 0.01,
  'Mozilla::Backup::Plugin::Zip'      => 0.03,
  'Mozilla::Backup::Plugin::FileCopy' => 0.03,
  'Mozilla::Backup::Plugin::Tar'      => 0.01,
);

plan tests => scalar(keys %MODULES);

foreach my $module (sort keys %MODULES) {
  my $version = $MODULES{$module};
  use_ok($module,$version);
}

