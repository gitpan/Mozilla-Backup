=head1 NAME

Mozilla::Backup - Backup utility for Mozilla profiles

=head1 REQUIREMENTS

The following non-core modules are required:

  Archive::Tar
  Archive::Zip
  Config::IniFiles
  File::Temp
  Log::Dispatch
  Module::Pluggable
  Params::Smart
  Params::Validate
  Regexp::Assemble;

The Archive::* modules are used by their respective plugins.

=head1 SYNOPSIS

  $moz = Mozilla::Backup->new();
  $file = $moz->backup_profile("firefox", "default");

=head1 DESCRIPTION

This package provides a simple interface to back up and restore the
profiles of Mozilla-related applications such as Firefox or Thunderbird.

The following methods are implemented:

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
use Mozilla::ProfilesIni;
use Params::Smart 0.03;
use Params::Validate qw( :all );
use Regexp::Assemble;

# $Revision: 1.45 $

our $VERSION = '0.05';

# Note: the 'pseudo' profile type is deliberately left out

my @PROFILE_TYPES = qw(
  camino firefox galeon k-meleon mozilla netscape phoenix sunbird thunderbird
);

sub profile_types {
  return @PROFILE_TYPES;
}

sub _catdir {
  goto \&Mozilla::ProfilesIni::_catdir;
}

sub _catfile {
  goto \&Mozilla::ProfilesIni::_catfile;
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
    if (my $path = Mozilla::ProfilesIni::_find_profile_path(
                     home => $home, type => $type)) {
      if (_catfile($path, "profiles.ini")) {
	$self->{profiles}->{$type} =
	  Mozilla::ProfilesIni->new( path => $path, debug => $self->{debug} );
      }
    } else {
    }
  }
  if ($self->{pseudo}) {
    my $pseudo = 
      Mozilla::ProfilesIni->new( path => $self->{pseudo}, create => 1,
				 debug => $self->{debug} );
    $pseudo->create_profile( name => "default", is_default => 1 ),
      unless ($pseudo->profile_exists( name => "default" ));
    $self->{profiles}->{pseudo} = $pseudo;
  }
}


=begin internal

=item _load_plugin

  $moz->_load_plugin( plugin => $plugin, options => \%options );

Loads a plugin module. It assumes that C<$plugin> contains the full
module name.

=end internal

=cut

sub _load_plugin {
  my $self   = shift;
  my %args = Params(qw( plugin *?options ))->args(@_);
  my $plugin = $args{plugin};
  my $opts   = $args{options} || { };

  local ($_);

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

    foreach (qw(
      allowed_options new munge_location open_for_backup open_for_restore
      get_contents backup_file restore_file close_backup close_restore
    )) {
      croak $self->_log( level => "critical",
        message => "Plugin does not support $_ method" )
      unless ($plugin->can($_));
    }

    # We check to see if the plugin accepts certain options

    my %copts = ( );
    foreach (qw( log debug )) {
      $copts{$_} = $self->{$_} if ($plugin->allowed_options($_));
    }
    $self->{plugin} = $plugin->new(%copts,%$opts);
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

=item Mozilla::Backup::Plugin::Tar

Saves the profile in a tar or tar.gz archive.

=back

You may pass options to the plugin in the following manner:

  $moz = Mozilla::Backup->new(
    plugin => [ 'Mozilla::Backup::Plugin::Tar', compress => 1 ],
  );

=item exclude

An array reference of regular expressions for files to exclude from
the backup.  For example,

  $moz = Mozilla::Backup->new(
    exclude => [ '^history', '^Cache' ],
  );

By default the F<Cache> and F<Cache.Trash> folders are excluded.

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
                   type    => SCALAR | ARRAYREF,
                   # we try to load the plugin later
                 },
    exclude   => {
                   default => [ '^Cache(.Trash)?\/' ],
                   type    => ARRAYREF,
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
    profiles  => { },
  };

  local ($_);

  foreach (qw( log debug pseudo exclude )) {
    $self->{$_} = $args{$_};
  }

  bless $self, $class;

  if ($self->{debug}) {
    require Log::Dispatch::Screen;
    $args{log}->add( Log::Dispatch::Screen->new(
      name      => __PACKAGE__,
      min_level => "debug",
      stderr    => 1,
    ));
  }

  {
    my $plugin = $args{plugin};
    my $opts   = [ ];
    if (ref($plugin) eq 'ARRAY') {
      $opts   = $plugin;
      $plugin = shift @{$opts};
    }
    $self->_load_plugin( plugin => $plugin, options => { @$opts } );
  }
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

=item type

  foreach ($moz->type($type)->profile_names) { ... }

Returns the L<Mozilla::ProfilesIni> object for the corresponding C<$type>,
or an error if it is invalid.

=cut

sub type {
  my $self = shift;
  my %args = Params(qw( type ))->args(@_);
  my $type = $args{type};
  return $self->{profiles}->{$type} ||
    croak $self->_log(
      level   => "error",
      message => "invalid profile type: $type"
    );
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


  my $exclude = Regexp::Assemble->new( debug => $self->{debug} );
  $exclude->add( @{$self->{exclude}} );

  find({
	bydepth    => 1,
	wanted     => sub {
	  my $file = $File::Find::name;
	  my $name = $relative ? substr($file, length($path)) : $file;
	  if ($name) {
	    $name = substr($name,1); # remove initial '/'

	    unless ($name =~ $exclude->re) {
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

  my $prof = $self->type( type => $type );

  my $dest = $args{destination}  || '.';
  my $arch = $args{archive_name} ||
    $self->_archive_name( type => $type, name => $name);

  # TODO - if destination includes a file name, use it. The plugin
  # should have methods for parsing destination appropriate to the
  # backup method.

  my $back = File::Spec->catfile($dest, $arch);

  # This needs to be rethought here. IsRelative refers to the Path in
  # the .ini file being relative, but does it also refer to locations
  # from within the profile being stored relatively? Not sure here.

  my $relative = $args{relative};

  $relative = $prof->profile_is_relative( name => $name )
    unless (defined $relative);

  unless ($relative) {
    $self->_log( level => "notice",
      message => "backup will not use relative pathnames\n" );
  }

  if ($prof->profile_is_locked( name => $name )) {
    croak $self->_log( level => "error",
      message => "cannot backup locked profile" );
  }

  $self->_backup_path(
    profile_path => $prof->profile_path( name => $name ),
    destination  => $back,
    relative     => $relative
  );
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

  # We don't really care about validating profile types and names
  # here. If it's invalid, so what. We just have a name that doesn't
  # refer to any actual profiles.

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
  my $msg  = $p{message};

  # we want log messages to always have a newline, but not necessarily
  # the returned value that we pass to carp and croak

  $p{message} .= "\n" unless ($p{message} =~ /\n$/);
  $self->{log}->log(%p) if ($self->{log});
  return $msg;    # when used by carp and croak
}

=item restore_profile

  $moz->restore_profile($backup, $type, $name, $is_default);

Restores the profile at C<$backup>.

Warning: this does not check that it is the correct profile type. It will
allow you to restore a profile of a different (and possibly incompatible)
type.

It also does not (yet) modify explicit directory settings in the
F<prefs.js> file in a profile (such as those used by "Thunderbird").

Potential incompatabilities with extensions are also not handled.

=cut

# TODO - method to munge directory settings in prefs.js for the following:
#   mail.root.pop3
#   mail.server.server(\d+).directory
#   mail.server.server(\d+).newsrc.file
# There are other fiels such as attach directories and values specific to
# extensions.  These are not easy to identify and update. 

sub restore_profile {
  my $self = shift;
  my %args = Params(qw( archive_path type name ?is_default ))->args(@_);
  my $path = $args{archive_path};
  my $type = $args{type};
  my $name = $args{name};
  my $def  = $args{is_default} || 0;

  my $prof = $self->type( type => $type );

  unless ($prof->profile_exists( name => $name)) {
    $self->_log( level => "info",
       message => "creating new profile: $name\n" );

    unless ($prof->create_profile(
      name       => $name,
      is_default => $def )) {
      croak $self->_log( level => "error",
        message => "unable to create profile: $name" );
    }
  }
  unless ($prof->profile_exists( name => $name )) {
    croak $self->_log(
      level   => "critical",
      message => "unable to create profile: $name"
    );
  }

  my $dest = $prof->profile_path( name => $name );
  unless (-d $dest) {
    croak $self->_log( level => "error",
      message => "invalid profile path$ path" );
  }

  if ($prof->profile_is_locked( name => $name )) {
    croak $self->_log( level => "error",
      message => "cannot restore locked profile" );
  }

  # Note: the guts of this should be moved to a _restore_profile method

  my $exclude = Regexp::Assemble->new( debug => $self->{debug} );
  $exclude->add( @{$self->{exclude}} );

  if ($self->{plugin}->open_for_restore($path)) {
    foreach my $file ($self->{plugin}->get_contents) {
      # TODO:
      # - an option for overwriting existing files?
      # - handle relative profile issues!

      unless ($file =~ $exclude->re) {
	unless ($self->{plugin}->restore_file($file, $dest)) {
	  croak $self->_log( level => "error", 
            message => "unable to restore files $file" );
	}
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

our $AUTOLOAD;

sub AUTOLOAD {
  my $self  = shift;
  $AUTOLOAD =~ /.*::(\w+)/;
  my $meth  = $1;
  if (Mozilla::ProfilesIni->can($meth)) {
    carp $self->_log(
      level => "warn",
      message => "Warning: deprecated method \"$meth\"",
    );
    if ($_[0] eq "type") {
      my %args = @_;
      my $type = $args{type}; delete $args{type};
      return $self->type(type => $type)->$meth(%args);
    }
    else {
      my @args = @_;
      my $type = shift @args;
      return $self->type(type => $type)->$meth(@args);
    }
  }
  else {
    croak $self->_log( level => "error",
      message => "Unrecognized object method \"$meth\" in \"".__PACKAGE__."\"",
    );
  }
}

# Otherwise AUTOLOAD looks for a DESTROY method

sub DESTROY {
  my $self = shift;
  undef $self;
}

1;

=back

=head2 Compatabilty with Earlier Versions

The interface has been changed from version 0.04. Various methods for
querying profile information were moved into the L<Mozilla::ProfilesIni>
module.  Code that was of the form

  $moz->method($type,$name);

should be changed to

  $moz->type($type)->method($name);

The older method calls should still work, but are deprecated and will
issue warnings.  (Support for them will be removed in some future
version.)

See the L</type> method for more information.

=head1 CAVEATS

This module is a prototype. Use at your own risk!

Not all of the profile types have been tested, and are implemented
based on information gleaned from sources which may or may not be
accurate.

=head1 SEE ALSO

Mozilla web site at L<http://www.mozilla.org>.

Mozilla Profile Service source code at
L<http://lxr.mozilla.org/seamonkey/source/toolkit/profile/src/nsToolkitProfileService.cpp>.

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




