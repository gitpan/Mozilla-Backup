=head1 NAME

Mozilla::Backup - Backup utility for Mozilla profiles

=begin readme

=head1 REQUIREMENTS

The following non-core modules are required:

  Archive::Tar
  Archive::Zip
  Compress::Zlib
  Config::IniFiles
  File::Temp
  IO::Zlib
  Log::Dispatch
  Module::Pluggable
  Params::Smart
  Regexp::Assemble;
  Regexp::Common
  Return::Value
  Test::More

The Archive::* and *::Zlib modules are used by their respective plugins.

=head1 INSTALLATION

Installation can be done using the traditional Makefile.PL or the newer
Build.PL methods.

Using Makefile.PL:

  perl Makefile.PL
  make test
  make install

(On Windows platforms you should use C<nmake> instead.)

Using Build.PL (if you have Module::Build installed):

  perl Build.PL
  perl Build test
  perl Build install

=end readme

=head1 SYNOPSIS

  $moz = Mozilla::Backup->new();
  $file = $moz->backup_profile("firefox", "default");

=head1 DESCRIPTION

This package provides a simple interface to back up and restore the
profiles of Mozilla-related applications such as Firefox or Thunderbird.

=begin readme

More details are available in the module documentation.

=end readme

=for readme stop

Method calls may use named or positional parameters (named calls are
recommended).  Methods are outlined below:

=cut

package Mozilla::Backup;

use 5.006;
use strict;
use warnings;

use Carp;
# use Config::IniFiles;
use File::Copy qw( copy );
use File::Find;
use File::Spec;
use IO::File;
use Log::Dispatch 1.6;
use Module::Pluggable;
use Mozilla::ProfilesIni;
use Params::Smart 0.04;
use Regexp::Assemble;
use Regexp::Common 1.8 qw( comment balanced delimited );
use Return::Value;

# $Revision: 1.64 $

our $VERSION = '0.06';

# Note: the 'pseudo' profile type is deliberately left out.
#       'minotaur' is obsolete, and so omitted; what about 'phoenix'?

# TODO: add support for Epiphany, SkipStone, and DocZilla, if relevant

my @PROFILE_TYPES = qw(
  beonex camino firefox galeon k-meleon mozilla netscape phoenix
  sunbird thunderbird
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

  $moz->_find_all_profiles()

Attempts to locale the profiles for all known L</profile_types>).

=end internal

=cut

sub _find_all_profiles {
  my $self = shift;

  my $home = $ENV{HOME};
  if ($^O eq "MSWin32") {
    $home  = $ENV{APPDATA} ||
      _catdir($ENV{USERPROFILE}, "Application Data") ||
      _catdir($ENV{WINDIR}, "Profiles", "Application Data") ||
      _catdir($ENV{WINDIR}, "Application Data");

    # Question: is WinDir set for all Windows 9x/WinNT machines? Where
    # is the code that Mozilla uses to determine where the profile
    # should be?

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

  $moz->_load_plugin( $plugin, %options );

Loads a plugin module. It assumes that C<$plugin> contains the full
module name.  C<%options> are passed to the plugin constructor.

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
    croak $self->_log( "Unable to load plugin plugin" );
  }
  else {
    # We check to see if the plugin supports the methods we
    # need. Would it make more sense to have a base class and test
    # isa() instead?

    foreach (qw(
      allowed_options new munge_location open_for_backup open_for_restore
      get_contents backup_file restore_file close_backup close_restore
    )) {
      croak $self->_log( "Plugin does not support $_ method" )
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

Regular expressions can be strings or compiled Regexps.

By default the F<Cache>, <Cache.Trash> folders, XUL cache, mail folders 
cache and lock files are excluded.

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

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = Params(
   {
     name     => "plugin",
     default  => "Mozilla::Backup::Plugin::Zip",
     callback => sub {
       my ($self, $name, $value) = @_;
       croak "expected scalar or array reference"

	 unless ((!ref $value) || (ref($value) eq "ARRAY"));
       return $value;
     },
     name_only => 0,
   },
   {
     name     => "log",
     default  => Log::Dispatch->new(),
     callback => sub {
       my ($self, $name, $log) = @_;
       croak "invalid log sink"
	 unless ((ref $log) && $log->isa("Log::Dispatch"));
       return $log;
     },
     name_only => 1,
   },
   {
     name      => "pseudo",
     default   => "",
     callback  => sub {
       my ($self, $name, $value) = @_;
       $value ||= "";
       croak "invalid pseudo directory"
	 unless (($value eq "") || _catdir($value));
       return $value;
     },
     name_only => 1,
   },
   {
     name      => "debug",
     default   => 0,
     name_only => 1,
   },
   {
     name     => "exclude",
     default  => [
       '^Cache(.Trash)?\/',                # web cache
       'XUL\.(mfl|mfasl)',                 # XUL cache
       'XUL FastLoad File',                # XUL cache 
       '(Invalid|Aborted)\.mfasl',         # Invalidated XUL
       'panacea.dat',                      # mail folder cache
       '(\.parentlock|parent\.lock|lock)', # lock file
     ],
     callback => sub {
       my ($self, $name, $value) = @_;
       $value = [ $value ] unless (ref $value);
       croak "expected scalar or array reference"
	 unless (ref($value) eq "ARRAY");
       local ($_);
       foreach (@$value) {
	 croak "expected regular expression"
	   unless ((!ref $value) || (ref($value) eq "Regexp"));	 
       }
       return $value;
     },
     name_only => 0,
     slurp     => 1,
   },
  )->args(@_);
		     
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
    $self->{log}->add( Log::Dispatch::Screen->new(
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

  beonex
  camino
  firefox
  galeon
  kmeleon
  mozilla
  phoenix
  netscape
  sunbird
  thunderbird

Some of these profile types are for platform-specific or obsolete
applications, so you may never run into them.

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

  $ini = $moz->type( type => $type );

  $ini = $moz->type( $type );

  if ($moz->type( $type )->profile_exists( $name )) { ... }

Returns the L<Mozilla::ProfilesIni> object for the corresponding C<$type>,
or an error if it is invalid.

=cut

sub type {
  my $self = shift;
  my %args = Params(qw( type ))->args(@_);
  my $type = $args{type};
  return $self->{profiles}->{$type} ||
    croak $self->_log(
      "invalid profile type: $type"
    );
}

=item type_exists

  if ($moz->type_exists( type => $type)) { ... }

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

An internal routine used by L</backup_profile>.

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
    return failure
      $self->_log( "$dest exists already" );
  }

  $self->_log( level => "notice", message => "backing up $path\n" );

  unless ($self->{plugin}->open_for_backup( path => $dest)) {
    return failure
      $self->_log( "error creating archive" );
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
              my $r = $self->{plugin}->backup_file($file, $name);
		return failure $self->_log(
		  "error backing up $file: $r" ) unless ($r);
	    }
	  }

	},
       }, $path
      );

  # TODO: check for errors here
  unless ($self->{plugin}->close_backup()) {
    return failure "close_backup failed";
  }

  return success;
}

=item backup_profile

  $file = $moz->backup_profile(
    type         => $type,
    name         => $name,
    destination  => $dest,
    archive_name => $arch,
    relative     => $rel,
  );

  $file = $moz->backup_profile($type,$name,$dest,$arch,$rel);

Backs up the profile as a zip archive to the path specified in C<$dest>.
(If none is given, the current directory is assumed.)

C<$arch> is an optional name for the archive file. If none is given, it
assumes F<type-name-date-time.ext> (for example,
F<mozilla-default-20050426-120000.zip> if the Zip plugin is used.)

C<$rel> is an optional flag to backup files with relative paths instead
of absolute pathnames. It defaults to the value of L</profile_is_relative>
for that profile. (Non-relative profiles will show a warning message.)

If the profile is currently in use, it may not be backed up properly.

This version does no munging of the profile data, nor does it store any
meta information. See L</KNOWN ISSUES> below.

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
    return failure $self->_log( 
      "cannot backup locked profile" );
  }

  my $r = $self->_backup_path(
    profile_path => $prof->profile_path( name => $name ),
    destination  => $back,
    relative     => $relative
  );
  return failure $r unless ($r);

  return $back;
}

=begin internal

=item _archive_name

Returns a default "archive name" appropriate to the plugin type.

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

  $moz->_log( $message, $level );

  $moz->_log( $message => $message, level => $level );

Logs an event to the dispatcher. If C<$level> is unspecified, "error"
is assumed.

=end internal

=cut

sub _log {
  my $self = shift;
  my %args = Params(qw( message ?level="error" ))->args(@_);
  my $msg  = $args{message};

  # we want log messages to always have a newline, but not necessarily
  # the returned value that we pass to carp/croak/return value

  $args{message} .= "\n" unless ($args{message} =~ /\n$/);
  $self->{log}->log(%args) if ($self->{log});
  return $msg;    # when used by carp/croak/return value
}

=begin internal

=item _munge_prefs_js

  $moz->_munge_prefs_js( $profile_path, $prefs_file );

=end internal

=cut

# TODO - test if we really need this. Thunderbird saves the relative
# path info, which we use for munging. But we need to check the
# behavior, since in the case where we copy profiles, we don't want it
# using a valid path but for a different profile.

sub _munge_prefs_js {
  my $self = shift;
  my %args = Params(qw( profile_path ?prefs_file ))->args(@_);
  my $profd    = $args{profile_path};
  my $filename = $args{prefs_file} || _catfile($profd, "prefs.js");

  unless (-d $profd) {
    return failure $self->_log( "Invalid profile path: $profd" );
  }

  unless (-r $filename) {
    return failure $self->_log( "Invalid prefs file: $filename" );
  }

  my $fh = IO::File->new("<$filename")
    || return failure $self->_log( "Unable to open file: $filename" );

  my $buffer = join("", <$fh>);

  close $fh ||
    return failure $self->_log( "Unable to close file: $filename" );

  $buffer =~ s/$RE{comment}{Perl}//g;
  $buffer =~ s/$RE{comment}{JavaScript}//g;

  my %prefs = ( );

  local ($_);
  foreach (split /\n/, $buffer) {
    if ($_ =~ /user_pref($RE{balanced}{-parens=>'()'})\;/) {
      my $args = $1;
      if ($args =~ /\(\s*($RE{delimited}{-delim=>'"'}{-esc})\,\s*(.+)\s*\)/) {
	my ($pref, $val) = ($1, $2);
        $pref = substr($pref,1,-1);
        $prefs{$pref} = $val;
#	print "user_pref(\"$pref\", $val);\n";
      }
      else {
	return failure $self->_log( "Don\'t know how to handle line: $args" );
      }
      
    }
  }

  my $re = Regexp::Assemble->new();
  $re->add(
    qr/^mail\.root\.pop3$/,
    qr/^mail\.server\.server\d+\.(directory|newsrc\.file)$/,
  );

  foreach my $pref (keys %prefs) {
    if ($pref =~ $re->re) {
      if (exists $prefs{$pref."-rel"}) {
	if ($prefs{$pref."-rel"} =~ /\"\[ProfD\](.+)\"/) {
	  my $path = File::Spec->catdir($profd, $1);
          $path =~ s/\\{2,}/\\/g; # unescape multiple slashes
          unless (-e $path) {
            $self->_log( level => "warn",
              message => "Path does not exist: $path", );
          }
          $path =~ s/\\/\\\\/g;   # escape single slashes
          $prefs{$pref} = "\"$path\"";
        }
        else {
          $self->_log( level => "warn",
           message => "Cannot handle $pref-rel key", );
        }
      }
      else {
          $self->_log( level => "warn",
           message => "Cannot find $pref-rel key", );
      }
    }
    elsif ($pref =~ /\.dir$/) {
      # TODO - check if directory exists, and if not, give a warning
    }
  }

  if (keys %prefs) {
    copy($filename, $filename.".backup");
    chmod 0600, $filename.".backup";

    $fh = IO::File->new(">$filename")
      || return failure $self->_log ( "Unable to write to $filename" );

    print $fh "
# Mozilla User Preferences

/* Do not edit this file. 
 * 
 * This file was modified by Mozilla::Backup.
 *
 * The original is at $filename.backup
 */

";

    foreach my $pref (sort keys %prefs) {
      print $fh "user_pref(\"$pref\", $prefs{$pref});\n";
    }

    close $fh || return failure $self->_log( "Unable to close $filename" );
  } else {
    return failure $self->_log( "No preferences to save" );
  }

  return success;
}


=item restore_profile

  $res = $moz->restore_profile(
    archive_path => $backup,
    type         => $type,
    name         => $name,
    is_default   => $is_default,
    munge_prefs  => $munge_prefs, # update prefs.js file
  );

  $res = $moz->restore_profile($backup,$type,$name,$is_default);

Restores the profile at C<$backup>.  Returns true if successful,
false otherwise.

C<$munge_prefs> can only be specified using named parameter calls. If
C<$munge_prefs> is true, then it will attempt to correct any absolute
paths specified in the F<prefs.js> file.

Warning: this does not check that it is the correct profile type. It will
allow you to restore a profile of a different (and possibly incompatible)
type.

Potential incompatabilities with extensions are also not handled.
See L</KNOWN ISSUES> below.

=cut

sub restore_profile {
  my $self = shift;
  my %args =
    Params(qw( archive_path type name ?is_default ?+munge_prefs ))->args(@_);
  my $path = $args{archive_path};
  my $type = $args{type};
  my $name = $args{name};
  my $def  = $args{is_default} || 0;
  my $munge = $args{munge_prefs} || 0;

  my $prof = $self->type( type => $type );

  unless ($prof->profile_exists( name => $name)) {
    $self->_log( level => "info",
       message => "creating new profile: $name\n" );

    unless ($prof->create_profile(
      name       => $name,
      is_default => $def )) {
      return failure $self->_log( "unable to create profile: $name" );
    }
  }
  unless ($prof->profile_exists( name => $name )) {
    return failure $self->_log(
      "unable to create profile: $name"
    );
  }

  my $dest = $prof->profile_path( name => $name );
  unless (-d $dest) {
    return failure $self->_log( "invalid profile path$ path" );
  }

  if ($prof->profile_is_locked( name => $name )) {
    return failure $self->_log( "cannot restore locked profile" );
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
	  return failure $self->_log( "unable to restore files $file" );
	}
      }
    }
    $self->{plugin}->close_restore;

    if ($munge) {
      if (my $filename = _catfile($dest, "prefs.js")) {
	my $r = $self->_munge_prefs_js(
	  profile_path => $dest,
	  prefs_file   => $filename,
	);
        return failure $r unless ($r);
      } else {
	$self->_log( level => "warn", message => "Cannot find prefs.js" );
      }
    }

  }
  else {
    return failure $self->_log( "unable to open backup: $path" );
  }

  return success;
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
    croak $self->_log( 
      "Unrecognized object method \"$meth\" in \"".__PACKAGE__."\"",
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

=for readme continue

=begin readme

=head1 REVISION HISTORY

The following changes have been made since the last release:

=for readme include type=text file=Changes start=0.06 stop=0.05

Details can be found in the Changes file.    

=end readme

=head1 KNOWN ISSUES

This module is a prototype. Use at your own risk!

Not all of the profile types have been tested, and are implemented
based on information gleaned from sources which may or may not be
accurate.

The current version of this module only copies files and does little
manipulation of any files, except for the F<profiles.ini> and F<prefs.js>
to update some pathnames.  This means that information specific to a
profile on a machine such as extensions and themes is kept as-is, which
may not be a good thing if a profile is restored to a different location
or machine, or even application.

(By default cache files are excluded from backups; there may be problems
if cache files are restored to incompatible applications or machines.)

=for readme stop

=head2 To Do List

A list of to-do items, in no particular order:

=over

=item Meta-data

Save meta-data about backups (such as profile type, file locations, platform)
so that file-restoration can make the appropriate conversions.

=item Improved Parameter Checking

Improve parameter type and value checking.

=item Tests

The test suite needs improved coverage. Sample profiles should be included
for more thorough testing.

=item User-friendly Exclusion Lists

User-friendly exclusion lists (via another module?).  Exclusion by categories
(privacy protection, E-mail, Bookmarks, etc.).

=item Standardize Log Messages

Have a standard format (case, puntuation etc.) for log messages. Also
standardize error levels (error, alert, critical, etc.).

Possiblly add hooks for internationalisation of messages.

=item Other

Other "TODO" items marked in source code.

=back

=for readme continue

=head1 SEE ALSO

Mozilla web site at L<http://www.mozilla.org>.

=for readme stop

MozillaZine KnowledgeBase article on Profiles at
L<http://kb.mozillazine.org/Profile>.

Mozilla Profile Service source code at
L<http://lxr.mozilla.org/seamonkey/source/toolkit/profile/src/nsToolkitProfileService.cpp>.

=for readme continue

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head2 Suggestions and Bug Reporting

Feedback is always welcome.  Please use the CPAN Request Tracker at
L<http://rt.cpan.org> to submit bug reports.

There is now a SourceForge project for this module at
L<http://mozilla-backup.sourceforge.net/>.

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut




