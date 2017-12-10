package Rsync::Protocol;
use Moo;
use Digest::MD5;
use Digest::MD4;

has version       => ( is => 'rw', default => sub { 30 } );
has rbuf          => ( is => 'rw', default => sub { Rsync::Protocol::Buffer->new } );
has wbuf          => ( is => 'rw', default => sub { Rsync::Protocol::Buffer->new } );
has remote_cmd    => ( is => 'rw' );
has daemon_module => ( is => 'rw' );
has username      => ( is => 'rw' );
has password      => ( is => 'rw' );
has daemon_challenge => ( is => 'rw' );
has daemon_message   => ( is => 'rw' );

sub state {
	my $self= shift;
	if (@_) {
		my $state= shift;
		my $cls= "Rsync::Protocol::State::$state";
		$cls->isa(__PACKAGE__) or croak "Invalid state $state"; 
		bless $self, $cls;
	}
	return ($self =~ /Rsync::Protocol::State::(.*)/? $1 : undef;
}

sub BEGIN {
	my $self= shift;
	$self->state('Initial') unless $self->state;
}

sub parse {
}

@Rsync::Protocol::State::Initial::ISA= 'Rsync::Protocol';

sub Rsync::Protocol::State::Initial::start_socket_client {
	my ($self, $commandline, $module, $username, $password)= @_;
	$self->remote_cmd($commandline) if defined $commandline;
	$self->daemon_module($module) if defined $module;
	$self->username($username) if defined $username;
	$self->password($password) if defined $password;
	$self->wbuf->append('@RSYNCD: '.$self->version.".0\n".$self->daemon_module."\n");
	$self->state('ClientReadProtocol');
}

@Rsync::Protocol::State::ReadProtocol::ISA= 'Rsync::Protocol';

sub Rsync::Protocol::State::ClientReadProtocol::parse {
	my $self= shift;
	my $daemon_response= $self->rbuf->unpack_line // return undef;;
	$self->rbuf->discard;
	$daemon_response =~ /^\@RSYNCD: ([0-9]+)\.([-0-9]+)$/
		or return [ ERROR => "Unexpected rsync server ident line: $daemon_response" ];
	my $remote_ver= $1;
	my $remote_sub= $2;
	my $proto= $self->version >= $remote_ver? ( $remote_sub? $remote_ver - 1 : $remote_ver )
		: $self->version;
	$proto >= 29
		or return [ ERROR => "Can't talk protocol $remote_ver.$remote_sub or any prior" ];
	$self->version($proto);
	$self->state('ClientLogin');
}

@Rsync::Protocol::State::ClientLogin::ISA= 'Rsync::Protocol';

sub Rsync::Protocol::State::ClientLogin::parse {
	my $self= shift;
	my $line= $self->rbuf->unpack_line // return undef;
	$self->rbuf->discard;
	if ($line =~ /^\@RSYNCD: AUTHREQD (.*)$/) {
		$self->daemon_challenge($1);
		if (defined $self->username && defined $self->password) {
			$self->send_user_pass($self->username, $self->password);
		} else {
			return [ AUTHREQD => $1 ];
		}
	}
	elsif ($line =~ /^\@RSYNCD: OK$/) {
		$self->state('Receiver');
		return $self->parse;
	}
	elsif ($line =~ /^\@RSYNCD: EXIT$/) {
		return [ 'EXIT' ];
	}
	elsif ($line =~ /\@ERROR: (.*)/) {
		return [ ERROR => "Protocol error during login: $1" ];
	}
	else {
		return [ INFO => $line ];
	}
}

sub Rsync::Protocol::State::ClientLogin::send_user_pass {
	my ($self, $username, $password)= @_;
	defined $self->daemon_challenge or croak "Can't perform login without challenge";
	my $passhash= ($self->version >= 30? Digest::MD5->new : Digest::MD4->new)
		->add($password)
		->add($challenge)
		->b64digest;
	$passhash =~ s/=+$//;
	$self->wbuf->pack_line("$username $passhash");
	$self->parse;
}

@Rsync::Protocol::State::Receiver::ISA= 'Rsync::Protocol';

sub Rsync::Protocol::State::Receiver::parse {
	my $self= shift;
}

