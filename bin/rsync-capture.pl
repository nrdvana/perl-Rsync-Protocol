#! /usr/bin/env perl
use strict;
use warnings;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use FindBin;
use lib "$FindBin::Bin/../t/lib";
$ENV{TAP_LOG_SHOW_USAGE}= 0;
require RsyncTest;

my $exit= AE::cv;
tcp_server undef, 4001, sub {
	my ($client_fh, $host, $port)= @_;
	tcp_connect "localhost", 4000, sub {
		my ($server_fh)= @_ or die "Can't connect: $!";
		my $client_h;
		my $server_h= AnyEvent::Handle->new(
			fh => $server_fh,
			on_read => sub {
				print "SERVER ".RsyncTest::escape_str($_[0]{rbuf})."\n";
				$client_h->push_write($_[0]{rbuf});
				$_[0]{rbuf}= '';
			},
			on_error => sub {
				print "SERVER LOST: $_[2]\n";
				$client_h->destroy;
				$_[0]->destroy;
			},
			on_eof => sub {
				print "SERVER EOF\n";
				$client_h->push_shutdown;
			},
		);
		$client_h= AnyEvent::Handle->new(
			fh => $client_fh,
			on_read => sub {
				print "CLIENT ".RsyncTest::escape_str($_[0]{rbuf})."\n";
				$server_h->push_write($_[0]{rbuf});
				$_[0]{rbuf}= '';
			},
			on_error => sub {
				print "CLIENT LOST: $_[2]\n";
				$server_h->destroy;
				$_[0]->destroy;
			},
			on_eof => sub {
				print "CLIENT EOF\n";
				$server_h->push_shutdown;
			},
		);
	};
};
$exit->recv;
