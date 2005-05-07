#!/usr/bin/perl

# Test script for pseudo-profile. This allows us to test a lot of functions
# which manipulate profiles, but to test them in a safe place.

# $Revision: 1.5 $

use strict;
use Test::More;

use File::Temp qw( tempdir );

plan tests => 14;

use_ok("Mozilla::Backup", 0.05);

my $PseudoDir = tempdir( CLEANUP => 1 );
ok(-d $PseudoDir, "pseudo dir exists");
ok(-d Mozilla::Backup::_catdir($PseudoDir), "_catdir");

my $moz = Mozilla::Backup->new(
  debug  => 1,
  pseudo => $PseudoDir,
);
ok(defined $moz, "new()");

my %Types = map { $_ => 1, } ($moz->found_profile_types);

ok(keys %Types, "found_profile_types");

ok($moz->type_exists( type => "pseudo" ), "type_exists (named)");
ok($moz->type_exists( "pseudo" ), "type_exists (positional)");
ok($Types{pseudo} && $moz->type_exists( type => "pseudo" ),
 "type_exists corresponds with found_profile_types");

my $ProfilesDir = Mozilla::Backup::_catdir($PseudoDir, "Profiles");
ok(-d $ProfilesDir, "Profiles subdir");

SKIP: {
  skip "NA in Windows", 1 if ($^O eq "MSWin32");
  my $mode = (stat($ProfilesDir))[2] & 07777;
#  printf STDERR "\x23 %04o\n", $mode;
  ok($mode == 0700, "Profiles perms");
}

ok($moz->type_exists( type => "pseudo" ), "type_exists (named)");
ok($moz->type_exists( "pseudo" ), "type_exists (positional)");

my $IniFile =  Mozilla::Backup::_catfile($PseudoDir, "profiles.ini");
ok(-r $IniFile, "_catfile profiles.ini");
ok( $IniFile eq $moz->type("pseudo")->ini_file,
    "ini_file" );

# TODO - revamp these tests now that we've changed the interface!!


