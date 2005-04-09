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

use Archive::Zip;
use Carp;
use Config::IniFiles;
use File::Find;
use File::Spec;
use Log::Dispatch 1.6;
use Params::Validate qw( :all );

our $VERSION = '0.02';

sub _find_mozilla_profiles {
  my $self = shift;
  my %apps = ( );

  my %MOZILLA_PROFILE_PATHS = (
    'mozilla'     => 'Mozilla',
    'firefox'     => 'Mozilla/Firefox',
    'sunbird'     => 'Mozilla/Sunbird',
    'thunderbird' => 'Thunderbird',
  );

  # Mac OS/X - $ENV{HOME}/Library or $ENV{HOME}/Library/Application Support
  # Windows 98       - C:\WINDOWS\Application Data
  # Windows 2000/XP  - $ENV{APPDATA}
  # Unix     - $ENV{HOME}/.mozilla

  # K-Melion in Windows - $ENV{ProgramFiles}/K-Meleon/Profiles ?
  # Camino?

  my $home = $ENV{HOME};
  if ($^O eq "MSWin32") {
    $home = $ENV{APPDATA};
  }
  else {
    croak $self->_log( level => "error", message => "unsupported OS: $^O" );
  }

    if (-d $home) {

      foreach my $app (keys %MOZILLA_PROFILE_PATHS) {
	my $path = $MOZILLA_PROFILE_PATHS{$app};
	my $app_path = File::Spec->catdir($home,$path);

	if (-d $app_path) {
	  my $ini_file = File::Spec->catfile($app_path, 'profiles.ini');
	  $self->{ini_files}->{$app} = $ini_file;

	  if (-r $ini_file) {
	    my $cfg = Config::IniFiles->new( -file => $ini_file );
	    if ($cfg) {
	      my $i = 0;
	      while (my $profile = $cfg->val("Profile$i","Path")) {
		my $profile_path = File::Spec->catdir($app_path, $profile);
		if (-d $profile_path) {
		  my $data = {
                    Profile => "Profile$i",
                    Path    => $profile_path,
                  };
		  foreach my $key (qw( Name IsRelative )) {
		    $data->{$key} = $cfg->val("Profile$i",$key);
		  }
		  $apps{$app} = [ ] unless (exists $apps{$app});
		  push @{$apps{$app}}, $data;
		} else {
		  $self->_log( level => "warn", message => "$profile_path not a directory");
		}
		$i++;
	      }
	    } else {
	      croak $self->_log( level => "error", message => "Bad INI file: $ini_file");
	    }
	  }
	}
      }
      
    }

  foreach my $app (keys %apps) {
    $self->{profiles}->{$app} = { };
    foreach my $profile (@{$apps{$app}}) {
      $self->{profiles}->{$app}->{$profile->{Name}} = $profile;
    }
  }

}

=over

=item new

  $moz = Mozilla::Backup->new( log => $log );

Creates a new Mozilla::Backup object.  C<$log> is an optional
L<Log::Dispatch> object.

=cut

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = validate( @_, {
    log       => { default => Log::Dispatch->new, },
  });

  my $self  = {
    log       => $args{log},
    profiles  => { },
    ini_files => { },
  };

  bless $self, $class;

  $self->_find_mozilla_profiles();

  return $self;
}

=item found_profile_types

  @types = $moz->found_profile_types();

Returns a list of applications for which profiles were found.  (This
does not mean that the applications are installed on the machine.)

Supported profile types:

  firefox
  mozilla
  sunbird
  thunderbird

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
  my $type = shift;
  return $self->{ini_files}->{$type};
}

=item profile_names

  @names = $moz->profile_names($type);

Returns the names of profiles associated with the type.

=cut

sub profile_names {
  my $self = shift;
  my $type = shift;
  return (keys %{$self->{profiles}->{$type}});
}

=item profile_path

  $path = $moz->profile_path($type,$name);

Returns the pathname of the profile.

=cut

sub profile_path {
  my $self = shift;
  my $type = shift;
  my $name = shift;
  return $self->{profiles}->{$type}->{$name}->{Path};
}

=item profile_is_relative

  if ($moz->profile_is_relative($type,$name)) { ... }

Returns the 'IsRelative' flag for the profile.

=cut

sub profile_is_relative {
  my $self = shift;
  my $type = shift;
  my $name = shift;
  return $self->{profiles}->{$type}->{$name}->{IsRelative};
}


=item profile_section

  $section = $moz->profile_section($type,$name);

Returns the L</ini_file> section of the profile.

=cut

sub profile_section {
  my $self = shift;
  my $type = shift;
  my $name = shift;
  return $self->{profiles}->{$type}->{$name}->{Profile};
}

sub _backup_path {
  my $self = shift;
  my $path = shift;
  my $back = shift;

  if (-e $back) {
    croak $self->_log( level => "error", message => "$back exists already" );
  }


  $self->_log( level => "notice", message => "Backing up $path\n" );
  my $arch = Archive::Zip->new();
  find({
	bydepth    => 1,
	wanted     => sub {
	  my $file = $File::Find::name;
	  my $name = substr($file, length($path));
	  if ($name) {
	    $name = substr($name,1); # remove initial '/'
	    unless ($name =~ /^(Cache(\.Trash)?|extensions)\//) {
	      $name .= '/' if (-d $file);
              $self->_log( level => "info", message => "Backing up $name\n" );
	      $arch->addFileOrDirectory($file, $name);
	    }
	  }

	},
       }, $path
      );

  # TODO: check for errors here
  $self->_log( level => "notice", message => "Saving to $back\n" );
  $arch->writeToFileNamed( $back );
}

=item backup_profile

  $file = $moz->backup_profile($type,$name,$dest,$arch);

Backs up the profile as a zip archive to the path specified in C<$dest>.
(If none is given, the current directory is assumed.)

C<$arch> is an optional name for the archive file. If none is given, it
assumes F<type-name-date-time.zip>.

If the profile is currently in use, it may not be backed up properly.

=cut

sub backup_profile {
  my $self = shift;
  my $type = shift;
  my $name = shift;
  my $dest = shift || '.';
  my $arch = shift || $self->_archive_name($type, $name);
  my $back = File::Spec->catfile($dest, $arch);

  unless ($self->profile_is_relative($type,$name)) {
    $self->_log( level => "warn", message => "warning: profile is not relative" );
  }

  $self->_backup_path($self->profile_path($type,$name), $back);
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

Only Windows 2000/XP machines are supported in this version.

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
