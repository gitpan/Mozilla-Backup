#!/usr/bin/perl

# For testing various "internal" routines and miscellaneos behaviors

# $Revision: 1.2 $

use strict;
use Test::More;

use File::Spec;
use File::Temp qw( tempdir );
use IO::File;

plan tests => 10;

use_ok("Mozilla::Backup", 0.05);

my $TmpDir = tempdir( CLEANUP => 1 );

# Test _catdir and _catfile

ok(Mozilla::Backup::_catdir($TmpDir), "_catdir");

{
  my $NoTmp;
  my $i = 0;
  while (-d ($NoTmp = File::Spec->catdir($TmpDir,sprintf("tmp%05d",$i++)))) {
    print "\x23 looking for non-existent dirname $NoTmp\n";
    die "cannot find a non-existent subdir in a new temp dir" if ($i>10);
  }
  ok(!Mozilla::Backup::_catdir($NoTmp), "!_catdir");
}


{
  my $tmpfile = File::Spec->catfile($TmpDir, "test");
  my $fh = IO::File->new( ">$tmpfile");
  $fh->close;
  if (-e $tmpfile) {
    ok(Mozilla::Backup::_catfile($TmpDir, "test"), "_catfile");
  }
  else {
    die "File $tmpfile was not created";
  }
  ok(!Mozilla::Backup::_catfile($TmpDir, "testnot"), "!_catfile");
}

# TODO - test _find_profile_path behavior (named & positional args)

my $moz = Mozilla::Backup->new();
ok(defined $moz, "new()");

{
  my @types = $moz->profile_types;
  ok(@types, "profile_types");
  ok(!grep(/^pseudo$/, @types), "pseudo not in profile_types");
}

# Test _log. TODO - hook onto dispatcher and verify that logs with no
# newlines have them added, but not in the returned value

ok("test" eq $moz->_log(level => 0, message => "test"), "_log");
ok("test\n" eq $moz->_log(level => 0, message => "test\n"), "_log");


