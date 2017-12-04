package RsyncTest;
use strict;
use warnings;
use FindBin;
use Exporter ();
use Path::Class;
use Log::Any::Adapter 'TAP';
use Log::Any '$log';
use Carp;

our @EXPORT= qw( proj_dir test_tmp_dir test_data_dir $log dir file );

sub import {
	# Inject various modules into caller
	my $caller= caller;
	strict->import;
	warnings->import;
	eval "package $caller;
		use Test::More;
		use Try::Tiny;
		1;
	" or die "$@";
	
	goto &Exporter::import;
}

our $proj_dir;
sub proj_dir {
	return $proj_dir if defined $proj_dir;
	$proj_dir= file(__FILE__)->dir->parent->parent->resolve;
}

our $test_tmp_dir;
sub test_tmp_dir {
	return $test_tmp_dir if defined $test_tmp_dir;
	my $name= $FindBin::Script;
	$name =~ s/\.t$//;
	$test_tmp_dir= proj_dir->subdir('t', 'tmp', $name)->resolve;
	# Sanity check before we rm -r
	! -l $test_tmp_dir->parent
	  and ! -l $test_tmp_dir
	  and $test_tmp_dir =~ m,[\\/]t[\\/]tmp[\\/]\w, or die "Unexpected test tmp dir $test_tmp_dir";
	$test_tmp_dir->rmtree if -e $test_tmp_dir;
	$test_tmp_dir->mkpath;
	$test_tmp_dir;
}

1;
