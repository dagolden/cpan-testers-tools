#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Lucid qw/:all/;
use File::Path qw/mkpath rmtree/;
use File::pushd qw/pushd tempd/;
use Path::Class;

my $suffix = qr{\.(?:tar\.(?:bz2|gz|Z)|t(?:gz|bz)|(?<!ppm\.)zip|pm.gz)$}i; 
my $dist_re = qr{[a-zA-Z]+/.+?$suffix};

my @spec = (
  # required
  Param( "src|S", sub { -e "$_/makeaperl" } )->required,
  Param("old|O", $dist_re)->required,
  Param("new|N", $dist_re)->required,
  Param("dir|D", sub { -d } )->required,
  Param("list|L", sub { -r } )->required,
  # optional
  Param("threads|t"),
  Param("temp|-T"),
  List("extra|x"), 
  Switch("help|h"),
);

my $usage = << "ENDHELP";
usage: $0 <required options> <other options>

REQUIRED OPTIONS:
  --src|-S    DIR       perl source directory
  --old|-O    DISTFILE  older distfile to test ("AUTHOR/TARBALL")
  --new|-N    DISTFILE  newer distfile to test ("AUTHOR/TARBALL")
  --dir|-D    DIR       directory for results
  --list|-L   FILE      file with list of dists to test

OTHER OPTIONS:
  --extra|-x  MOD       extra module to install (can be repeated)
  --temp|-T   DIR       used in place of temporary directory         
  --threads|-t          build perl with threads
  --help|-h             usage guide
ENDHELP

# XXX nasty hack until Getopt::Lucid has better help
if ( grep { /--help|-h/ } @ARGV ) {
  print STDERR "$usage\n" and exit 
}

my $opt = Getopt::Lucid->getopt( \@spec );

main( $opt );
exit;

#--------------------------------------------------------------------------#

sub main {
  my ($opt) = @_;

  # must have CPAN already configured
  die "CPAN must be configured using ~/.cpan/CPAN/MyConfig.pm\n"
    unless -r file( $ENV{HOME}, qw/ .cpan CPAN MyConfig.pm / );

  # make paths absolute before changing directories
  my $perl_src = dir( $opt->get_src )->absolute;
  my $output_dir = dir( $opt->get_dir )->absolute;
  my $list = file($opt->get_list)->absolute;

  # setup temporary work directory
  my $work_dir = $opt->get_temp ? pushd( $opt->get_temp ) 
                                : tempd();
  my $perl_dir = dir($work_dir, 'perl'); 
  my $perl_bin = file($perl_dir, 'bin', 'perl');
  my $old_report_dir = dir ( $output_dir, 'reports-old' );
  my $new_report_dir = dir ( $output_dir, 'reports-new' );
  
  print "*** Working directory is '$work_dir' ***\n";

  # build perl in work directory
  build_perl( $opt, $perl_src, $perl_dir );

  # install CPAN::Reporter::Smoker and extra modules
  my @requires = qw(File::Temp YAML CPAN::SQLite CPAN::Reporter::Smoker);
  for my $mod ( @requires, $opt->get_extra ) {
    cpan_install( $perl_bin, $mod );
  }

  # archive perl directory
  print "*** Archiving perl directory to restore later ***\n";
  system("tar clpf perl.tar perl") 
    and die "Problem archiving perl dir. Stopping.\n"; 

  # smoke_it( old dist )
  smoke_it( $opt, $work_dir, $old_report_dir, $perl_bin, $opt->get_old, $list );

  # restore perl from archive file
  print "*** Restoring perl from archive ***\n";
  eval { rmtree ($perl_dir); 1} 
    or die "Problem removing modified perl directory. Stopping\n";
  system( 'tar xf perl.tar') 
    and die "Problem extracting archived perl directory. Stopping\n";

  # smoke_it( new dist )
  smoke_it( $opt, $work_dir, $new_report_dir, $perl_bin, $opt->get_new, $list );
  
  # compare output directories
  compare_results( $perl_bin, $output_dir, $old_report_dir, $new_report_dir); 

}

sub build_perl {
  my ($opt, $perl_src, $target_dir) = @_;
  my $pd = pushd( $perl_src );
  print "*** Building perl from '$pd' to '$target_dir' ***\n";
  my $config_args="-des -Dprefix=$target_dir";
  $config_args .= " -Dusethreads" if $opt->get_threads;
  system("make realclean");
  system("rm -f config.sh Policy.sh");
  system("sh ./Configure $config_args") 
    and die "Problem with Configuration. Stopping.\n";
  system("make depend") and die "Problem with make depend. Stopping.\n";
  system("make") and die "Problem with make. Stopping\n";
  system("make install") and die "Problem with install. Stopping\n";
}

sub cpan_install {
  my ($perl_bin, $mod) = @_;
  print "*** Installing $mod ***\n";
  local %ENV = (%ENV, _automated_testing_env());
  system("$perl_bin -MCPAN -e 'install(q{$mod})'")
    and die "Problem installing CPAN::Reporter::Smoker. Stopping\n";
  system("$perl_bin -MCPAN -e 'exit !CPAN::Shell->expandany(q{$mod})->uptodate'")
    and die "Could not confirm $mod installed\n";
}

sub smoke_it {
  my ($opt, $work_dir, $result_dir, $perl_bin, $dist, $list) = @_;
  print "*** Preparing to smoke test with $dist ***\n";
  $result_dir = $result_dir->absolute;

  # install regression distfile
  cpan_install( $perl_bin, $dist );

  # create output directory for results
  mkpath( "$result_dir" );

  # set temporary CPAN::Reporter config dir
  my $config_dir = dir( $work_dir , 'cpan-reporter-config', $dist );
  $config_dir->mkpath;
  local $ENV{PERL_CPAN_REPORTER_DIR} = $config_dir;

  # CPAN::Reporter config.ini to save files to output directory
  my $fh = file( $config_dir, 'config.ini' )->openw
    or die "Couldn't create CPAN::Reporter config file; $!\n";
  print {$fh} << "ENDCONFIG";
email_from = nobody\@example.org
transport = File $result_dir
ENDCONFIG

  # smoke the list
  print "*** Smoke testing distributions in '$list' ***\n";
  rmtree( File::Spec->catdir($ENV{HOME}, qw/.cpan build/) );
  system( "$perl_bin -MCPAN::Reporter::Smoker -e 'start(list => q{$list})'" );
  system('stty sane');
  
}

sub compare_results {
  my ($perl_bin, $result_dir, $dir1, $dir2) = @_; 

  my @dir1 = `ls $dir1`;
  my @dir2 = `ls $dir2`;

  my %dir1;
  my %dir2;

  my $checkarch = `$perl_bin -V:archname`;
  my ($archname) = $checkarch =~ m/'([^']+)'/;

  for my $f ( @dir1 ) {
    $f =~ /^(\w+)\.(.+?)\.$archname/;
    $dir1{ $2 } = $1;
  }

  for my $f ( @dir2 ) {
    $f =~ /^(\w+)\.(.+?)\.$archname/;
    $dir2{ $2 } = $1;
  }

  my %dists = map { $_ => 1 } keys %dir1, keys %dir2;

  my $fh = file( $result_dir, 'test-diff.txt' )->openw;

  for my $d ( sort keys %dists ) {
    next if exists $dir1{$d} && exists $dir2{$d} && $dir1{$d} eq $dir2{$d};
    printf {$fh} "%8s %8s %s\n", $dir1{$d}, $dir2{$d}, $d;
  }
}

sub _automated_testing_env {
  return (
    AUTOMATED_TESTING => 1,
    PERL_MM_USE_DEFAULT => 1,
    PERL_EXTUTILS_AUTOINSTALL => '--default-deps',
  );
}

