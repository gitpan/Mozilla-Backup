=head1 NAME

Mozilla::Backup::Plugin::FileCopy - A file copy plugin for Mozilla::Backup

=head1 REQUIREMENTS

The following non-core modules are required:

  File::Copy;
  Log::Dispatch;
  Mozilla::Backup
  Params::Smart
  Params::Validate;

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
use Params::Smart 0.03;
use Params::Validate qw( :all );

# require Mozilla::Backup;

# $Revision: 1.5 $

our $VERSION = '0.01';

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

my %ALLOWED_OPTIONS = ( map { $_ => 1, } qw(
  log debug
));

sub new {
  my $class = shift || __PACKAGE__;

  my %args  = validate( @_, {
    log       => {
                   required => 1,
                   isa      => 'Log::Dispatch',
                 },
    debug     => {
                   default  => 0,
		   type     => BOOLEAN,
                 },
  });

  my $self  = {
    log       => $args{log},
    debug     => $args{debug},
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
  my $path = File::Spec->rel2abs($args{path});

  $self->{opts} = $args{options};

  $self->_log( level => "debug", message => "creating archive $path\n" );

  mkdir $path;
  return $self->{path} = _catdir($path);
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
  my $path = File::Spec->rel2abs($args{path});
  return $self->{path} = _catdir($path);
}

=item get_contents

  @files = $plugin->get_contents;

Returns a list of files in the archive.

=cut

sub get_contents {
  my $self = shift;

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

  my $file = File::Spec->canonpath($args{file}); # actual file
  my $name = $args{internal} || $file;    # name in archive

  $self->_log( level => "info", message => "backing up $name\n" );

  if (-d $file) {
    my $dest = File::Spec->catdir($self->{path}, $name);
    if ($self->_create_dir($name)) {
      $self->_log( level => "debug", message => "creating $dest\n" );    
      mkdir $dest;
    }
    return _catdir($dest);
  } elsif (-r $file) {
    my $dest = File::Spec->catfile($self->{path}, $name);
    if ($self->_create_dir($name)) {
      $self->_log( level => "debug",
         message => "copying $file to $dest\n" );    

      # TODO - options to copy permissions

      copy($file, $dest)
	|| croak $self->_log( level => "error",
			      message => "copying failed: $!" );
    }
    return _catfile($dest);
  } else {
    croak $self->_log( level => "critical",
		       message => "cannot find file $file" );
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

  my $src = File::Spec->catfile($self->{path}, $file);

  if (-d $src) {
    if ($self->_create_dir($file, $dest)) {
      $self->_log( level => "debug", message => "creating $file\n" );    
      mkdir $path;
    }
    return _catdir($path);
  } elsif (-r $src) {
    if ($self->_create_dir($file, $dest)) {
      $self->_log( level => "debug", message => "copying $file\n" );    

      # TODO - options to copy permissions

      copy($src, $path)
	|| croak $self->_log( level => "error",
			      message => "copying failed: $!" );
    }
    return _catfile($path);
  } else {
    croak $self->_log( level => "critical",
		       message => "cannot find file $src" );
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

=item _catdir

=item _catfile

=end internal

=cut

sub _log {
  my $self = shift;
  my %p    = @_;
  $self->{log}->log(%p);
  return $p{message};    # when used by carp and croak
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

1;

=back

=head1 AUTHOR

Robert Rothenberg <rrwo at cpan.org>

=head1 LICENSE

Copyright (c) 2005 Robert Rothenberg. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

