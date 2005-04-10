=head1 NAME

Mozilla::Backup - Backup utility for Mozilla profiles

=head1 REQUIREMENTS

The following non-core modules are required:

  Archive::Zip
  Config::IniFiles
  Log::Dispatch
  Params::Validate

=head1 SYNOPSIS

  $moz = Mozilla::Backup->new();
  $file = $moz->backup_profile("firefox", "default");

=head1 DESCRIPTION

This package provides a simple interface to back up the profiles of
Mozilla-related applications.

=cut

package Mozilla::Backup;

use 5.006;
use strict;
use warnings;

use Carp;
use Config::IniFiles;
use File::Find;
use File::Spec;
use Log::Dispatch 1.6;
use Params::Validate qw( :all );

our $VERSION = '0.03';

my @PROFILE_TYPES = qw(
  camino firefox galeon k-meleon mozilla netscape phoenix sunbird thunderbird
);

sub profile_types {
  return @PROFILE_TYPES;
}

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

sub _find_profile_path {
  my $home = shift;
  my $type = shift;

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

  return;
}

sub _find_all_profiles {
  my $self = shift;

  my $home = $ENV{HOME};
  if ($^O eq "MSWin32") {
    $home  = $ENV{APPDATA} || _catdir($ENV{USERPROFILE}, "Application Data");
  }

  foreach my $type (profile_types) {
    if (my $path = _find_profile_path($home,$type)) {      
      if (my $ini_file = _catfile($path, "profiles.ini")) {
	$self->{ini_files}->{$type} = $ini_file;
	my $cfg = Config::IniFiles->new( -file => $ini_file );
	if ($cfg) {
	  my $i = 0;
	  while (my $profile = $cfg->val("Profile$i","Path")) {

	    my $profile_path = _catdir($path, $profile);
	    $profile_path = _catdir($profile) unless ($profile_path);

	    if ($profile_path) {
	      my $data = {
		ProfileId => "Profile$i",
		Path      => $profile_path,
	      };
	      foreach my $key (qw( Name IsRelative )) {
		$data->{$key} = $cfg->val("Profile$i",$key);
	      }

	      $self->{profiles}->{$type} = { }
		unless (exists $self->{profiles}->{type});
	      $self->{profiles}->{$type}->{$data->{Name}} = $data;

	    } else {
	      croak $self->_log( level => "error",
		message => "$profile_path not a directory");
	    }
	    $i++;
	  }
	} else {
	  croak $self->_log( level => "error",
	    message => "Bad INI file: $ini_file");
	}


      }
    }
  }
}

=over

=item new

  $moz = Mozilla::Backup->new( %options );

Creates a new Mozilla::Backup object. The options are as follows:

=over

=item log

A L<Log::Dispatch> object for receiving log messages.

=item new_arch

A callback for creating a new archive, which receives the following
arguments: C<($moz, $path, %opts)>.

C<$moz> is the L<Mozilla::Backup> object. 

C<$path> is the pathname of the archive.

<%opts> are options specific to the archive format.

You may save state in the C<$moz->{archive}->{user}> key.

On success it returns a true value.

=item add_arch

A callback for adding a file to the archive, which receives the following
arguments: C<$moz, $local_file, $archive_file>.

=item end_arch

A callback for saving and closing the archive. It receives the following
arguments: C<$moz>.

=back

=cut

# TODO:
# - option to insert comments into archive
# - option to control compression type

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = validate( @_, {
    log       => {
                   default => Log::Dispatch->new,
                   isa     => 'Log::Dispatch',
                 },
    new_arch  => {
                   default => \&_new_archive,
                   type    => 'CODE',
                 },
    add_arch  => {
                   default => \&_add_archive,
                   type    => 'CODE',
                 },
    end_arch  => {
                   default => \&_end_archive,
                   type    => 'CODE',
                 },
  });

  my $self  = {
    log       => $args{log},
    profiles  => { },
    ini_files => { },
    archive   => {
      _new    => $args{new_arch},
      _add    => $args{add_arch},
      _end    => $args{end_arch},
      path    => undef,
      opts    => { },
    },
  };


  bless $self, $class;

  $self->_find_all_profiles();

  return $self;
}

=item profile_types

  @types = $moz->profile_types;

Returns a list of all profile types that are supported by this version
of the module.

Supported profile types:

  camino
  firefox
  galeon
  kmeleon
  mozilla
  phoenix
  netscape
  sunbird
  thunderbird

Some of these profile types are for platform-specific applications, so
you may never run into them.

=item found_profile_types

  @types = $moz->found_profile_types();

Returns a list of applications for which profiles were found.  (This
does not mean that the applications are installed on the machine, only
that profiles were found where they were expected.)

=cut

sub found_profile_types {
  my $self = shift;
  return (keys %{$self->{profiles}});
}

=item ini_file

  $file = $moz->ini_file($type);

Returns the profile INI file for that type.

=cut

sub ini_file {
  my $self = shift;
  validate_pos(@_, 1);
  my $type = shift;
  return $self->{ini_files}->{$type};
}

=item profile_names

  @names = $moz->profile_names($type);

Returns the names of profiles associated with the type.

=cut

sub profile_names {
  my $self = shift;
  validate_pos(@_, 1);
  my $type = shift;
  return (keys %{$self->{profiles}->{$type}});
}

=item profile_path

  $path = $moz->profile_path($type,$name);

Returns the pathname of the profile.

=cut

sub profile_path {
  my $self = shift;
  validate_pos(@_, 1, 1);
  my $type = shift;
  my $name = shift;
  return $self->{profiles}->{$type}->{$name}->{Path};
}


=item profile_exists

  if ($moz->profile_exists($type,$name)) { ... }

Returns true if a profile exists.

=cut

sub profile_exists {
  my $self = shift;
  validate_pos(@_, 1, 1);
  my $type = shift;
  my $name = shift;
  return (exists $self->{profiles}->{$type}->{$name});
}

=item profile_is_relative

  if ($moz->profile_is_relative($type,$name)) { ... }

Returns the 'IsRelative' flag for the profile.

=cut

sub profile_is_relative {
  my $self = shift;
  validate_pos(@_, 1, 1);
  my $type = shift;
  my $name = shift;
  return $self->{profiles}->{$type}->{$name}->{IsRelative};
}

=item profile_id

  $section = $moz->profile_id($type,$name);

Returns the L</ini_file> identifier of the profile.

=cut

sub profile_id {
  my $self = shift;
  validate_pos(@_, 1, 1);
  my $type = shift;
  my $name = shift;
  return $self->{profiles}->{$type}->{$name}->{ProfileId};
}


=item profile_is_locked

  if ($moz->profile_is_locked($type,$name)) { ... }

Returns true if there is a lock file in the profile.

=cut

sub profile_is_locked {
  my $self = shift;
  validate_pos(@_, 1, 1);
  my $type = shift;
  my $name = shift;
  return (-e File::Spec->catfile($self->profile_path($type,$name),
				 'parent.lock'));
}

sub _new_archive {
  my $self = shift;
  my $path = shift;
  my %opts = @_;  

  $self->{archive}->{path} = $path;
  $self->{archive}->{opts} = \%opts;

  require Archive::Zip;

  return $self->{archive}->{zip} = Archive::Zip->new();
}

sub _add_archive {
  my $self = shift;
  my $file = shift;                 # actual file
  my $name = shift || $file;        # name in archive

  $self->{archive}->{zip}->addFileOrDirectory($file, $name);
}

sub _end_archive {
  my $self = shift;
  $self->{archive}->{zip}->writeToFileNamed( $self->{archive}->{path} );
}

sub _backup_path {
  my $self = shift;
  validate_pos(@_, 1, 1, 1);
  my $path = shift;
  my $dest = shift;

  my $relative = shift;

  if (-e $dest) {
    croak $self->_log( level => "error", message => "$dest exists already" );
  }


  $self->_log( level => "notice", message => "Backing up $path\n" );

  unless ($self->{archive}->{_new}->($self, $dest)) {
    croak $self->_log( level => "error", message => "error creating archive" );
  }

  find({
	bydepth    => 1,
	wanted     => sub {
	  my $file = $File::Find::name;
	  my $name = $relative ? substr($file, length($path)) : $file;
	  if ($name) {
	    $name = substr($name,1); # remove initial '/'
	    unless ($name =~ /^(Cache(\.Trash)?|extensions)\//) {
	      $name .= '/' if (-d $file);
              $self->_log( level => "info", message => "Backing up $name\n" );
              $self->{archive}->{_add}->($self, $file, $name);
	    }
	  }

	},
       }, $path
      );

  # TODO: check for errors here
  $self->_log( level => "notice", message => "Saving to $dest\n" );
  $self->{archive}->{_end}->($self);
}

=item backup_profile

  $file = $moz->backup_profile($type,$name,$dest,$arch,$rel);

Backs up the profile as a zip archive to the path specified in C<$dest>.
(If none is given, the current directory is assumed.)

C<$arch> is an optional name for the archive file. If none is given, it
assumes F<type-name-date-time.zip>.

C<$rel> is an optional flag to backup files with relative paths instead
of absolute pathnames. It defaults to the value of L</profile_is_relative>
for that profile. (Non-relative profiles will show a warning message.)

If the profile is currently in use, it may not be backed up properly.

This version does no munging of the profile data at all. It simply
stores the files in an archive.

=cut

sub backup_profile {
  my $self = shift;
  validate_pos(@_, 1, 1, 0, 0, 0);
  my $type = shift;
  my $name = shift;
  my $dest = shift || '.';
  my $arch = shift || $self->_archive_name($type, $name);
  my $back = File::Spec->catfile($dest, $arch);

  my $relative = shift;

  $relative = $self->profile_is_relative($type,$name)
    unless (defined $relative);

  unless ($relative) {
    $self->_log( level => "notice", message => "backup will not use relative pathnames" );
  }

  if ($self->profile_is_locked($type,$name)) {
    croak $self->_log( level => "error", message => "cannot backup locked profile" );
  }

  $self->_backup_path($self->profile_path($type,$name), $back, $relative);
  return $back;
}

sub _archive_name {
  my $self = shift;
  my $type  = shift; # application
  my $name = shift; # profile

  my $timestamp   = sprintf("%04d%02d%02d-%02d%02d%02d",
       (localtime)[5]+1900, (localtime)[4]+1,
       reverse((localtime)[0..3]),
  );
  my $arch = join("-", $type, $name, $timestamp) . ".zip";
  return $arch;
}


sub _log {
  my $self = shift;
  $self->{log}->log(@_);
}

=item restore_profile

Not yet implemented.

=cut

sub restore_profile {
  my $self = shift;
  croak $self->_log( level => "error", message => "method unimplemented" );
}

1;

=back

=head1 CAVEATS

This module is a prototype. Use at your own risk!

Not all of the profile types have been tested, and are implemented
based on information gleaned from sources which may or may not be
accurate.

=head1 SEE ALSO

Mozilla web site at L<http://www.mozilla.org>.

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head2 Suggestions and Bug Reporting

Feedback is always welcome.  Please use the CPAN Request Tracker at
L<http://rt.cpan.org> to submit bug reports.

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
