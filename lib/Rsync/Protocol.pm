package Rsync::Protocol;

use Moo;
use Carp;
use Log::Any '$log';
use Try::Tiny;
use Rsync::Protocol::Buffer;
use Digest::MD5;
use Digest::MD4;

use constant PROTOCOL_VERSION => 30;

# ABSTRACT: Implementation of the Rsync state machine, for writing clients or servers

=head1 SYNOPSIS

  my $proto= Rsync::Protocol->new;
  while (read_more_data_from_peer($buffer)) {
    $proto->rbuf->append($buffer);
    while (my @event= $proto->parse) {
      ... # handle events, call other methods to reply
    }
    write_data_to_peer($proto->wbuf);
    $proto->wbuf->discard;
  }

=head1 DESCRIPTION

This module is a parser and producer for the rsync ... "protocol".  As it happens, rsync
doesn't really have what most people would call a protocol; It's more like two blobs of
complicated C state machines exchanging bytes with eachother as needed.  The state machines
don't implement the protocol so much as the protocol is defined by the behavior of the state
machines.  As such, a lot of this module was writen by following the flow of the C code.
The behavior of the rsync state machine is affected by a large number of global variables,
and so this module ends up mimicing a lot of them as attributes.

In short, this module isn't very pretty, even though I was trying to make it so in the
beginning.

This module is designed around the idea that you feed it the bytes from the remote side and
then parse out events.  The actual rsync state machine doesn't have any concept of events, and
in fact just performs blocking reads and writes as needed.  So, the "events" are entirely based
on my interpretation of the situation, and I might change them in the future.

Until this module reaches 1.0, be very careful when upgrading, and be sure to write your own
test cases for whatever you're using it for.

Your program flow should look like the L</SYNOPSIS> above.  You should read bytes from the
socket, append them to the read-buffer of the protocol object, call L</parse> repeatedly until
it doesn't return an event, then write any bytes that accumulated in the write-buffer back over
to the peer.  This design allows you to choose between blocking read/write, or event driven
designs.

=head1 ATTRIBUTES

These are the main attributes that you should worry about when creating the object.  There are
many others that are simply part of the protocol, and not documented here.

=head2 rbuf

The read-buffer.  This is always an instance of L<Rsync::Protocol::Buffer>.  You fill it with
bytes for mthe peer, and the L</parse> method extracts bytes from it.

=head2 wbuf

The write-buffer.  As you call L</parse> or other methods, messages to the peer will be encoded
into this buffer.  You must then write the contents of the buffer over to the peer.

=head2 opt

This is an instance of L<Rsync::Protocol::Options>, which holds the parsed command line options
of the rsync command.   What on earth is that doing in the protocol, you say?  Well the options
directly initialize the global variables that drive the C state machine, and in fact the
literal command line is passed from client to server at the start of the transmission.

Many other attributes are derived from L</opt> during the flow of the protocol, so you should
never change the options once communication has begun.

=head2 state

This is the name of the current state of the protocol state machine.  It might be useful for
logging but you shouldn't rely on it until version 1.0 of this module.

=cut

has rbuf             => ( is => 'rw', default => sub { Rsync::Protocol::Buffer->new } );
has wbuf             => ( is => 'rw', default => sub { Rsync::Protocol::Buffer->new } );
has opt              => ( is => 'rw', lazy => 1, builder => 1 );
sub _build_opt {
	require Rsync::Protocol::Options;
	Rsync::Protocol::Options->new;
}

# Active version of the protocol.  Starts at max value supported by this end, and negotiates
# downward when we find out the peer's version.  Always an integer.
has protocol_version => ( is => 'rw', default => sub { 30 } );
# Version reported by peer.  Maybe be fractional if talking to a pre-release version.
has remote_version   => ( is => 'rw' );

has daemon_module    => ( is => 'rw' );
has username         => ( is => 'rw' );
has password         => ( is => 'rw' );
has passhash         => ( is => 'rw' );
has daemon_challenge => ( is => 'rw' );
has daemon_message   => ( is => 'rw' );

has multiplex_in     => ( is => 'rw' );

# Read and write the current state of the protocol
has _state_stack => ( is => 'rw' );
sub state {
	my $self= shift;
	if (@_) {
		my $state= shift;
		my $cls= "Rsync::Protocol::_state_$state";
		$cls->isa(__PACKAGE__) or croak "Invalid state $state"; 
		bless $self, $cls;
		$log->trace("State = $state") if $log->is_trace;
	}
	return ($self =~ /Rsync::Protocol::_state_(\w+)/? $1 : undef);
}

sub push_state {
	my ($self, $state)= @_;
	my $old= $self->state;
	$self->state($state);
	push @{ $self->{_state_stack} }, $old;
}

sub pop_state {
	my $self= shift;
	die "State stack is empty" unless @{ $self->{_state_stack} };
	$self->state(pop @{ $self->{_state_stack} });
}

our $_inherit_from= __PACKAGE__;
sub STATE {
	my $state_name= shift;
	return $state_name => [ @_ ] if wantarray; # for nesting
	{ no strict 'refs';
		@{ 'Rsync::Protocol::_state_'.$state_name.'::ISA' }= ( $_inherit_from );
		print "Rsync::Protocol::_state_${state_name}::ISA= $_inherit_from\n";
	}
	while (@_) {
		my ($name, $thing)= splice(@_, 0, 2);
		if (ref $thing eq 'ARRAY') {
			local $_inherit_from= 'Rsync::Protocol::_state_'.$state_name;
			STATE($name, @$thing);
		} elsif (ref $thing eq 'CODE') {
			no strict 'refs';
			*{ 'Rsync::Protocol::_state_'.$state_name.'::'.$name }= $thing;
		} else {
			die; # author error
		}
	}
}

sub BUILD {
	my $self= shift;
	$self->state('Initial') unless $self->state;
}

=head1 METHODS

The methods of this object change based on the current state.  Every state defines these
methods:

=head2 parse

  my @event= $proto->parse;

Read bytes from L</rbuf> and if they form a complete event, return the event, else return an
empty list.

An event is returned as a list to avoid the overhead of allocating arrayrefs every single time.
The elements are an identifier string followed by data points specific to that event type.
See the protocol description below.

=cut

sub parse {
	return;
}

sub _setup_protocol {
	my $self= shift;
#	my $n= $self->am_sender? PTR_EXTRA_CNT : 1;
#	$self->uid_ndx( ++$n ) if $self->preserve_uid;
#	$self->gid_ndx( ++$n ) if $self->preserve_gid;
#	$self->acls_ndx( ++$n ) if $self->preserve_acls && !$self->am_sender;
#	$self->xattrs_ndx( ++$n ) if $self->preserve_xattrs;
}

=head1 PROTOCOL

=head2 State: Initial

You can start communications as either client or server, and as either sender or receiver.
(these are orthagonal, aside from that you must always be the receiver if you are a client
connecting to an rsync daemon)

=head3 Methods

=over

=item start_daemon_client

This initializes the protocol as a client connecting to an rsync daemon.

=item start_daemon_server

  $proto->start_daemon_server(
  );

This initializes the protocol as an rsync daemon server accepting a connection from a client.

=back

=cut

sub _fatal_error {
	my ($self, $message)= @_;
	$self->error($message);
	$self->state('Fatal');
	return ERROR => $message;
}

STATE Initial => (
	start_daemon_client => sub {
		my ($self, $commandline, $module, $username, $password)= @_;
		$self->opt->apply_argv($commandline) if defined $commandline;
		$self->daemon_module($module) if defined $module;
		$self->username($username) if defined $username;
		$self->password($password) if defined $password;
		$self->wbuf->append('@RSYNCD: '.$self->protocol_version.".0\n");
		$self->state('ClientReadProtocol');
	},

	start_daemon_server => sub {
		my $self= shift;
		$self->wbuf->append('@RSYNCD: '.$self->protocol_version.".0\n");
		$self->state('DaemonServerReadModule');
		$self->push_state('DaemonReadVersion');
	},
);

STATE DaemonReadVersion => (
	parse => sub {
		my $self= shift;
		my $peer_version= $self->rbuf->unpack_line // return;
		$self->rbuf->discard;
		$peer_version =~ /^\@RSYNCD: ([0-9]+)\.([-0-9]+)$/
			or return $self->_fatal_error("Unexpected rsync ident line: $peer_version");
		my ($remote_ver, $remote_sub)= ($1, $2);
		$self->remote_version("$1.$2");
		$remote_ver-- if $remote_sub; # can't talk pre-release versions, so drop to previous
		$self->protocol_version($remote_ver) if $remote_ver < $self->protocol_version;
		$self->protocol_version >= 29
			or return $self->_fatal_error("Can't talk protocol ".$self->remote_version." or any prior");
		$self->pop_state;
		return PROTOCOL => $self->protocol_version;
	},
);

STATE DaemonServerReadModule => (
	parse => sub {
		my $self= shift;
		my $module= $self->rbuf->unpack_line // return;
		$self->rbuf->discard;
		$self->daemon_module($module);
		$self->state('DaemonServerNegotiateModule');
		return MODULE => $module;
	},
);

STATE DaemonServerNegotiateModule => (
	send_motd => sub {
		my ($self, $motd)= @_;
		$motd =~ s/^\@/ \@/mg; # ensure no line starts with @
		$self->wbuf->pack_lines($motd);
	},
	send_module_list => sub {
		my ($self, $modules)= @_;
		$self->wbuf->pack_lines(@$modules, '@RSYNCD: EXIT');
	},
	send_auth_challenge => sub {
		my ($self, $salt)= @_;
		$salt =~ /^[^\n]+/ or die "Must provide a secure random salt value that doesn't contain newline";
		$self->daemon_challenge($salt);
		$self->wbuf->pack_lines('@RSYNCD: AUTHREQD '.$salt);
		$self->state('DaemonServerCheckAuth');
	},
	
	DaemonServerCheckAuth => [
		parse => sub {
			my $self= shift;
			my $user_pass= $self->rbuf->unpack_line // return;
			$self->rbuf->discard;
			my ($u, $p)= ($user_pass =~ /([^ \n]+) +(\S+)$/)
				or return $self->_fatal_error('Invalid username/passhash received from client');
			$self->username($u);
			$self->passhash($p);
			$self->state('DaemonServerNegotiateModule');
			return AUTH => $u, $p;
		},
	],
	
	check_auth_password => sub {
		my ($self, $real_password)= @_;
		my $expected= ($self->protocol_version >= 30? Digest::MD5->new : Digest::MD4->new)
			->add($real_password)
			->add($self->daemon_challenge)
			->b64digest;
		$expected =~ s/=+$//;
		return ($expected eq $self->passhash);
	},
	
	send_error => sub {
		my ($self, $message)= @_;
		$self->wbuf->pack_lines('@ERROR: '.$message);
	},
	send_ok => sub {
		my $self= shift;
		$self->wbuf->pack_lines('@RSYNCD: OK');
		$self->state('DaemonServerReadCommand');
	},
	send_exit => sub {
		my $self= shift;
		$self->wbuf->pack_lines('@RSYNCD: EXIT');
	},
);

STATE DaemonServerReadCommand => (
	parse => sub {
		my $self= shift;
		# Protocol < 30 uses newline delimiter.  Later versions delimit with NUL
		my $term= $self->protocol_version >= 30? "\0" : "\n";
		return unless ${$self->rbuf} =~ /\G(.*?)$term$term/gc;
		my @argv= split $term, $1;
		$self->rbuf->discard;
		$self->opt->apply_argv(@argv)
			or return $self->_fatal_error('Client sent invalid command: '.join(' ', @argv));
		$self->state('DaemonServerSend');
		return COMMAND => @argv;
	},
);

STATE DaemonServerSend => (
);

@Rsync::Protocol::_state_DaemonServerReadModule::ISA= 'Rsync::Protocol';

@Rsync::Protocol::_state_ClientLogin::ISA= 'Rsync::Protocol';

sub Rsync::Protocol::_state_ClientLogin::parse {
	my $self= shift;
	my $line= $self->rbuf->unpack_line // return;
	$self->rbuf->discard;
	if ($line =~ /^\@RSYNCD: AUTHREQD (.*)$/) {
		$self->daemon_challenge($1);
		if (defined $self->username && defined $self->password) {
			$self->send_user_pass($self->username, $self->password);
		} else {
			return AUTHREQD => $1;
		}
	}
	elsif ($line =~ /^\@RSYNCD: OK$/) {
		return 'OK';
	}
	elsif ($line =~ /^\@RSYNCD: EXIT$/) {
		return 'EXIT';
	}
	elsif ($line =~ /\@ERROR: (.*)/) {
		return ERROR => "Protocol error during login: $1";
	}
	else {
		return INFO => $line;
	}
}

sub Rsync::Protocol::_state_ClientLogin::send_user_pass {
	my ($self, $username, $password)= @_;
	defined $self->daemon_challenge or croak "Can't perform login without challenge";
	my $passhash= ($self->version >= 30? Digest::MD5->new : Digest::MD4->new)
		->add($password)
		->add($self->daemon_challenge)
		->b64digest;
	$passhash =~ s/=+$//;
	$self->wbuf->pack_line("$username $passhash");
}

sub Rsync::Protocol::_state_ClientLogin::start_remote_sender {
	my ($self, $command)= @_;
	$command //= $self->remote_cmd;
	my @args= ref $command? @$command : split / +/, $command;
	# In version 30, write arguments separated by NUL terminated by double NUL
	if ($self->version >= 30) {
		shift @args; # discard command name
		$self->wbuf->append( map "$_\0", @args, '' );
	}
	# earlier versions use arguments separated by newline terminated by double newline
	else {
		shift @args;
		$self->wbuf->append( map "$_\n", @args, '' );
	}
	
	$self->multiplex_in(1) if $self->version <= 22;
	$self->state('Receiver');
}

@Rsync::Protocol::_state_Receiver::ISA= 'Rsync::Protocol';

sub Rsync::Protocol::_state_Receiver::parse {
	my $self= shift;
	return;
}

