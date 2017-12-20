#! /usr/bin/env perl
use strict;
use warnings;
use Rsync::Protocol;
use IO::Socket;
STDOUT->autoflush(1);

my $listen_socket= IO::Socket::INET->new(
	Proto => 'tcp',
	LocalAddr => 'localhost',
	LocalPort => 4322,
	Listen => 1,
	ReuseAddr => 1,
);
my $client_socket= $listen_socket->accept;
$client_socket->autoflush(1);

my $proto= Rsync::Protocol->new;
$proto->start_daemon_server;
while (1) {
	print $proto->state."\n";
	while (my @event= $proto->parse) {
		print "EVENT: ".join(' ', map escape_buffer($_), @event)."\n";
		if ($event[0] eq 'MODULE') {
			$proto->send_motd("Welcome.  Some things are\npassword protected, here.");
			if ($event[1] eq '') {
				$proto->send_module_list([ 'a', 'b', 'c', 'd', 'e' ]);
			} elsif ($event[1] eq 'a') {
				$proto->send_ok;
			} elsif ($event[1] eq 'b') {
				$proto->send_auth_challenge('qwertyuiop');
			} else {
				$proto->send_exit;
			}
		} elsif ($event[0] eq 'AUTH') {
			if ($event[1] eq 'Aladin') {
				$proto->check_auth_password('OpenSesame');
				$proto->send_ok;
			} else {
				$proto->send_error("Access Denied");
			}
		}
		print $proto->state."\n";
	}
	if ($proto->wbuf->len) {
		print "WROTE: ".escape_buffer($proto->wbuf)."\n";
		$client_socket->send($proto->wbuf);
		$proto->wbuf->clear;
	}
	if (defined $client_socket->recv(my $buffer, 1024)) {
		if (length $buffer) {
			print "READ : ".escape_buffer($buffer)."\n";
			$proto->rbuf->append($buffer);
		} else {
			print "EOF from client\n";
			exit 0;
		}
	} else {
		warn "Error on socket: $!\n";
		exit 2;
	}
}

sub escape_buffer {
	my $x= shift."";
	$x =~ s/([^ -\x7E])/ sprintf("\\x%X", ord($1)) /gex;
	qq{"$x"};
}
