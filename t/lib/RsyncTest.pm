package RsyncTest;
use strict;
use warnings;
use FindBin;
use Exporter ();
use Path::Class;
use Log::Any::Adapter 'TAP';
use Log::Any '$log';
use Carp;

our @EXPORT= qw(
	proj_dir test_tmp_dir test_data_dir $log dir file
	escape_str unescape_str load_trace concat_trace_client_server test_parse_with_interruptions
);

# "use RsyncTest;" has lots of side effects
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

# Return absolute path to root of git project
our $proj_dir;
sub proj_dir {
	return $proj_dir if defined $proj_dir;
	$proj_dir= file(__FILE__)->dir->parent->parent->resolve;
}

# Create a new empty directory for the current test case (deleting any previous for this test case)
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

# Format a string of binary data into C-style notation of pure ASCII
my %escapes; BEGIN { %escapes = ( "\0" => '\0', "\n" => '\n', "\r" => '\r', "\\" => "\\\\", '"' => "\\\"" ); }
sub escape_str {
	my $str= $_[0];
	$str =~ s/([\0-\x1F"\\\x7F-\xFF])/ defined $escapes{$1}? $escapes{$1} : sprintf("\\x%02X", ord($1)) /ge;
	unescape_str($str) eq $_[0] or die "Encoding broken: $str\n";
	qq{"$str"};
}

# Reverse escape_str and return binary data
my %unescapes; BEGIN { %unescapes = ( 0 => "\0", 'n' => "\n", 'r' => "\r", '\\' => "\\", '"' => '"' ); }
sub unescape_str {
	my $str= shift;
	$str =~ s/^"(.*)"$/$1/;
	$str =~ s/(\\(x(..)|(.)))/ defined $3? chr(hex($3)) : defined $unescapes{$4}? $unescapes{$4} : die "Invalid escape $1" /ge;
	$str;
}

# Load one of the rsync protocol traces in t/data/ and return it as an arrayref of
# each read/write by the server and client.
sub load_trace {
	my $fname= shift;
	my @content= proj_dir->subdir('t','data',$fname)->slurp;
	for (@content) {
		if ($_ =~ /^(CLIENT|SERVER) "(.*)"$/) {
			$_= [ $1, unescape_str($2) ];
		} elsif ($_ =~ /^(CLIENT|SERVER) EOF$/) {
			$_= [ $1, undef ];
		} elsif (length $_) {
			croak "Can't parse line '$_'";
		}
	}
	\@content;
}

# Given a trace from load_trace above, return two strings where the first is all client
# messages concatenated, and the second is all server messages concatenated.
sub concat_trace_client_server {
	my $trace= shift;
	my $client= '';
	my $server= '';
	for (@$trace) {
		$client .= $_->[1] if $_->[0] eq 'CLIENT' && defined $_->[1];
		$server .= $_->[1] if $_->[0] eq 'SERVER' && defined $_->[1];
	}
	return $client, $server;
}

# Given a list of method calls, and a buffer of input, and expected output events,
# verify that the Protocol object generates the expected events for this input.
# The methods are called any time the Protocol doesn't consume some of it's input.
# Then, try dividing the input on arbitrary boundaries and repeat the test, to make
# sure that the protocol parser can handle partial writes.

sub test_parse_with_interruptions {
	my ($method_calls, $expected_output, $input, $expected_events)= @_;
	# First, test by dumping the entire peer response at once
	main::subtest( 'One Chunk' => sub { 
		my $parser= Rsync::Protocol->new;
		$parser->rbuf->append($input);
		my @todo= @$method_calls;
		my @expected= @$expected_events;
		my $prev_len= 0;
		while ((my @event= $parser->parse) or @todo or $parser->wbuf->len > $prev_len) {
			$prev_len= length $parser->wbuf;
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
		main::is( ''.$parser->wbuf, $expected_output, 'generated expected output' );
	});
	
	# Then, test by delivering the peer response one byte at a time
	main::subtest( 'Byte at a Time' => sub {
		my $parser= Rsync::Protocol->new;
		my $pos= 0;
		my @todo= @$method_calls;
		my @expected= @$expected_events;
		my $prev_len= 0;
		while ((my @event= $parser->parse) or @todo or $pos < length($input) or $parser->wbuf->len > $prev_len) {
			$prev_len= length $parser->wbuf;
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
		main::is( ''.$parser->wbuf, $expected_output, 'generated expected output' );
	});
	
	# Then test with some randomly divided chunks
	main::subtest( 'Bursts of Input' => sub {
		my $parser= Rsync::Protocol->new;
		my $pos= 0;
		my @todo= @$method_calls;
		my @expected= @$expected_events;
		my $prev_len= 0;
		while ((my @event= $parser->parse) or @todo or $pos < length($input) or $parser->wbuf->len > $prev_len) {
			$prev_len= length $parser->wbuf;
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
		main::is( ''.$parser->wbuf, $expected_output, 'generated expected output' );
	});
}

1;
