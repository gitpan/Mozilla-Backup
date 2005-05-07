=head1 NAME

Mozilla::Backup::Plugin::Tar - A tar archive plugin for Mozilla::Backup

=begin readme

=head1 REQUIREMENTS

The following non-core modules are required:

  Archive::Tar
  Compress::Zlib
  IO::Zlib
  Log::Dispatch;
  Mozilla::Backup
  Params::Smart
  Return::Value;

=end readme

=head1 SYNOPSIS

  use Mozilla::Backup;

  my $moz = Mozilla::Backup->new(
    plugin => 'Mozilla::Backup::Plugin::Tar'
  );
  
=head1 DESCRIPTION

This is a plugin for Mozilla::Backup which allows backups to be saved
as tar files.

=over

=cut

package Mozilla::Backup::Plugin::Tar;

use strict;

use Archive::Tar;
use Carp;
use File::Spec;
use Log::Dispatch;
use Params::Smart 0.04;
use Return::Value;

# Actually, IO::Zlib is not required unless we want to support the
# gzip option. However, Archive::Zip requires Compress::Zlib, which
# IO::Zlib requires. So we may as well require it.

# require Mozilla::Backup;

# $Revision: 1.11 $

our $VERSION = '0.02';

=item new

  $plugin = Mozilla::Backup::Plugin::Tar->new( %options );

The following C<%options> are supported:

=over

=item log

The L<Log::Dispatch> objetc used by L<Mozilla::Backup>. This is required.

=item debug

The debug flag from L<Mozilla::Backup>. This is not used at the moment.

=item compress

Compress the archive when saving. Enabled by default.

=back

=cut

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
     name      => "compress",
     default   => 1,
     name_only => 1,
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
    compress  => $args{compress},
    status    => "closed",
  };

  $Archive::Tar::DEBUG = 1 if ($self->{debug});

  return bless $self, $class;
}


=item allowed_options

  @options = Mozilla::Backup::Plugin::Tar->allowed_options();

  if (Mozilla::Backup::Plugin::Tar->allowed_options('debug')) {
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

  $filename = $plugin->munge_location( $filename );

Munges the archive name by adding the "tar" or "tar..gz" extension to it,
if it does not already have it.  If called with no arguments, just returns 
".tar" or ".tar.gz" (depending on whether the L</compress> option is given).

=cut

sub munge_location {
  my $self = shift;
  my %args = Params(qw( file ))->args(@_);
  my $file = $args{file} || "";

  my $ext  = ".tar";
     $ext .= ".gz" if ($self->{compress});

  $file .= $ext, unless ($file =~ /$ext$/i);
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
  my $path = $args{path};

  unless ($self->{status} eq "closed") {
    return failure $self->_log( 
      "cannot create archive: status is \"$self->{status}\"" );
  }

  $self->{path} = $path;
  $self->{opts} = $args{options};

  $self->_log( level => "debug", message => "creating archive $path\n" );

  if ($self->{tar} = Archive::Tar->new()) {
    $self->{status} = "open for backup";
    return success;
  }
  else {
    return failure $self->_log( "unable to create archive" );
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
  my $path = $args{path};

  unless ($self->{status} eq "closed") {
    return failure $self->_log(
      "cannot open archive: status is \"$self->{status}\"" );
  }

  $self->{path} = $path;
  $self->{opts} = $args{options};

  $self->_log( level => "debug", message => "opening archive $path\n" );
  if ($self->{tar} = Archive::Tar->new( $path, $self->{compress} )) {
    $self->{status} = "open for restore";
    return success;
  }
  else {
    return failure $self->_log( "unable to open archive" );
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

  return $self->{tar}->list_files();
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

  my $file = $args{file};                 # actual file
  my $name = $args{internal} || $file;    # name in archive

  $self->_log( level => "info", message => "backing up $name\n" );
  if ($self->{tar}->add_files($file)) {
    my $nix_name = $file;
      $nix_name =~ tr|\\|\/|;
    if ($self->{tar}->rename($nix_name, $name)) {
      return success;
    }
    else {
      return failure $self->_log( "rename failed for $nix_name to $name" );
    }
  } else {
    # TODO - error in debug
    return failure $self->_log( "unable to add file" );
  }
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
    return failure $self->_log( 
      "no destination specified" );

  unless (-d $dest) {
    return failure $self->_log( "destination does not exist" );
  }

  my $path = File::Spec->catfile($dest, $file);
  if (-e $path) {
    $self->_log( level => "debug", message => "$path exists\n" );
    # TODO: confirmation to overwrite?
  }

  $self->_log( level => "info", message => "restoring $file\n" );
  $self->{tar}->extract_file($file, $path);
  unless (-e $path) {
    return failure $self->_log( "extract failed" );
  }
  return success;
}

=item close_backup

  $plugin->close_backup();

Closes the backup.

=cut

sub close_backup {
  my $self = shift;

  unless ($self->{status} eq "open for backup") {
    return failure $self->_log( 
      "cannot close archive: status is \"$self->{status}\"" );
  }


  my $path = $self->{path};
  $self->_log( level => "debug", message => "saving archive: $path\n" );

  if ($self->{tar}->write( $path, $self->{compress} )) {
    $self->{status} = "closed";
    return success;
  }
  else {
    return failure $self->_log( "write $path failed" );
  }
}

=item close_restore

  $plugin->close_restore();

Closes the restore.

=cut

sub close_restore {
  my $self = shift;

  unless ($self->{status} eq "open for restore") {
    return failure $self->_log( 
      "cannot close archive: status is \"$self->{status}\"" );
  }

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


1;

=back

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

