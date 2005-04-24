=head1 NAME

Mozilla::Backup::Plugin::Zip - A zip archive plugin for Mozilla::Backup

=head1 REQUIREMENTS

The following non-core modules are required:

  Archive::Zip
  Log::Dispatch;
  Mozilla::Backup
  Params::Smart
  Params::Validate;

=head1 SYNOPSIS

  use Mozilla::Backup;

  my $moz = Mozilla::Backup->new(
    plugin => 'Mozilla::Backup::Plugin::Zip'
  );
  
=head1 DESCRIPTION

This is a plugin for Mozilla::Backup which allows backups to be saved
as zip files.

=over

=cut

package Mozilla::Backup::Plugin::Zip;

use strict;

use Archive::Zip;
use Carp;
use File::Spec;
use Log::Dispatch;
use Params::Smart 0.03;
use Params::Validate qw( :all );

# require Mozilla::Backup;

# $Revision: 1.17 $

our $VERSION = '0.02';

=item new

  $plugin = Mozilla::Backup::Plugin::Zip->new( %options );

The following C<%options> are supported:

=over

=item log

The L<Log::Dispatch> objetc used by L<Mozilla::Backup>. This is required.

=item debug

The debug flag from L<Mozilla::Backup>. This is not used at the moment.

=item compression

The desired compression level to use when backing up files, between C<0>
and C<9>.  C<0> means to store (not compress) files, C<1> is for the
fastest method with the lowest compression, and C<9> is for the slowest
method with the fastest compression.  (The default is C<6>.)

See the L<Archive::Zip> documentation for more information on levels.

=back

=cut

my %ALLOWED_OPTIONS = (
    log       => {
                   required => 1,
                   isa      => 'Log::Dispatch',
                 },
    debug     => {
                   default  => 0,
		   type     => BOOLEAN,
                 },

    # This options is intentionally called 'compression' instead of
    # 'compress' so as not to be confused with option in Tar plugin

    compression => {
                   default  => 6,
                   type     => SCALAR,
                   callbacks => {
                     'valid_range' => sub {
                       return (($_[0] >= 0) && ($_[0] <= 9));
                     },
                   },
                 },
);

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = validate( @_, \%ALLOWED_OPTIONS);

  my $self  = {
    log       => $args{log},
    debug     => $args{debug},
    compression => $args{compression},
  };

  return bless $self, $class;
}


=item allowed_options

  @options = Mozilla::Backup::Plugin::Zip->allowed_options();

  if (Mozilla::Backup::Plugin::Zip->allowed_options('debug')) {
    ...
  }

If no arguments are given, it returns a list of configuration parameters
that can be passed to the constructor.  If arguments are given, it returns
true if all of the arguments are allowable options for the constructor.

=cut

sub allowed_options {
  my $class = shift || __PACKAGE__;
  my %args = Params(qw( ?*options ))->args(@_);
  my @opts = @{$args{options}}, if ($args{options});
  if (@opts) {
    my $allowed = 1;
    while ($allowed && (my $opt = shift @opts)) {
      $allowed = $allowed && $ALLOWED_OPTIONS{$opt};
    }
    return $allowed;
  }
  else {
    return (keys %ALLOWED_OPTIONS);
  }
}

=item munge_location

  $filename = $plugin->munge_location( $filename );

Munges the archive name by adding the "zip" extension to it, if it
does not already have it.  If called with no arguments, just returns 
".zip".

=cut

sub munge_location {
  my $self = shift;
  my %args = Params(qw( file ))->args(@_);
  my $file = $args{file} || "";
  $file .= ".zip", unless ($file =~ /\.zip$/i);
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

  $self->{path} = $path;
  $self->{opts} = $args{options};

  $self->_log( level => "debug", message => "creating archive $path\n" );
  return $self->{zip} = Archive::Zip->new();
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

  $self->{path} = $path;
  $self->{opts} = $args{options};

  $self->_log( level => "debug", message => "opening archive $path\n" );
  return $self->{zip} = Archive::Zip->new( $path );
}

=item get_contents

  @files = $plugin->get_contents;

Returns a list of files in the archive.

=cut

sub get_contents {
  my $self = shift;
  return $self->{zip}->memberNames();
}

=item backup_file 

  $plugin->backup_file( $local_file, $internal_name );

Backs up the file in the archive, using C<$internal_name> as the
name in the archive.

=cut

sub backup_file {
  my $self = shift;
  my %args = Params(qw( file ?internal  ))->args(@_);

  my $file = $args{file};                 # actual file
  my $name = $args{internal} || $file;    # name in archive

  $self->_log( level => "info", message => "backing up $name\n" );
  my $member = $self->{zip}->addFileOrDirectory($file, $name);
  $member->desiredCompressionLevel( $self->{compression} );
  return $member;
}

=item restore_file

  $plugin->restore_file( $internal_name, $local_file );

Restores the file from the archive.

=cut

sub restore_file {
  my $self = shift;
  my %args = Params(qw( internal file ))->args(@_);

  my $file = $args{internal};
  my $dest = $args{file} ||
    croak $self->_log( level => "error",
      message => "no destination specified" );

  unless (-d $dest) {
    croak $self->_log( level => "error",
      message => "destination does not exist");
  }

  my $path = File::Spec->catfile($dest, $file);
  if (-e $path) {
    $self->_log( level => "debug", message => "$path exists\n" );
    # TODO: confirmation to overwrite?
  }

  $self->_log( level => "info", message => "restoring $file\n" );
  $self->{zip}->extractMember($file, $path);
  return (-e $path);
}

=item close_backup

  $plugin->close_backup();

Closes the backup.

=cut

sub close_backup {
  my $self = shift;
  my $path = $self->{path};
  $self->_log( level => "debug", message => "saving archive: $path\n" );
  $self->{zip}->writeToFileNamed( $path );
}

=item close_restore

  $plugin->close_restore();

Closes the restore.

=cut

sub close_restore {
  my $self = shift;
  $self->_log( level => "debug", message => "closing archive\n" );
}

=begin internal

=item _log

  $plugin->_log( level => $level, $message => $message );

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

1;

=back

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

