#!/usr/bin/perl

use strict;
use Test::More tests => 94;

use File::Temp qw( tempdir );

use_ok("Mozilla::Backup");

my $moz = new Mozilla::Backup();
ok(defined $moz, "new");

my $tmpdir = tempdir( CLEANUP => 1 );

my @all   = $moz->profile_types;
ok(@all, "profile_types");

my %types = map { $_ => 1 } ($moz->found_profile_types);

SKIP: {
  skip "No profiles found", 1 unless (keys %types);
  ok(%types, "found_profile_types");
}

foreach my $type (@all) {

 SKIP: {
    skip "No $type profiles found", 10 unless ($types{$type});

    my @profs = $moz->profile_names($type);
    ok(@profs, "$type profile_names");

    ok(-r $moz->ini_file($type), "$type ini_file");

    my $name  = $profs[0];
    ok($moz->profile_exists($type,$name), "profile exists");

    ok(-d $moz->profile_path($type,$name), "$type $name profile_path");

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

    eval {
      $moz->restore_profile($type,"bogus_profile_name");
    };
    ok($@, "restore_profile fails");
  }
}
