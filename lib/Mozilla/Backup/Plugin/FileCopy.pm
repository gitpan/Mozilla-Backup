=head1 NAME

Mozilla::Backup::Plugin::FileCopy - A file copy plugin for Mozilla::Backup

=begin readme

=head1 REQUIREMENTS

The following non-core modules are required:

  File::Copy;
  Log::Dispatch;
  Mozilla::Backup
  Mozilla::ProfilesIni;
  Params::Smart
  Return::Value;

=end readme

=head1 SYNOPSIS

  use Mozilla::Backup;

  my $moz = Mozilla::Backup->new(
    plugin => 'Mozilla::Backup::Plugin::FileCopy'
  );
  

=head1 DESCRIPTION

This is a plugin for Mozilla::Backup which copies profiles to another
directory.

=over

=cut

package Mozilla::Backup::Plugin::FileCopy;

use strict;

use Carp;
use File::Copy;
use File::Find;
use File::Spec;
use Log::Dispatch;
use Mozilla::ProfilesIni;
use Params::Smart 0.04;
use Return::Value;

# require Mozilla::Backup;

# $Revision: 1.16 $

our $VERSION = '0.03';

=item new

  $plugin = Mozilla::Backup::Plugin::FileCopy->new( %options );

The following C<%options> are supported:

=over

=item log

The L<Log::Dispatch> objetc used by L<Mozilla::Backup>. This is required.

=item debug

The debug flag from L<Mozilla::Backup>. This is not used at the moment.

=back

=cut

# TODO - option to preserve file perms/ownership, which should be
# enabled by default.  Possibly specify a callback to run on each
# copied file?

my @ALLOWED_OPTIONS = (
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
     required  => 1,
   },
   {
     name      => "debug",
     default   => 0,
     name_only => 1,
   },
);

sub new {
  my $class = shift || __PACKAGE__;
  my %args  = Params(@ALLOWED_OPTIONS)->args(@_);

  my $self  = {
    log       => $args{log},
    debug     => $args{debug},
    status    => "closed",
  };

  return bless $self, $class;
}

=item allowed_options

  @options = Mozilla::Backup::Plugin::FileCopy->allowed_options();

  if (Mozilla::Backup::Plugin::FileCopy->allowed_options('debug')) {
    ...
  }

If no arguments are given, it returns a list of configuration parameters
that can be passed to the constructor.  If arguments are given, it returns
true if all of the arguments are allowable options for the constructor.

=cut

sub allowed_options {
  my $class = shift || __PACKAGE__;
  my %args = Params(qw( ?*options ))->args(@_);

  my %allowed = map { $_->{name} => 1, } @ALLOWED_OPTIONS;

  my @opts = @{$args{options}}, if ($args{options});
  if (@opts) {
    my $allowed = 1;
    while ($allowed && (my $opt = shift @opts)) {
      $allowed = $allowed && $allowed{$opt};
    }
    return $allowed;
  }
  else {
    return (keys %allowed);
  }
}

=item munge_location

  $directory = $plugin->munge_location( $directory );

Munges the backup location name for use by this plugin. (Currently
has no effect.)

=cut

sub munge_location {
  my $self = shift;
  my %args = Params(qw( file ))->args(@_);
  my $file = $args{file} || "";
  return $file;
}

=item open_for_backup

  if ($plugin->open_for_backup( $filename, %options )) {
    ...
  }

Creates a new archive for backing the profile. C<$filename> is the
name of the archive file to be used. C<%options> are optional 
configuration parameters.

=cut

sub open_for_backup {
  my $self = shift;
  my %args = Params(qw( path ?*options ))->args(@_);

  unless ($self->{status} eq "closed") {
    return failure $self->_log( 
      "cannot create archive: status is \"$self->{status}\"" );
  }

  my $path = File::Spec->rel2abs($args{path});

  $self->{opts} = $args{options};

  $self->_log( level => "debug", message => "creating archive $path\n" );

  mkdir $path;
  chmod 0700, $path;
  if ($self->{path} = _catdir($path)) {
    $self->{status} = "open for backup";
    return success;
  }
  else {
    return failure $self->_log( 
      "unable to create path: \"$path\"", );
  }

}

=item open_for_restore

  if ($plugin->open_for_restore( $filename, %options )) {
    ...
  }

Opens an existing archive for restoring the profile.

=cut

sub open_for_restore {
  my $self = shift;
  my %args = Params(qw( path ?*options ))->args(@_);

  unless ($self->{status} eq "closed") {
    return failure $self->_log( 
      "cannot open archive: status is \"$self->{status}\"" );
  }

  my $path = File::Spec->rel2abs($args{path});

  if ($self->{path} = _catdir($path)) {
    $self->{status} = "open for restore";
    return success;
  }
  else {
    return failure $self->_log( "cannot find archive: \"$path\"" );
  }
}

=item get_contents

  @files = $plugin->get_contents;

Returns a list of files in the archive.

=cut

sub get_contents {
  my $self = shift;

  unless ($self->{status} ne "closed") {
    return failure $self->_log( 
      "cannot get contents: status is \"$self->{status}\"" );
  }

  my $path  = $self->{path};
  my @files = ( );

  find({
	bydepth    => 1,
	wanted     => sub {
	  my $file = $File::Find::name;
	  my $name = substr($file, length($path));
	  if ($name) {
	    $name = substr($name,1); # remove initial '/'
	    {
	      $name .= '/' if (-d $file);
	      push @files, $name;
	    }
	  }

	},
       }, $path
      );

  unless (@files) {
    carp $self->_log( level => "warn",
      message => "no files in backup" );
  }

  return @files;
}

=item backup_file 

  $plugin->backup_file( $local_file, $internal_name );

Backs up the file in the archive, using C<$internal_name> as the
name in the archive.

=cut

sub backup_file {
  my $self = shift;
  my %args = Params(qw( file ?internal  ))->args(@_);

  unless ($self->{status} eq "open for backup") {
    return failure $self->_log( 
      "cannot backup file: status is \"$self->{status}\"" );
  }

  my $file = File::Spec->canonpath($args{file}); # actual file
  my $name = $args{internal} || $file;    # name in archive

  $self->_log( level => "info", message => "backing up $name\n" );

  if (-d $file) {
    my $dest = File::Spec->catdir($self->{path}, $name);
    if ($self->_create_dir($name)) {
      $self->_log( level => "debug", message => "creating $dest\n" );    
      mkdir $dest;
      chmod 0700, $dest;
    }
    return failure "directory $dest not found" unless (_catdir($dest));
    return success;
  } elsif (-r $file) {
    my $dest = File::Spec->catfile($self->{path}, $name);
    if ($self->_create_dir($name)) {
      $self->_log( level => "debug",
         message => "copying $file to $dest\n" );    

      # TODO - options to copy permissions

      copy($file, $dest)
	|| return failure $self->_log( "copying failed: $!" );
    }
    return failure "file $dest not found" unless (_catfile($dest));
    return success;
  } else {
    return failure $self->_log( "cannot find file $file" );
  }
}

=begin internal

=item _create_dir

  if ($plugin->_create_dir($name, $root)) {
    ...
  }

Creates deep directories. (This may be removed in future versions.)

=end internal

=cut

sub _create_dir {
  my $self = shift;
  my $name = shift;
  my $root = shift || $self->{path};

  my @dirs = File::Spec->splitdir($name);
  my $file = pop @dirs;

  foreach my $dir ("", @dirs) {
    $root = File::Spec->catdir($root, $dir);
    unless (-d $root) {
      $self->_log( level => "debug", message => "creating $root\n" );    
      mkdir $root;
      chmod 0700, $root;
    }
  }
  return _catdir($root) ? $file : undef;
}


=item restore_file

  $plugin->restore_file( $internal_name, $local_file );

Restores the file from the archive.

=cut

sub restore_file {
  my $self = shift;
  my %args = Params(qw( internal file ))->args(@_);

  unless ($self->{status} eq "open for restore") {
    return failure $self->_log( 
      "cannot restore file: status is \"$self->{status}\"" );
  }

  my $file = $args{internal};
  my $dest = $args{file} ||
    return failure $self->_log( "no destination specified" );

  unless (-d $dest) {
    return failure $self->_log( "destination does not exist" );
  }

  my $path = File::Spec->catfile($dest, $file);
  if (-e $path) {
    $self->_log( level => "debug", message => "$path exists\n" );
    # TODO: confirmation to overwrite?
  }

  $self->_log( level => "info", message => "restoring $file\n" );

  my $src = File::Spec->catfile($self->{path}, $file);

  if (-d $src) {
    if ($self->_create_dir($file, $dest)) {
      $self->_log( level => "debug", message => "creating $file\n" );    
      mkdir $path;
      chmod 0700, $path;
    }
    return failure "directory $path not found" unless (_catdir($path));
    return success;
  } elsif (-r $src) {
    if ($self->_create_dir($file, $dest)) {
      $self->_log( level => "debug", message => "copying $file\n" );    

      # TODO - options to copy permissions

      copy($src, $path)
	|| return failure $self->_log( "copying failed: $!" );
      chmod 0600, $path;
    }
    return failure "file $path not found" unless (_catfile($path));
    return success;
  } else {
    return failure $self->_log( "cannot find file $src" );
  }
}

=item close_backup

  $plugin->close_backup();

Closes the backup.

=cut

sub close_backup {
  my $self = shift;
  my $path = $self->{path};
  $self->_log( level => "debug", message => "closing archive\n" );
  $self->{status} = "closed";
  return success;
}


=item close_restore

  $plugin->close_restore();

Closes the restore.

=cut

sub close_restore {
  my $self = shift;
  $self->_log( level => "debug", message => "closing archive\n" );
  $self->{status} = "closed";
  return success;
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

=item _catdir

=item _catfile

=end internal

=cut

sub _catdir {
  goto \&Mozilla::ProfilesIni::_catdir;
}

sub _catfile {
  goto \&Mozilla::ProfilesIni::_catfile;
}

1;

=back

=head1 EXAMPLES

=head2 Creating archvies other than zip or tar.gz

If you would like to create backups in a format for which no plugin
is available, you can use Mozilla::Backup::Plugin::FileCopy with a
system call to the appropriate archiver. For example,

  $moz = Mozilla::backup->new(
    plugin => "Mozilla::Backup::Plugin::FileCopy",
  );

  $dest = $moz->backup_profile(
    type => "firefox",
    name => "default",
  );

  system("tar cf - $dest |bzip2 - > firefox-default-profile.tar.bz2");

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

