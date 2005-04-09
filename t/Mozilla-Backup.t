#!/usr/bin/perl

use strict;
use Test::More tests => 35;

use File::Temp qw( tempdir );

use_ok("Mozilla::Backup");

my $moz = new Mozilla::Backup();
ok(defined $moz, "new");

my $tmpdir = tempdir( CLEANUP => 1 );

my %types = map { $_ => 1 } ($moz->found_profile_types);

SKIP: {
  skip "No profiles found", 1 unless (keys %types);
  ok(%types, "found_profile_types");
}

foreach my $type (qw( mozilla firefox thunderbird sunbird )) {

 SKIP: {
    skip "No $type profiles found", 8 unless ($types{$type});

    my @profs = $moz->profile_names($type);
    ok(@profs, "$type profile_names");

    ok(-r $moz->ini_file($type), "$type ini_file");

    my $name  = $profs[0];
    ok(-d $moz->profile_path($type,$name), "$type $name profile_path");

    {
      local $TODO = "should be relative";
      ok($moz->profile_is_relative($type,$name), "profile_is_relative");
    }

    ok($moz->profile_section($type,$name), "profile_section");

    my $arch = $moz->_archive_name($type,$name);
    ok($arch =~ /^$type\-$name\-\d{8}\-\d{6}\.zip$/, "archive_name");

    my $file = $moz->backup_profile($type,$name,$tmpdir,$arch);
    ok(-e $file, "backup_profile");

    eval {
      $moz->restore_profile($type,"bogus_profile_name");
    };
    ok($@, "restore_profile fails");

  }
}
