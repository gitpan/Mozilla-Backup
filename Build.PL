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
       'File::Find'       => 0,
       'File::Spec'       => 0,
       'Log::Dispatch'    => 1.6,
       'Params::Validate' => 0,
     },
     recommends => {
#        'Test::Pod::Coverage' => 0,
#        'Test::Pod'      => 1.00,
#        'Test::Prereq'   => 0,
     },
     build_requires => {
       'File::Temp'     => 0,
       'Test::More'     => 0,
     },
     create_readme      => 1,
     create_makefile_pl => 'traditional',
     dist_author        => 'Robert Rothenberg <rrwo at cpan.org>',
     sign               => 1,
);

$build->create_build_script;

