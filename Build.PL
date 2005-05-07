# $Revision: 1.20 $

use Module::Build;

my $build = Module::Build->new
    (
     module_name => 'Mozilla::Backup',
     license => 'perl',
     requires => {
       'perl'             => '5.6.0',
       'Carp'             => 0,
       'Archive::Tar'     => 0,
       'Archive::Zip'     => 0,
       'Compress::Zlib'   => 0,         # for Archive::Zip and IO::Zlib 
       'Config::IniFiles' => 0,
       'File::Copy'       => 0,
       'File::Find'       => 0,
       'File::Spec'       => 0,
       'File::Temp'       => 0,
       'IO::File'         => 0,
       'IO::Zlib'         => 0,         # for Archive::Tar
       'Log::Dispatch'    => 1.6,
       'Module::Pluggable' => 0,
       'Params::Smart'    => 0.05,
       'Regexp::Assemble' => 0,
       'Regexp::Common'   => 1.8,
       'Return::Value'    => 0,
     },
     recommends => {
       'Getopt::Long'          => 0,    # for script
       'Log::Dispatch::Screen' => 0,    # for debugging
       'Pod::Readme'           => 0.02, # for generating distro
       'Test::Pod::Coverage'   => 0,    # for tests
       'Test::Pod'             => 1.00,
       'Test::Portability::Files' => 0,
#        'Test::Prereq'   => 0,
     },
     build_requires => {
       'Test::More'     => 0,
     },
     script_files       => [
       'bin/mozback',
     ],
     create_readme      => 0,
     create_makefile_pl => 'traditional',
     dist_author        => 'Robert Rothenberg <rrwo at cpan.org>',
     sign               => 1,
);

$build->create_build_script;

