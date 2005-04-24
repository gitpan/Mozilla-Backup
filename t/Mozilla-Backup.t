#!/usr/bin/perl

# $Revision: 1.13 $

use strict;
use Test::More tests => 15;

use File::Temp qw( tempdir );

use_ok("Mozilla::Backup");

my $tmpdir = tempdir( CLEANUP => 1 );

my $moz = new Mozilla::Backup();
ok(defined $moz, "new (no options)");

$moz = new Mozilla::Backup(
  pseudo => $tmpdir,
  debug  => 0,
  plugin => [ 'Mozilla::Backup::Plugin::Zip', compression => 6 ],
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

    my @profs = $moz->type($type)->profile_names();
    ok(@profs, "$type profile_names");

    ok(-r $moz->type($type)->ini_file, "ini_file");

    my $name  = $profs[0];
    ok($moz->type($type)->profile_exists($name), "$name profile exists");

    skip "No profile found for type", 7
      unless ($moz->type($type)->profile_exists($name));

    ok(-d $moz->type($type)->profile_path($name), "profile_path");

    ok(defined $moz->type($type)->profile_is_relative($name), "profile_is_relative");

    ok($moz->type($type)->profile_id($name), "profile_id");

    my $arch = $moz->_archive_name($type,$name);
    ok($arch =~ /^$type\-$name\-\d{8}\-\d{6}\.zip$/, "archive_name");

    skip "profile is locked", 3
      if ($moz->type($type)->profile_is_locked($name));

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
	if ($moz->type("pseudo")->profile_exists($restored));

      $moz->restore_profile($file, "pseudo", $restored);

      my $rest_path = $moz->type($type)->profile_path($restored);
      ok(-d $rest_path, "restore path exists");

      # TODO - test that files are extracted?

    }

  }
}
