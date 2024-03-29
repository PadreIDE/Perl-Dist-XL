package Perl::Dist::XL;
use strict;
use warnings;
use 5.008;

use Cwd            qw(cwd);
use CPAN::Mini     ();
use Data::Dumper   qw(Dumper);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use File::HomeDir  ();
use File::Path     qw(rmtree mkpath);
use File::Temp     qw(tempdir);
use LWP::Simple    qw(getstore mirror);

our $VERSION = '0.03';

sub perl_dev  { '5.11.4' }
sub perl_prod { '5.10.1' }
sub perl_version { return $_[0]->{perl} eq 'dev' ? perl_dev() : perl_prod(); }

=head1 NAME

Perl::Dist::XL - Perl distribution for Linux

=head1 SYNOPSIS

The primary objective is to generate an already compiled perl distribution 
that Padre was already installed in so people can download it, unzip it
and start running Padre.

=head1 DESCRIPTION

=head2 Process plan

1] Download
  1) check if the version numbers listed in the file are the latest from cpan and report the differences
  2) Download the additional files needed (e.g. wxwidgets)

2] Building in steps and on condition
  1) build perl - if it is not built yet
  2) foreach module
     if it is not yet in the distribution
     unzip it
     run perl Makefile.PL or perl Build.PL and check for errors
     make; make test; make install

   have special case for Alien::wxWidgets to build from a downloaded version of wxwidgets

TODO: create snapsshots at the various steps of the build process so
      we can restart from there

TODO: eliminate the need for Module::Install or reduce the dependency to 0.68 
as only that is available in 8.04.3

TODO: list the actual versions of CPAN modules used and add this list to distributed perl

TODO: allow the (optional) use of the development version of wxWidgets

TODO: fetch the list of modules installed from 
      $self->{perl_install_dir}/lib/$perl_version/i686-linux-thread-multi/perllocal.pod


=head2 Plan 2

1) Full Mini-CPAN mirror + Perl + wxWidgets

2) build Perl

3) Configure CPAN client

4a) Install Alien::wxWidgets

4b) Install Wx

4c) Install Padre

Install Plugins: Perl 6, Catalyst








=head2 Building on Ubuntu 8.04.3 or 9.10

  sudo aptitude install subversion vim libfile-homedir-perl libmodule-install-perl 
  sudo aptitude install libcpan-mini-perl perl-doc libgtk2.0-dev g++

  svn co https://github.com/PadreIDE/Perl-Dist-XL/
  cd Perl-Dist-XL
  perl script/perldist_xl.pl --download 
  perl script/perldist_xl.pl --clean
  perl script/perldist_xl.pl --build all

TODO: set perl version number (and allow command line option to configure it)

=head2 Building on perl 5.11.3

Pod-POM-0.25 warned about 
   defined(%hash) is deprecated at .../perl/lib/site_perl/5.11.3/Pod/POM/Node.pm line 82.
and one of our modules checked for warnings I patched it after installation. REPORTED to author

Pod::Abstract 0.19 warned about
  UNIVERSAL->import is deprecated and will be removed in a future perl 
   at ..../perl/lib/site_perl/5.11.3/Pod/Abstract/Path.pm line 7
and one of our modules checked for warnings I patched it after installation. REPORTED to author who fixed it

CPAN::Inject 0.11 failed as ~/.perldist_xl/perl-5.11.3-xl-0.03/perl/.cpan/sources directory did not exist.
I had to create it manually. (now included in build cpan)

Test::Exception 0.27 - one of the tests failed. I force installed the module and REPORTED to the
author and to p5p.

I had to patch t/71-perl.t of Padre due to a change in a warning perl gives.
(change in Padre SVN as well after 0.53 was released)

=head2 Building Padre 0.55 on perl 5.11.4

Pod-POM-0.25 warned about 
   defined(%hash) is deprecated at .../perl/lib/site_perl/5.11.3/Pod/POM/Node.pm line 82.
and one of our modules checked for warnings I patched that file after installation.

I had CPAN::Inject issue again but fixed in Perl::Dist::XL so it should not happen next time

Plugins:

PerlCritic installed

PerlTidy installed

Perl 6

  Cannot install because of the YAML::LibYAML 0.32 failure

Catalyst

  Cannot install because of Devel::Caller 2.03 fails to install

Plack



=head2 Plans

Once the primary objective is reached we can consider adding more modules
to include all the Padre Plugins, the EPO recommendations and all the 
none-windows specific modules that are in Strawberry Perl.

We can also consider including the C level libraries and tool to make sure
further CPAN modules can be installed without additional configuration.


Version control: Currently we just install the latest version of
each module in XLPerl. We could make sure we know exactly which version
of each module we install and upgrade only under control.

=cut

sub new {
	my ($class, %args) = @_;

	my @steps = get_steps();
	#if ($args{build}) {
	#	my $build = $args{build};
	#	my %b = map {$_ => 1} @$build;
	#	$args{build} = \%b;
	#	if ($args{build}{all}) {
	#		$args{build}{$_} = 1 for @steps;
	#	}
	#}

	my $self = bless \%args, $class;

	$self->{cwd} = cwd;

	if (not $self->{dir}) {
		my $home    = File::HomeDir->my_home;
		$self->{dir} = "$home/.perldist_xl";
	}
	mkpath("$self->{dir}/src") if not -e "$self->{dir}/src";
	debug("directory: $self->{dir}");

	$self->{perl_install_dir} = $self->dir . '/' . $self->release_name  . '/perl/';
	return $self;
}
DESTROY {
	my ($self) = @_;
	chdir $self->{cwd};
	debug("Done");
}

sub run {
	my ($self) = @_;

	$self->download    if $self->{download} or $self->{mirror};
	$self->clean       if $self->{clean};

	if ($self->{module}) {
		$self->install_modules( [$self->{module}] );
	}

	if ($self->{build}) {
		$self->build_perl     if $self->{build} eq 'perl';
		$self->configure_cpan if $self->{build} eq 'cpan';

		# Needed by Alien::wxWidgets
		my $dir = $self->dir . "/src";
		$ENV{AWX_URL} = "file:///$dir";

		my %modules = steps();
		if ($modules{$self->{build}} ) {
			#print join "|", @{ $modules{$self->{build}} };
			$self->install_modules( $modules{$self->{build}} );
		}
	}


	# TODO: run some tests
	$self->create_zip  if $self->{zip};
	# TODO: unzip and in some other place and run some more tests

	return;
}

sub build_perl {
	my ($self) = @_;

	my $build_dir = $self->dir_build;
	mkdir $build_dir if not -e $build_dir;
	my $dir       = $self->dir;

	chdir $build_dir;
	my $perl_src_file = $self->perl_file;
	my $perl_no_ext   = $self->perl_file_no_ext;
	$self->{perl_source_dir} = "$build_dir/$perl_no_ext";
	debug("Perl source dir: $self->{perl_source_dir}");

	if (not -e $self->{perl_source_dir}) {
		my $flags = $perl_src_file =~ /bz2$/ ? 'xjf' : 'xzf';
		_system("tar $flags $dir/src/$perl_src_file");
	}

	chdir $self->{perl_source_dir};
	my $cmd = "sh Configure -Dusethreads -Duserelocatableinc -Dprefix='$self->{perl_install_dir}' -de";
	$cmd .= " -Dusedevel" if $self->{perl} ne 'stable';
	_system($cmd);
	_system("make");
	_system("make test");
	_system("make install");

	my $perl = "$self->{perl_install_dir}/bin/perl";
	my $src  = "$self->{perl_install_dir}/bin/perl" . $self->perl_version;
	copy($src, $perl);
	chmod 0755, $perl;

	return;
}

sub configure_cpan {
	my ($self) = @_;
	
	# TODO not from cwd ?
	# TODO eliminate this horrible patch!
	#for my $from ("$self->{cwd}/share/files/mycpan.pl", "$self->{cwd}/share/files/mycpan_core.pl") {
	#for my $from ("$self->{cwd}/share/files/mycpan.pl") {
	#	my $to   = $self->{perl_install_dir} . '/bin/';
	#	debug("copy '$from', '$to'");
	#	copy $from, $to;
	#}

	process_template (
		"$self->{cwd}/share/files/mycpan.pl.tmpl", 
		"$self->{perl_install_dir}/bin/mycpan.pl",
	);

	# TODO: make this a template, replace perl version number in file!
	process_template (
		"$self->{cwd}/share/files/padre.sh.tmpl",
		"$self->{perl_install_dir}/bin/padre.sh",
		PERL_VERSION => $self->perl_version,
	);
	chmod 0755, "$self->{perl_install_dir}/bin/padre.sh";

	process_template(
		"$self->{cwd}/share/files/Config.pm.tmpl",
		"$self->{perl_install_dir}.cpan/CPAN/Config.pm",

		URL => 'file://' . $self->minicpan,
	);
	mkpath "$self->{perl_install_dir}/.cpan/sources";

	return;
}

sub process_template {
	my ($from, $to, %map) = @_;
	
	mkpath dirname($to);
	open my $in,  '<', $from  or die "Could not open source '$from' $!";
	open my $out, '>', $to    or die "Could not open target '$to' $!";
	local $/ = undef;
	my $content = <$in>;
	foreach my $k (sort {length $b <=> length $a} keys %map) {
		$content =~ s{$k}{$map{$k}}g; 
	}
	print $out $content;

	close $in;
	close $out;

	return;
}

# sometimes released as tar.gz and sometimes as tar.bz2 ?
sub perl_file { return 'perl-' . $_[0]->perl_version() . '.tar.bz2'; }
sub perl_file_no_ext {
	my $self = shift;
	(my $perl = $self->perl_file()) =~ s/\.tar\.(bz2|gz)$//;
	return $perl;
}

sub all_modules {
	my ($self) = @_;
	my @all;

	return \@all;
}

sub get_steps { return ('perl', 'cpan', grep /^\w+$/, steps()) };
sub steps {
	return (
		alien => [
			'YAML',
			'YAML::Tiny',
			'ExtUtils::CBuilder',
			'Alien::wxWidgets',
		],
		mbuild => [
			#'Module::Signature',   # optional Module::Build prereq
			'Regexp::Common',        # prereq of Pod::Readme
			'Pod::Readme',           # optional Module::Build prereq
			'Module::Build',
		],
		minstall => [
			'Module::ScanDeps',      # prereq of Module::Install
			'JSON',                  # prereq of Module::Install
			'Module::Install',
		],
		wx => [
			'ExtUtils::XSpp',
			'Wx',
			'Wx::Perl::ProcessStream',
		],

		padre => [
			'Capture::Tiny',
			'Padre',
		],

		perl6 => [

#		'Perl6::Refactor', # prereqs of Perl6 plugin
#		'Perl6::Doc',
#		'App::Grok',
#		'grok',
#		'Perl6::Perldoc::To::Ansi',
#		'Perl6::Perldoc',
#		'Pod::Text::Ansi',
#		'IO::Interactive',
#		'YAML::Syck',
#		'Log::Trace',
#		'Scope::Guard',
#		'Sub::Exporter',
#		'Test::Assertions',
#		'Test::Assertions::TestScript',
#		'Pod::Xhtml',
#		'Syntax::Highlight::Perl6',

			'Padre::Plugin::Perl6',
		],
		catalyst => [
			'Catalyst::Runtime',
# Catalyst::Test
# Catalyst-Action-RenderView
# Catalyst::Util
			'Catalyst::Devel',
			'Padre::Plugin::Catalyst',

# 'Task::CatInABox',
# 'Tast::Catalyst::Tutorial',
		],

		svn => [
			'Padre::Plugin::SVN',
		],
		git => [
			'Padre::Plugin::Git',
		],
		plack => [
			'Padre::Plugin::Plack',
		],
		tidy => [
			'Padre::Plugin::PerlTidy',
		],
		critic => [
			'Padre::Plugin::PerlCritic',
		],
	);
}

#		'CPAN::Inject',
#		'LWP::Online',
#		'LWP::Simple',
#		'libwww::perl',
#		'Spiffy',
#		'Test::Simple',
#		'Test::Base',
#		'Devel::Refactor',
#		'Sub::Uplevel',
#		'Moose',
#		'Data::Compare',
#		'File::chmod',
#		'Tree::DAG_Node',
#		'Test::Exception',
#		'Test::Warn',
#		'Test::Tester',
#		'Test::NoWarnings',
#		'Test::Deep',
#		'IO::stringy', # needed by IO::Scalar ??
#		'IO::Scalar',
#		'File::Next',
#		'App::Ack',
#		'ack',  # ack is the name of the package, App::Ack is the name of module
#		'Class::Adapter',
#		'Class::Inspector',
#		'Class::Unload',
#		'AutoXS::Header',
#		'Class::XSAccessor',
#		'Class::XSAccessor::Array',
#		'Cwd', # PathTools-3.30
#		'DBI',
#		'DBD::SQLite',
#		'Devel::Dumpvar',
#		'Encode',
#		'IPC::Run3',
#		'CPAN::Checksums',
#		'Compress::Bzip2',
#		'Probe::Perl',
#		'Test::Script',
#		'Test::Harness',
#		'Devel::StackTrace',
#		'Class::Data::Inheritable',
#		'Exception::Class',
#		'Algorithm::Diff',
#		'Text::Diff',
#		'Test::Differences',
#		'Test::Most',
#		'File::Copy::Recursive',
#		'Text::Glob',
#		'Number::Compare',
#		'File::Find::Rule',
#		'File::HomeDir',
#		'Params::Util',
#		'File::ShareDir',
##		'File::Spec', # was already installed
#		'File::Which',
#		'Format::Human::Bytes',
#		'Locale::Msgfmt',
#		'HTML::Tagset',
#		'HTML::Entities',
#		'HTML::Parser', # the same pacakge as HTML::Entities
#		'IO::Socket', # IO 1.25
#		'IO::String',
#		'IPC::Cmd',
#		'List::Util', # Scalar-List-Utils-1.21
#		'List::MoreUtils',
#		'File::Temp',
#		'File::Remove',
#		'File::Find::Rule::Perl',
#		'File::Find::Rule::VCS',
#		'Module::Extract',
#		'Module::Manifest',
#		'Module::Math::Depends',
#		'ORLite',
#		'ORLite::Migrate',
#		'File::pushd',
#		'File::Slurp',
#		'Pod::POM',
#		'Parse::ErrorString::Perl',
#		'Module::Refresh',
#		'Devel::Symdump',
#		'Test::Pod',
#		'Pod::Coverage',
#		'Test::Pod::Coverage',
#		'Module::Starter',
#		'Parse::ExuberantCTags',
#		'Pod::Simple',
##		'Pod::Simple::XHTML', # supplied by Pod::Simple
#		'Task::Weaken',
#		'Pod::Abstract',
#		'Pod::Perldoc',
#		'Storable',
#		'URI',
#		'Text::FindIndent',
#		'pip',
#		'Class::MOP',
#		'Data::OptList',
#		'Sub::Install',
#		'MRO::Compat',
#		'Sub::Exporter',
#		'Sub::Name',
#		'Try::Tiny',
#		'Test::Object',
#		'Devel::GlobalDestruction',
#		'Config::Tiny',
#		'Test::ClassAPI',
#		'Clone',
#		'Hook::LexWrap'            => '0.22'],
#		'Test::SubCalls'           => '1.09'],
#		'PPI'                      => '1.203'],
#		'PPIx::EditorTools'        => '0.04'],
#		'Module::Inspector'        => '0.04'],
#
#
#		'PAR::Dist'                => '0.45'],
#		'Archive::Zip'             => '1.28'],
#		'Compress::Raw::Zlib'      => '2.020'],
#		'AutoLoader'               => '5.68'],
#		'PAR'                      => '0.992'],
#		'File::ShareDir::PAR'      => '0.05'],
#
#		'threads'                  => '1.73'],
#		'threads::shared'          => '1.29'],
#		'Thread::Queue'            => '2.11'],

sub install_modules {
	my ($self, $modules) = @_;

	foreach my $m (@$modules) {
		print "XL: Installing $m\n";
		local $ENV{PATH} = "$self->{perl_install_dir}/bin:$ENV{PATH}";
		local $ENV{HOME} = $self->{perl_install_dir};
		local $ENV{PERL_MM_USE_DEFAULT} = 1;
		my $cmd0 = 'mycpan.pl';
		my $PERL = "$self->{perl_install_dir}/bin/perl";
		#$PERL .= $self->perl_version if $self->{perl} ne 'stable'; # no need as we copy the perl5.11.3 to be also perl
		my $cmd = "$PERL $self->{perl_install_dir}/bin/$cmd0 $m";
		my $out = _system($cmd);
		foreach my $re (
			qr/Result: FAIL/,
			qr/Warning: no success downloading/,
			qr/Make had returned bad status/,
			) {
			if ($out =~ $re ) {
				print $out;
				exit;
			}
		}
		if ($self->{verbose}) {
			print $out;
		}
	}
}

sub remove_cpan_dir {
	my ($self) = @_;
	rmtree($self->{perl_install_dir} . '/.cpan/build');
	rmtree($self->{perl_install_dir} . '/.cpan/sources');
	rmtree($self->{perl_install_dir} . '/.cpan/Metadata');
	rmtree($self->{perl_install_dir} . '/.cpan/FTPstats.yml');
	return;
}


sub create_zip {
	my ($self) = @_;

	$self->remove_cpan_dir;

	chdir $self->dir;
	my $file = "$self->{cwd}/" . $self->release_name . '.tar.bz2';
	if (-e $file) {
		print "File '$file' already exists\n";
		return;
	}
	_system("tar cjf $file " . $self->release_name); # . ' --exclude .cpan');
	return;
}	


#### helper subs

sub dir       { return $_[0]->{dir};         }
sub minicpan  { return "$_[0]->{dir}/cpan_mirror";  }
sub dir_build { return "$_[0]->{dir}/build"; }

sub release_name {
	my ($self) = @_;
	my $perl = $self->perl_file_no_ext();
	return "$perl-xl-$VERSION";
}
sub _system {
	my $cmd = shift;
	debug("system: $cmd");
	my $tempdir = tempdir(CLEANUP => 1);
	my $error = system("$cmd >  $tempdir/out 2>&1");

	my $out;
	if (open my $fh, '<', "$tempdir/out") {
		local $/= undef;
		$out = <$fh>;
	}
 	if ($error) {
		print $out;
		die "\nsystem failed with $?\n";
	}

	return $out;
}

sub debug {
	print "@_\n";
}

=head2 clean

Remove the directories where perl was unzipped, built and where it was "installed"

=cut

sub clean {
	my ($self) = @_;

	my $dir = $self->dir_build;
	rmtree $dir if $dir;
	return;
}

=head2 download

Downloading the source code of perl, the CPAN modules
and in the future also wxwidgets

See get_other and get_cpan for the actual code.

=cut

sub download {
	my ($self) = @_;

	$self->get_cpan;
	$self->get_other;

	return;
}


sub get_other {
	my ($self) = @_;

	my $perl = $self->perl_file;
	my @resources = (
		"http://www.cpan.org/src/$perl",
		'http://prdownloads.sourceforge.net/wxwindows/wxWidgets-2.8.10.tar.gz',

	);

	my $src = $self->dir . "/src";
	foreach my $url (@resources) {
		my $filename = (split "/", $url)[-1];
		debug("getting $url to   $src/$filename");
		mirror($url, "$src/$filename"); 
	}
	return;
}

sub get_cpan {
	my ($self) = @_;
	
	debug("Get CPAN");
	my $cpan = 'http://cpan.hexten.net/';
	my $minicpan = $self->minicpan;
	my $verbose = 0;
	my $force   = 1;

	my @filter;
	if (not $self->{full}) {
		# comment out so won't delete mirror accidentally
		#@filter = (path_filters => [ sub { $self->filter(@_) } ]);
	}
	CPAN::Mini->update_mirror(
		remote       => $cpan,
		local        => $minicpan,
		trace        => $verbose,
		force        => $force,
		@filter,
	);

	return;
}

{
	my %modules;
	my %seen;

	sub filter {
		my ($self, $path) = @_;

		return $seen{$path} if exists $seen{$path};

		if (not %modules) {
			foreach my $pair (@{ $self->all_modules }) {
				my ($name, $version) = @$pair;
				$name =~ s/::/-/g;
				$modules{$name} = $version;
			}
		}
		foreach my $module (keys %modules) {
			if ($path =~ m{/$module-v?\d}) { # Damian use a v prefix in the module name
				print "Mirror: $path\n";
				return $seen{$path} = 0;
			}
		}
		#die Dumper \%modules;
		#warn "@_\n";
		return $seen{$path} = 1;
	}
}


1;


