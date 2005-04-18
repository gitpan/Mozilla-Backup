use Module::Build;

my $build = Module::Build->new
    (
     module_name => 'Mozilla::Backup',
     license => 'perl',
     requires => {
       'perl'             => '5.6.0',
       'Carp'             => 0,
       'Archive::Zip'     => 0,
       'Config::IniFiles' => 0,
       'File::Copy'       => 0,
       'File::Find'       => 0,
       'File::Spec'       => 0,
       'File::Temp'       => 0,
       'Log::Dispatch'    => 1.6,
       'Module::Pluggable' => 0,
       'Params::Smart'    => 0.03,
       'Params::Validate' => 0,
     },
     recommends => {
       'Getopt::Long'          => 0,    # for script
       'Log::Dispatch::Screen' => 0,    # for debugging
       'Test::Pod::Coverage'   => 0,    # for tests
       'Test::Pod'             => 1.00,
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

