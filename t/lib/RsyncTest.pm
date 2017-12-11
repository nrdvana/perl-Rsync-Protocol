package RsyncTest;
use strict;
use warnings;
use FindBin;
use Exporter ();
use Path::Class;
use Log::Any::Adapter 'TAP';
use Log::Any '$log';
use Carp;

our @EXPORT= qw( proj_dir test_tmp_dir test_data_dir $log dir file test_parse_with_interruptions );

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

sub test_parse_with_interruptions {
	my ($method_calls, $input, $expected_events)= @_;
	# First, test by dumping the entire peer response at once
	main::subtest( 'One Chunk' => sub { 
		my $parser= Rsync::Protocol->new;
		$parser->rbuf->append($input);
		my @todo= @$method_calls;
		my @expected= @$expected_events;
		while ((my @event= $parser->parse) or @todo) {
			if (@event) {
				unless (main::is_deeply( \@event, $expected[0], 'event '.$expected[0][0] )) {
					main::diag('Got '.main::explain(\@event).' instead of '.main::explain($expected[0]));
					last;
				}
				shift @expected;
			}
			elsif (@todo) {
				my ($method, @args)= @{ shift @todo };
				$parser->$method(@args);
			}
		}
		main::is( scalar @expected, 0, 'received all events' );
	});
	
	# Then, test by delivering the peer response one byte at a time
	main::subtest( 'Byte at a Time' => sub {
		my $parser= Rsync::Protocol->new;
		my $pos= 0;
		my @todo= @$method_calls;
		my @expected= @$expected_events;
		while ((my @event= $parser->parse) or @todo or $pos < length($input)) {
			if (@event) {
				unless (main::is_deeply( \@event, $expected[0], 'event '.$expected[0][0] )) {
					main::diag('Got '.main::explain(\@event).' instead of '.main::explain($expected[0]));
					last;
				}
				shift @expected;
			}
			elsif (@todo) {
				my ($method, @args)= @{ shift @todo };
				$parser->$method(@args);
			}
			else {
				$parser->rbuf->append(substr($input, $pos++, 1));
			}
		}
		main::is( scalar @expected, 0, 'received all events' );
	});
	
	# Then test with some randomly divided chunks
	main::subtest( 'Bursts of Input' => sub {
		my $parser= Rsync::Protocol->new;
		my $pos= 0;
		my @todo= @$method_calls;
		my @expected= @$expected_events;
		while ((my @event= $parser->parse) or @todo or $pos < length($input)) {
			if (@event) {
				unless (main::is_deeply( \@event, $expected[0], 'event '.$expected[0][0] )) {
					main::diag('Got '.main::explain(\@event).' instead of '.main::explain($expected[0]));
					last;
				}
				shift @expected;
			}
			elsif (@todo) {
				my ($method, @args)= @{ shift @todo };
				$parser->$method(@args);
			}
			else {
				my $n= int(rand(length($input) * .4));
				main::note("read $n bytes");
				$parser->rbuf->append(substr($input, $pos, $n));
				$pos += $n;
			}
		}
		main::is( scalar @expected, 0, 'received all events' );
	});
}

1;
