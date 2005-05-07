#!/usr/bin/perl

# $Revision: 1.1 $

use strict;
use Test::More;

use File::Temp qw( tempdir );
use IO::File;

plan tests => 38;

use_ok("Mozilla::ProfilesIni", 0.01);

my $TmpDir = tempdir( CLEANUP => 1 );

{
  ok(Mozilla::ProfilesIni::_catdir($TmpDir), "_catdir");
  my $NoTmp;
  my $i = 0;
  while (-d ($NoTmp = File::Spec->catdir($TmpDir,sprintf("tmp%05d",$i++)))) {
    print "\x23 looking for non-existent dirname $NoTmp\n";
    die "cannot find a non-existent subdir in a new temp dir" if ($i>10);
  }
  ok(!Mozilla::ProfilesIni::_catdir($NoTmp), "!_catdir");
}

{
  my $tmpfile = File::Spec->catfile($TmpDir, "test");
  my $fh = IO::File->new( ">$tmpfile");
  $fh->close;
  if (-e $tmpfile) {
    ok(Mozilla::ProfilesIni::_catfile($TmpDir, "test"), "_catfile");
  }
  else {
    die "File $tmpfile was not created";
  }
  ok(!Mozilla::ProfilesIni::_catfile($TmpDir, "testnot"), "!_catfile");
}

{
  my $ini;
  eval { $ini = Mozilla::ProfilesIni->new( path => $TmpDir ); };
  ok(!$ini, "no profiles.ini");

  $ini = Mozilla::ProfilesIni->new( path => $TmpDir, create => 1 );
  ok($ini, "create profiles.ini");

  ok(-r $ini->ini_file, "ini file exists");

  ok(!($ini->profile_names), "no profiles in ini yet");

  ok(!$ini->profile_exists("default"), "no default profile");

  $ini->create_profile("default");

  ok(($ini->profile_names), "new profile in ini");

  ok($ini->profile_exists("default"), "profile_exists");
  ok(-d $ini->profile_path("default"), "profile_path");  
  ok($ini->profile_is_relative("default"), "profile_is_relative");
  ok($ini->profile_is_default("default"), "profile_is_default");
  ok(!$ini->profile_is_locked("default"), "profile_is_locked");
  ok($ini->profile_id("default") =~ /^Profile(\d+)$/,
     "profile_id");
  
  ok($ini->profile_exists(name => "default"), "profile_exists (named)");
  ok(-d $ini->profile_path(name => "default"), "profile_path (named)");  
  ok($ini->profile_is_relative(name => "default"),
     "profile_is_relative (named)");
  ok($ini->profile_is_default(name => "default"),
     "profile_is_default (named)");
  ok(!$ini->profile_is_locked(name => "default"), "profile_is_locked (named)");
  ok($ini->profile_id(name => "default") =~ /^Profile(\d+)$/,
     "profile_id (named)");

}

{
  # Retry tests, only with not overwriting an existing profile!

  my $ini = Mozilla::ProfilesIni->new( path => $TmpDir );
  ok($ini, "create profiles.ini");

  ok(-r $ini->ini_file, "ini file exists");
  ok(($ini->profile_names), "profile_names");

  ok($ini->profile_exists("default"), "profile_exists");
  ok(-d $ini->profile_path("default"), "profile_path");

  print STDERR "\x23 " . $ini->profile_path("default") . "\n";
  
  ok($ini->profile_is_relative("default"), "profile_is_relative");
  ok($ini->profile_is_default("default"), "profile_is_default");
  ok(!$ini->profile_is_locked("default"), "profile_is_locked");
  ok($ini->profile_id("default") =~ /^Profile(\d+)$/,
     "profile_id");
  
  ok($ini->profile_exists(name => "default"), "profile_exists (named)");
  ok(-d $ini->profile_path(name => "default"), "profile_path (named)");  
  ok($ini->profile_is_relative(name => "default"),
     "profile_is_relative (named)");
  ok($ini->profile_is_default(name => "default"),
     "profile_is_default (named)");
  ok(!$ini->profile_is_locked(name => "default"), "profile_is_locked (named)");
  ok($ini->profile_id(name => "default") =~ /^Profile(\d+)$/,
     "profile_id (named)");

}
