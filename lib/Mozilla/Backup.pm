=head1 NAME

Mozilla::Backup - Backup utility for Mozilla profiles

=head1 REQUIREMENTS

The following non-core modules are required:

  Archive::Zip
  Config::IniFiles
  Log::Dispatch
  Module::Pluggable
  Params::Smart
  Params::Validate

=head1 SYNOPSIS

  $moz = Mozilla::Backup->new();
  $file = $moz->backup_profile("firefox", "default");

=head1 DESCRIPTION

This package provides a simple interface to back up and restore the
profiles of Mozilla-related applications such as Firefox or Thunderbird.

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
use Module::Pluggable;
use Params::Smart 0.03;
use Params::Validate qw( :all );

# $Revision: 1.28 $

our $VERSION = '0.04';

# Note: the 'pseudo' profile type is deliberately left out

my @PROFILE_TYPES = qw(
  camino firefox galeon k-meleon mozilla netscape phoenix sunbird thunderbird
);

sub profile_types {
  return @PROFILE_TYPES;
}

=begin internal

=item _catdir

=item _catfile

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

=item _find_all_profiles

=end internal

=cut

sub _find_all_profiles {
  my $self = shift;

  my $home = $ENV{HOME};
  if ($^O eq "MSWin32") {
    $home  = $ENV{APPDATA} || _catdir($ENV{USERPROFILE}, "Application Data");
  }

  foreach my $type (profile_types) {
    if (my $path = _find_profile_path($home,$type)) {      
      $self->_read_profile_ini( type => $type, path => $path);
    }
  }
  if ($self->{pseudo}) {
    $self->_create_pseudo_profile_ini;
    $self->_create_new_profile("pseudo", "default")
      unless ($self->profile_exists("pseudo", "default"));
  }
}

=begin internal

=item _read_profile_ini

=end internal

=cut

sub _read_profile_ini {
  my $self = shift;
  my %args = Params(qw( type path ))->args(@_);
  my $type = $args{type};
  my $path = File::Spec->rel2abs($args{path});

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
	    unless (exists $self->{profiles}->{$type});
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

=begin internal

=item _create_new_profile

  $moz->_create_new_profile($type,$name);

Creates a new C<$type> profile named C<$name>.  (If a profile with the
given name already exists, it will die with an error.)

=end internal

=cut

sub _create_new_profile {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};

  if ($self->profile_exists($type,$name)) {
    croak $self->_log( level => "error",
      message => "profile $name already exists in $type" );
  }

  my $ini_file = $self->ini_file($type);
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
    }

    # create a unique name

    # Note: Mozilla-style is to use "Profiles/$name/$random.slt" rather
    # than "Profiles/$random.$name"

    my ($dir, $path);
    do {
      $dir = "";
      for (1..8) { $dir .= ("a".."z","0".."9")[int(rand(36))]; }
      # TODO - verify the profile naming scheme
      $dir .= "." . $name;
      $path = File::Spec->catdir($prof, $dir);
    } while (-d $path);

    $self->_log( level => "info",
        message => "creating directory $path\n" );
    unless (mkdir $path) {
	croak $self->_log( level => "error",
          message => "unable to create directory $path" );
    }

    # BUG/TODO - We need to check how Mozilla etc. handles profile ids

    my $id = "Profile" . scalar( keys %{$self->{profiles}->{$type}} );

#    require YAML;
#    print STDERR YAML->Dump($self);

    foreach my $n (keys %{$self->{profiles}->{$type}}) {
      if ($self->{profiles}->{$type}->{$n}->{ProfileId} eq $id) {
        croak $self->_log( level => "error",
          message => "Profile Id conflict" );
      }
    }

    my $data = {
      ProfileId  => $id,
      Name       => $name,
      IsRelative => 1,
      Path       => "Profiles/" . $dir,
    };
    $self->{profiles}->{$type}->{$name} = $data;

    my $cfg = Config::IniFiles->new( -file => $ini_file );
    $cfg->AddSection($id);
    foreach my $key (qw( Name IsRelative Path )) {
      $cfg->newval($id, $key, $data->{$key});
    }
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

=begin internal

=item _create_psuedo_profile_ini

  $moz->__create_psuedo_profile_ini($root);

Creates a pseudo-profile named C<psuedo> for testing and debugging.

=end internal

=cut

sub _create_pseudo_profile_ini {
  my $self = shift;
  unless (exists $self->{profiles}->{pseudo}) {
    $self->{pseudo} = File::Spec->rel2abs($self->{pseudo});
    my $root = $self->{pseudo};

    unless (-d $root) {
      croak $self->_log( level => "error",
	message => "cannot access psuedo profile directory: $root" );
    }

    my $ini_file = File::Spec->catfile($root, "profiles.ini" );
    if (-e $ini_file) {
      $self->_read_profile_ini( type => "pseudo", path => $root);
    }
    else {
      my $cfg = Config::IniFiles->new();
      $cfg->AddSection("General");
      $cfg->newval("General", "StartWithLastProfile", 1);

      unless ($cfg->WriteConfig( $ini_file )) {
	croak $self->_log( level => "error",
          message => "unable to create pseudo configuration" );
      }

      if (-e $ini_file) {
	$self->{ini_files}->{pseudo} = $ini_file;
	$self->{profiles}->{pseudo} = { };
      } else {
	croak $self->_log( level => "error",
	  message => "unexpected error in creating pseudo configuration" );
      }
    }
  }
}

=begin internal

=item _load_plugin

  $moz->_load_plugin( plugin => $plugin );

Loads a plugin module. It assumes that C<$plugin> contains the full
module name.

=end internal

=cut

sub _load_plugin {
  my $self   = shift;
  my %args = Params(qw( plugin ))->args(@_);
  my $plugin = $args{plugin};

  # TODO - check if plugin already loaded

  eval "CORE::require $plugin";
  if ($@) {
    croak $self->_log( level => "critical", 
      message => "Unable to load plugin plugin" );
  }
  else {
    # We check to see if the plugin supports the methods we
    # need. Would it make more sense to have a base class and test
    # isa() instead?

    foreach my $method (qw(
      allowed_options new munge_location open_for_backup open_for_restore
      get_contents backup_file restore_file close_backup close_restore
    )) {
      croak $self->_log( level => "critical",
        message => "Plugin does not support $method method" )
      unless ($plugin->can($method));
    }

    # We check to see if the plugin accepts certain options

    my %opts = ( );
    foreach my $opt (qw( log debug )) {
      $opts{$opt} = $self->{$opt} if ($plugin->allowed_options($opt));
    }
    $self->{plugin} = $plugin->new(%opts);
  }
  return $self->{plugin};
}

=over

=item new

  $moz = Mozilla::Backup->new( %options );

Creates a new Mozilla::Backup object. The options are as follows:

=over

=item log

A L<Log::Dispatch> object for receiving log messages.

This value is passed to plugins if they accept it.

=item plugin

A plugin to use for archiving. Plugins included are:

=over

=item Mozilla::Backup::Plugin::Zip

Saves the profile in a zip archive. This is the default plugin.

=item Mozilla::Backup::Plugin::FileCopy

Copies the files in the profile into another directory.

=back

=begin internal

=item pseudo

Specifies the directory of a special C<pseudo> profile type used for debugging
and testing.  This does not appear in the L</profile_types>.

=item debug

Sets an internal debug flag, which adds a "debug"-level screen output
sink to the log dispatcher.  This value is passed to plugins if they
accept it.

=end internal

=back

=cut

# TODO:
# - option to insert comments into archive
# - option to control compression type (pass to zip plugin)

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = validate( @_, {
    log       => {
                   default => Log::Dispatch->new,
                   isa     => 'Log::Dispatch',
                 },
    plugin    => {
                   default => 'Mozilla::Backup::Plugin::Zip',
                   # we try to load the plugin later
                 },
    pseudo    => {
                   default => '',
                   type    => SCALAR,
                   callbacks => {
                     'directory exists' =>
                        sub { (($_[0] eq "") || (-d $_[0])) },
                   },
                 },
    debug     => {
                   default => 0,
                   type    => BOOLEAN,
                 },
  });

  my $self  = {
    log       => $args{log},
    profiles  => { },
    ini_files => { },
    pseudo    => $args{pseudo}, # creates a pseudo profile type
    debug     => $args{debug},
  };

  bless $self, $class;

  if ($self->{debug}) {
    require Log::Dispatch::Screen;
    $args{log}->add( Log::Dispatch::Screen->new(
      name      => __PACKAGE__,
      min_level => "debug",
      stderr    => 1,
    ));
  }

  $self->_load_plugin( plugin => $args{plugin} );
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

=item type_exists

  if ($moz->type_exists($type)) { ... }

Returns true if a profile type exists on the machine.

=cut

sub type_exists {
  my $self = shift;
  my %args = Params(qw( type ))->args(@_);
  my $type = $args{type};
  return (exists $self->{profiles}->{$type});
}

=begin internal

=item _validate_type

=item _validate_profile

=end internal

=cut

sub _validate_type {
  my $self = shift;
  my %args = Params(qw( type ))->args(@_);
  my $type = $args{type};
  croak $self->_log( level => "error",
		     message => "invalid profile type: $type" ),
    unless ($self->type_exists( type => $type ));
}

sub _validate_profile {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};
  $self->_validate_type( type => $type);
  croak $self->_log( level => "error",
		     message => "invalid profile: $name" ),
    unless ($self->profile_exists( type => $type, name => $name ));
}

=item ini_file

  $file = $moz->ini_file($type);

Returns the profile INI file for that type.

=cut

sub ini_file {
  my $self = shift;
  my %args = Params(qw( type ))->args(@_);
  my $type = $args{type};
  $self->_validate_type( type => $type);
  return $self->{ini_files}->{$type};
}

=item profile_names

  @names = $moz->profile_names($type);

Returns the names of profiles associated with the type.

=cut

sub profile_names {
  my $self = shift;
  my %args = Params(qw( type ))->args(@_);
  my $type = $args{type};
  $self->_validate_type( type => $type);
  return (keys %{$self->{profiles}->{$type}});
}

=item profile_path

  $path = $moz->profile_path($type,$name);

Returns the pathname of the profile.

=cut

sub profile_path {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};
  $self->_validate_profile( type => $type, name => $name );
  my $path = $self->{profiles}->{$type}->{$name}->{Path};
  unless (-d $path) {
    my @dirs = File::Spec->splitdir( $self->ini_file($type) );
    $path = File::Spec->catdir( @dirs[0..$#dirs-1], $path );
  }
  return $path;
}


=item profile_exists

  if ($moz->profile_exists($type,$name)) { ... }

Returns true if a profile exists.

=cut

sub profile_exists {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};
  $self->_validate_type( type => $type);
  return (exists $self->{profiles}->{$type}->{$name});
}

=item profile_is_relative

  if ($moz->profile_is_relative($type,$name)) { ... }

Returns the 'IsRelative' flag for the profile.

=cut

sub profile_is_relative {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};
  $self->_validate_profile( type => $type, name => $name );
  return $self->{profiles}->{$type}->{$name}->{IsRelative};
}

=item profile_id

  $section = $moz->profile_id($type,$name);

Returns the L</ini_file> identifier of the profile.

=cut

sub profile_id {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};
  $self->_validate_profile( type => $type, name => $name );
  return $self->{profiles}->{$type}->{$name}->{ProfileId};
}


=item profile_is_locked

  if ($moz->profile_is_locked($type,$name)) { ... }

Returns true if there is a lock file in the profile.

=cut

sub profile_is_locked {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};
  $self->_validate_profile( type => $type, name => $name );
  return (-e File::Spec->catfile(
    $self->profile_path( type => $type, name => $name), 'parent.lock'));
}

=begin internal

=item _backup_path

=end internal

=cut

sub _backup_path {
  my $self = shift;
  my %args = Params(qw( profile_path destination relative ))->args(@_);
  my $path     = $args{profile_path};
  my $dest     = $args{destination};
  my $relative = $args{relative};

  # TODO - an option for overwriting existing files?

  if (-e $dest) {
    croak $self->_log( level => "error", message => "$dest exists already" );
  }

  $self->_log( level => "notice", message => "backing up $path\n" );

  unless ($self->{plugin}->open_for_backup( path => $dest)) {
    croak $self->_log( level => "error", message => "error creating archive" );
  }

  # TODO - options to filter which files backed up

  find({
	bydepth    => 1,
	wanted     => sub {
	  my $file = $File::Find::name;
	  my $name = $relative ? substr($file, length($path)) : $file;
	  if ($name) {
	    $name = substr($name,1); # remove initial '/'
	    unless ($name =~ /^(Cache(\.Trash)?|extensions)\//) {
	      $name .= '/' if (-d $file);
              $self->{plugin}->backup_file($file, $name) ||
		croak $self->_log( level => "error",
		  message => "error backing up $file" );
	    }
	  }

	},
       }, $path
      );

  # TODO: check for errors here
  $self->{plugin}->close_backup();
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
  my %args = Params(qw( type name ?destination ?archive_name ?relative ))
    ->args(@_);
  my $type = $args{type};
  my $name = $args{name};

  $self->_validate_profile( type => $type, name => $name );

  my $dest = $args{destination}  || '.';
  my $arch = $args{archive_name} ||
    $self->_archive_name( type => $type, name => $name);

  # TODO - if destination includes a file name, use it. The plugin
  # should have methods for parsing destination appropriate to the
  # backup method.

  my $back = File::Spec->catfile($dest, $arch);

  my $relative = $args{relative};

  $relative = $self->profile_is_relative( type => $type, name => $name)
    unless (defined $relative);

  unless ($relative) {
    $self->_log( level => "notice",
      message => "backup will not use relative pathnames\n" );
  }

  if ($self->profile_is_locked( type => $type, name => $name)) {
    croak $self->_log( level => "error",
      message => "cannot backup locked profile" );
  }

  $self->_backup_path(
    profile_path => $self->profile_path( type => $type, name => $name),
    destination  => $back,
    relative     => $relative);
  return $back;
}

=begin internal

=item _archive_name

=end internal

=cut

sub _archive_name {
  my $self = shift;
  my %args = Params(qw( type name ))->args(@_);
  my $type = $args{type};
  my $name = $args{name};

  $self->_validate_profile( type => $type, name => $name );

  my $timestamp   = sprintf("%04d%02d%02d-%02d%02d%02d",
       (localtime)[5]+1900, (localtime)[4]+1,
       reverse((localtime)[0..3]),
  );
  my $arch = join("-", $type, $name, $timestamp);
  return $self->{plugin}->munge_location($arch);
}

=begin internal

=item _log

  $moz->_log( level => $level, $message => $message );

Logs an event to the dispatcher.

=end internal

=cut

sub _log {
  my $self = shift;
  my %p    = @_;
  $self->{log}->log(%p);
  return $p{message};    # when used by carp and croak
}

=item restore_profile

  $moz->restore_profile($backup, $type, $name);

Restores the profile at C<$backup>.

Note: this does not check that it is the corrct profile type. It will
allow you to restore a profile of a different (and possibly incompatible)
type.

=cut

sub restore_profile {
  my $self = shift;
  my %args = Params(qw( archive_path type name ))->args(@_);
  my $path = $args{archive_path};
  my $type = $args{type};
  my $name = $args{name};

  $self->_validate_type( type => $type );

  unless ($self->profile_exists( type => $type, name => $name)) {
    $self->_log( level => "info",
       message => "creating new profile: $name\n" );
    unless ($self->_create_new_profile( type => $type, name => $name)) {
      croak $self->_log( level => "error",
        message => "unable to create profile: $name" );
    }
  }
  $self->_validate_profile( type => $type, name => $name );

  my $dest = $self->profile_path( type => $type, name => $name);
  unless (-d $dest) {
    croak $self->_log( level => "error",
      message => "invalid profile path$ path" );
  }

  if ($self->profile_is_locked( type => $type, name => $name)) {
    croak $self->_log( level => "error",
      message => "cannot restore locked profile" );
  }

  # Note: the guts of this should be moved to a _restore_profile method

  if ($self->{plugin}->open_for_restore($path)) {
    foreach my $file ($self->{plugin}->get_contents) {
      # TODO:
      # - an option for overwriting existing files?
      # - handle relative profile issues!

      unless ($self->{plugin}->restore_file($file, $dest)) {
	croak $self->_log( level => "error", 
          message => "unable to restore files $file" );
      }
    }
    $self->{plugin}->close_restore;
  }
  else {
    croak $self->_log( level => "error",
		       message => "unable to open backup: $path" );
  }

}

# TODO - a separate copy_profile method that copies a profile into another
#        one for the same application

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

There is now a SourceForge project for this module at
L<http://sourceforge.net/projects/mozilla-backup/>

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut




