=head1 NAME

Mozilla::ProfilesIni - Manipulation of Mozilla F<profiles.ini> files

=head1 REQUIREMENTS

The following non-core modules are required:

  Config::IniFiles
  Log::Dispatch
  Params::Smart
  Params::Validate

=head1 SYNOPSIS

  $path = Mozilla::ProfilesIni::_find_profile_path(
    home => $ENV{HOME}, 
    type => "firefox"
  );

  $ini = Mozilla::ProfilesIni->( path => $path );


=head1 DESCRIPTION

This module provides routines for parsing and manipulating Mozilla
F<profiles.ini> files.

The following methods are implemented:

=cut

package Mozilla::ProfilesIni;

require 5.006;

use strict;
use warnings;

# TODO - move much of the Profiles handling code to this module.

use Carp;
use Config::IniFiles;
use File::Find;
use File::Spec;
use Log::Dispatch;
use Params::Smart 0.03;
use Params::Validate qw( :all );

# $Revision: 1.8 $

our $VERSION = '0.01';

=over

=item new

  $ini = Mozilla::ProfilesIni->new( path => $path, %options );

The following options are supported:

=over

=item path

Path to where the F<profiles.ini> file is (excluding the actual
F<profiles.ini> file).

=item log

A L<Log::Dispatch> object for receiving log messages.

=item debug

Sets an internal debug flag. (Not implemented at this time.)

=item create

Create a new F<profile.ini> file in L</path>.

=back

=cut

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = validate( @_, {
    log       => {
                   default  => Log::Dispatch->new,
                   isa      => 'Log::Dispatch',
                 },
    debug     => {
                   default  => 0,
                   type     => BOOLEAN,
                 },
    path      => {
                   required => 1,
                   type     => SCALAR,
                 },
    create    => {
                   default  => 0,
                   type     => BOOLEAN,
                 },
  } );
  
  my $self  = {
    profiles  => { },
  };

  local ($_);

  foreach (qw( log debug create )) {
    $self->{$_} = $args{$_};
  }

  bless $self, $class;

  if ($self->{create}) {
    $self->_create_profile_ini( path => $args{path}, ignore => 1 );
  }

  $self->_read_profile_ini( path => $args{path} );

  return $self;
}

=begin internal

=item _create_profile_ini

  $ini->_create_profile_ini( path => $path, ignore => $ignore );

  $ini->_create_profile_ini( $path );

Creates a new F<profiles.ini> file in C<$path>.

By default it will die if a profiles file already exists, unless the
ignore flag is specified explicitly, in which case it will return
without creating a profile (or complaining).

=end internal

=cut

sub _create_profile_ini {
  my $self = shift;
  my %args = Params(qw( path ?+ignore ))->args(@_);
  my $path = File::Spec->rel2abs($args{path});

  unless (-d $path) {
    croak $self->_log( level => "error",
      message => "cannot access psuedo profile directory: $path" );
  }

  my $ini_file = File::Spec->catfile($path, "profiles.ini" );
  if (-e $ini_file) {
    if ($args{ignore}) {
      return;
    } else {
      croak $self->_log( level => "error",
        message => "a profile exists already at $path" );
    }
  } else {
    my $cfg = Config::IniFiles->new();
    $cfg->AddSection("General");
    $cfg->newval("General", "StartWithLastProfile", "");

    unless ($cfg->WriteConfig( $ini_file )) {
      croak $self->_log( level => "error",
        message => "unable to create pseudo configuration" );
    }

    unless (-e $ini_file) {
      croak $self->_log( level => "error",
	message => "unexpected error in creating pseudo configuration" );
    }
  }
}

=begin internal

=item _read_profile_ini

  $ini->_read_profile_ini( path => $path );

  $ini->_read_profile_ini( $path );

Parses the F<profile.ini> in C<$path>.

This is called automatically by L</new>.

=end internal

=cut

sub _read_profile_ini {
  my $self = shift;
  my %args = Params(qw( path ))->args(@_);
  my $path = File::Spec->rel2abs($args{path});

  local ($_);

  $self->{profiles} = { };

  if (my $ini_file = _catfile($path, "profiles.ini")) {
    $self->{ini_file} = $ini_file;
    my $cfg = Config::IniFiles->new( -file => $ini_file );
    if ($cfg) {
      my $start_with_last = $cfg->val("General","StartWithLastProfile","");

      my $name = "";
      my $i = 0;
      while (my $profile = $cfg->val("Profile$i","Path")) {

        my $profile_path = _catdir($path, $profile);
	$profile_path = _catdir($profile) unless ($profile_path);

	if ($profile_path) {
	  my $data = {
	    ProfileId => "Profile$i",
	    Path      => $profile_path,
	  };

          unless ($name = $cfg->val("Profile$i", "Name")) {
	    croak $self->_log( level => "error",
	      message => "No name is defined for Profile$i");
          }

          # In nsToolkitProfileService.cpp, flags are "1" or ""

	  foreach (qw( Name IsRelative Default )) {
	    $data->{$_} = $cfg->val("Profile$i",$_, "");
	  }

	  $self->{profiles}->{$name} = $data;

	} else {
          # Do we carp instead of croak if there's bad data in profiles.ini?
	  croak $self->_log( level => "error",
	    message => "Bad Path: $profile_path not a directory");
	}
	$i++;
      }
      if ($start_with_last && $name) {
        $self->{profiles}->{$name}->{Default} = "1";
      }
    } else {
      croak $self->_log( level => "error",
       message => "Bad INI file: $ini_file");
    }
  } else {
    croak $self->_log( level => "error",
      message => "cannot find profiles.ini in $path");
  }
}

=item create_profile

  $ini->create_profile( name => $name, is_default => $def, path => $path );

  $ini->create_profile( $name, $def, $path );

Creates a profile named C<$name> in C<$path>. If C<$path> is not
specified, it creates a relative profile in the F<Profiles>
subdirectory below the F<profiles.ini> file.

=cut

sub create_profile {
  my $self = shift;
  my %args = Params(qw( name ?is_default ?path ))->args(@_);
  my $name = $args{name};
  my $def  = $args{is_default} ? "1" : "";
  my $path = $args{path};

  local ($_);

  unless ($def || (keys %{$self->{profiles}})) {
    $def = "1";
    $self->_log( level => "info",
      message => "the only profile must be default" );
  }


  my $ini_file = $self->ini_file();
  if (-r $ini_file) {
    my @dirs = File::Spec->splitdir($ini_file);
    my $prof = File::Spec->catdir( @dirs[0..$#dirs-1], "Profiles" );
    unless (-d $prof) {
      $self->_log( level => "info",
        message => "creating directory $prof\n" );
      unless (mkdir $prof) {
	croak $self->_log( level => "error",
          message => "unable to create directory $prof" );      
      }

      # TODO - option whether to set perms; also a portable chmod

      chmod 0700, $prof;
    }

    # create a unique name

    # Note: Mozilla-style is to use "Profiles/$name/$random.slt" rather
    # than "Profiles/$random.$name"

    my $dir;
    unless ($path) {
      do {
        $dir = "";
        for (1..8) { $dir .= ("a".."z","0".."9")[int(rand(36))]; }
        # TODO - verify the profile naming scheme
        $dir .= "." . $name;
        $path = File::Spec->catdir($prof, $dir);
      } while (-d $path);
    }

    $self->_log( level => "info",
        message => "creating directory $path\n" );
    unless (mkdir $path) {
	croak $self->_log( level => "error",
          message => "unable to create directory $path" );
    }
    chmod 0700, $path;

    # BUG/TODO - We need to check how Mozilla etc. handles profile ids

    my $id = "Profile" . scalar( keys %{$self->{profiles}} );

    foreach (keys %{$self->{profiles}}) {
      if ($self->{profiles}->{$_}->{ProfileId} eq $id) {
        croak $self->_log( level => "error",
          message => "Profile Id conflict" );
      }
    }

    my $cfg = Config::IniFiles->new( -file => $ini_file );

    # update profile default flags

    foreach (keys %{$self->{profiles}}) {
      my $data = $self->{profiles}->{$_};
      $data->{Default} = "", if ($def);
      if (defined $cfg->val($data->{ProfileId}, "Default")) {
	$cfg->setval($data->{ProfileId}, "Default", $data->{Default});
      } else {
	$cfg->newval($data->{ProfileId}, "Default", $data->{Default});
      }
    }

    if ($def) {
      $cfg->setval("General", "StartWithLastProfile", "1");
    }
    else {
      $cfg->setval("General", "StartWithLastProfile", "");
    }

    my $data = {
      ProfileId  => $id,
      Name       => $name,
      IsRelative => (($dir) ? "1" : ""),
      Default    => $def,
      Path       => (($dir) ? ("Profiles/" . $dir) : $path),
    };

    $cfg->AddSection($id);
    foreach (qw( Name IsRelative Path Default )) {
      $cfg->newval($id, $_, $data->{$_});
    }

    $data->{Path} = $path;
    $self->{profiles}->{$name} = $data;

    # TODO/BUG? - Make sure IsRelative paths are not changed to
    # absolute paths when rewritten!

    unless ($cfg->RewriteConfig) {
      croak $self->_log( level => "error",
        message => "Unable to update INI file" );
    }
  }
  else {
    croak $self->_log( level => "error",
      message => "cannot find INI file $ini_file" );
  }
}

=item ini_file

   $path = $ini->ini_file();

Returns the path to the F<profiles.ini> file.

=cut

sub ini_file {
  my $self = shift;
  return $self->{ini_file};
}

=item profile_names

  @names = $ini->profile_names($type);

Returns the names of profiles associated with the type.

=cut

sub profile_names {
  my $self = shift;
  return (keys %{$self->{profiles}});
}

=item profile_exists

  if ($ini->profile_exists($name)) { ... }

Returns true if a profile exists.

=cut

sub profile_exists {
  my $self = shift;
  my %args = Params(qw( name ))->args(@_);
  my $name = $args{name};
  return (exists $self->{profiles}->{$name});
}

=item profile_is_relative

  if ($ini->profile_is_relative($name)) { ... }

Returns the "IsRelative" flag for the profile.

=cut

sub profile_is_relative {
  my $self = shift;
  my %args = Params(qw( name ))->args(@_);
  my $name = $args{name};
  # TODO - validate profile name
  return $self->{profiles}->{$name}->{IsRelative};
}

=item profile_path

  $path = $ini->profile_path($name);

Returns the pathname of the profile.

=cut

sub profile_path {
  my $self = shift;
  my %args = Params(qw( name ))->args(@_);
  my $name = $args{name};

  # TODO - validate profile name

  my $path = $self->{profiles}->{$name}->{Path};
#   if ($self->profile_is_relative($name) && (!-d $path)) {
#     my @dirs = File::Spec->splitdir( $self->ini_file );
#     $path = File::Spec->catdir( @dirs[0..$#dirs-1], $path );
#   }
  return $path;
}

=item profile_is_default

  if ($ini->profile_is_default($name)) { ... }

Returns the "Default" flag for the profile.

=cut

sub profile_is_default {
  my $self = shift;
  my %args = Params(qw( name ))->args(@_);
  my $name = $args{name};
  return $self->{profiles}->{$name}->{Default};
}

=item profile_id

  $section = $ini->profile_id($name);

Returns the L</ini_file> identifier of the profile.

=cut

sub profile_id {
  my $self = shift;
  my %args = Params(qw( name ))->args(@_);
  my $name = $args{name};
  return $self->{profiles}->{$name}->{ProfileId};
}

=item profile_is_locked

  if ($ini->profile_is_locked($name)) { ... }

Returns true if there is a lock file in the profile.

=cut

sub profile_is_locked {
  my $self = shift;
  my %args = Params(qw( name ))->args(@_);
  my $name = $args{name};
  foreach ('parent.lock', 'lock', '.parentlock') {
    if (_catfile($self->profile_path(name => $name), $_ )) {
      return 1;
    }      
  }
  return;
}

=begin internal

=item _catdir

  $path = _catdir( @names );

Returns the C<$path> if the concatenation of C<@names> exists as a
directory, or C<undef> otherwise.

=item _catfile

  $path = _catdir( @names );

Returns the C<$path> if the concatenation of C<@names> exists as a
file, or C<undef> otherwise.

=end internal

=cut

sub _catdir {
  if ($_[0]) { # otherwise blank "" is translated to root directory
    my $path = File::Spec->catdir(@_);
    return (-d $path) ? $path : undef;
  }
  else {
    return;
  }
}

sub _catfile {
  my $path = File::Spec->catfile(@_);
  return (-r $path) ? $path : undef;
}

=begin internal

=item _find_profile_path

  $path = _find_profile_path( home => $home, type => $type );

  $path = _find_profile_path( $home, $type );

Looks for a directory corresponding to where profile type of C<$type>
should be, generally somewhere in the C<$home> directory, where
C<$home> is the platform-specific "home" directory (not necessarily
C<$ENV{HOME}>).

Returns C<undef> if no path for that type was found.

In cases where profile paths cannot be found, use the C<MOZILLA_HOME>
or C<appname_HOME> environment variable to indicate where it is.

=end internal

=cut

sub _find_profile_path {
  my %args = Params(qw( home type ))->args(@_);
  my $home = $args{home};
  my $type = $args{type};

  # Known Issue: the first profile that it finds for a type is the one
  # it uses. If for some reason there are profiles for the same
  # application in multiple places (maybe due to an upgrade), it will
  # use the first that it finds.

  my $path;

  # The MOZILLA_HOME environment variables are for OS/2, but putting
  # them here first allows one to override settings.

  if ($path = _catdir($ENV{uc($type)."_HOME"})) {
    return $path;
  }
  if ($path = _catdir($ENV{MOZILLA_HOME}, ucfirst($type))) {
    return $path;
  }

  if ($path = _catdir($home, "\.$type")) {
    return $path;
  }
  if ($path = _catdir($home, "\.mozilla", $type)) {
    return $path;
  }
  if ($path = _catdir($home, ucfirst($type))) {
    return $path;
  }
  if ($path = _catdir($home, "Mozilla", ucfirst($type))) {
    return $path;
  }

  if ($^O eq "darwin") {
    if ($path = _catdir($home, "Library", "Application Support",
			ucfirst($type))) {
      return $path;
    }
    if ($path = _catdir($home, "Library", "Application Support",
			"Mozilla", ucfirst($type))) {
      return $path;
    }
    if ($path = _catdir($home, "Library", ucfirst($type))) {
      return $path;
    }
    if ($path = _catdir($home, "Library", "Mozilla", ucfirst($type))) {
      return $path;
    }
  }
  elsif ($^O eq "MSWin32") {
    my $program_files = $ENV{ProgramFiles} || "Program Files";
    if ($path = _catdir($program_files, ucfirst($type))) {
      return $path;
    }
    if ($path = _catdir($program_files, "Mozilla", ucfirst($type))) {
      return $path;
    }
  }

  # If we're here in Cygwin, it means that Mozilla builds are probably
  # native-Windows instead of Cygwin. So we need to look in the
  # Windows native drive.

  # Known Issue: if you have separate Cygwin and Windows Moz profiles,
  # then it will recognize the Cygwin profile first.

  elsif ($^O eq "cygwin") {
    if ((caller(1))[3] !~ /_find_profile_path$/) {
      $home = $ENV{APPDATA}; # Win 2000/XP/2003
      $home =~ s/^(\w):/\/cygdrive\/$1/;
      return _find_profile_path($home,$type);
    }
  }

  return;
}

=begin internal

=item _log

  $ini->_log( level => $level, $message => $message );

Logs an event to the dispatcher.

=end internal

=cut

sub _log {
  my $self = shift;
  my %p    = @_;
  my $msg  = $p{message};

  # we want log messages to always have a newline, but not necessarily
  # the returned value that we pass to carp and croak

  $p{message} .= "\n" unless ($p{message} =~ /\n$/);
  $self->{log}->log(%p);
  return $msg;    # when used by carp and croak
}


=back

=head1 CAVEATS

This module is a prototype. Use at your own risk!

=head1 SEE ALSO

L<Mozilla::Backup>

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

1;

__END__
