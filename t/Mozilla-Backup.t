#!/usr/bin/perl

# $Revision: 1.11 $

use strict;
use Test::More tests => 15;

use File::Temp qw( tempdir );

use_ok("Mozilla::Backup");

my $tmpdir = tempdir( CLEANUP => 1 );

my $moz = new Mozilla::Backup();
ok(defined $moz, "new (no options)");

$moz = new Mozilla::Backup(
  pseudo => $tmpdir,
  debug => 0,
);
ok(defined $moz, "new");


my @all   = $moz->profile_types;
ok(@all, "profile_types");


my %types = map { $_ => 1 } ($moz->found_profile_types);

# Hm. Should this fail if no profiles found?

SKIP: {
  skip "No profiles found", 1 unless (keys %types);
  ok(%types, "found_profile_types");
}

my $prof_name = 0;

foreach my $type (qw( pseudo )) {

 SKIP: {
    skip "No $type profiles found", 10 unless ($moz->type_exists($type));

    my @profs = $moz->profile_names($type);
    ok(@profs, "$type profile_names");

    ok(-r $moz->ini_file($type), "ini_file");

    my $name  = $profs[0];
    ok($moz->profile_exists($type,$name), "$name profile exists");

    skip "No profile found for type", 7
      unless ($moz->profile_exists($type,$name));

    ok(-d $moz->profile_path($type,$name), "profile_path");

    ok(defined $moz->profile_is_relative($type,$name), "profile_is_relative");

    ok($moz->profile_id($type,$name), "profile_id");

    my $arch = $moz->_archive_name($type,$name);
    ok($arch =~ /^$type\-$name\-\d{8}\-\d{6}\.zip$/, "archive_name");

    skip "profile is locked", 3 if ($moz->profile_is_locked($type,$name));

    my $file = $moz->backup_profile($type,$name,$tmpdir,$arch);
    ok(-e $file, "backup_profile");

    my $verify = File::Spec->catfile($tmpdir,$arch);
    ok(-e $verify, "file is where expected to be");

    # TODO - test that it is a valid zip file,
    #      - test that it does not have files that were excluded
    #        (such as Cache, etc.)
    #      - test that it is relative vs. absolute as appropriate
    #      - test separate backup that is opposite of profile_is_relative

    my $restored = sprintf("test%04d", ++$prof_name);

    SKIP : {
      skip "$restored profile exists", 1
	if ($moz->profile_exists("pseudo", $restored));

      $moz->restore_profile($file, "pseudo", $restored);

      my $rest_path = $moz->profile_path("pseudo", $restored);
      ok(-d $rest_path, "restore path exists");

      # TODO - test that files are extracted?

    }

  }
}
