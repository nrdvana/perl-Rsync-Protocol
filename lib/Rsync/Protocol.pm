package Rsync::Protocol;

use Moo;
use Carp;
use Log::Any '$log';
use Try::Tiny;
use Rsync::Protocol::Buffer;
use Rsync::Protocol::Checksum;
use Fcntl ':mode';

# ABSTRACT: Implementation of the Rsync state machine, for writing clients or servers

=head1 SYNOPSIS

  my $proto= Rsync::Protocol->new;
  while (read_more_data_from_peer($buffer)) {
    $proto->rbuf->append($buffer);
    while (my @event= $proto->parse) {
      ... # handle events, call other methods to reply
    }
    write_data_to_peer($proto->wbuf);
    $proto->wbuf->clear;
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

=cut

use constant {
	PROTOCOL_VERSION        => 30,
	
	# Flags for the first byte of each file list entry
	
	XMIT_TOP_DIR            => (1<<0),
	XMIT_SAME_MODE          => (1<<1),
	XMIT_SAME_RDEV_pre28    => (1<<2),  # protocols 20 - 27
	XMIT_EXTENDED_FLAGS     => (1<<2),  # protocols 28 - now
	XMIT_SAME_UID           => (1<<3),
	XMIT_SAME_GID           => (1<<4),
	XMIT_SAME_NAME          => (1<<5),
	XMIT_LONG_NAME          => (1<<6),
	XMIT_SAME_TIME          => (1<<7),
	XMIT_SAME_RDEV_MAJOR    => (1<<8),  # protocols 28 - now (devices only)
	XMIT_NO_CONTENT_DIR     => (1<<8),  # protocols 30 - now (dirs only)
	XMIT_HLINKED            => (1<<9),  # protocols 28 - now
	XMIT_SAME_DEV_pre30     => (1<<10), # protocols 28 - 29
	XMIT_USER_NAME_FOLLOWS  => (1<<10), # protocols 30 - now
	XMIT_RDEV_MINOR_8_pre30 => (1<<11), # protocols 28 - 29
	XMIT_GROUP_NAME_FOLLOWS => (1<<11), # protocols 30 - now
	XMIT_HLINK_FIRST        => (1<<12), # protocols 30 - now (HLINKED files only)
	XMIT_IO_ERROR_ENDLIST   => (1<<12), # protocols 31*- now (w/XMIT_EXTENDED_FLAGS) (also protocol 30 w/'f' compat flag)
	XMIT_MOD_NSEC           => (1<<13), # protocols 31 - now

	# These flags are passed to the file list encoder, but not transferred

	FLAG_TOP_DIR      => (1<<0),  # sender/receiver/generator
	FLAG_OWNED_BY_US  => (1<<0),  # generator: set by make_file() for aux flists only
	FLAG_FILE_SENT    => (1<<1),  # sender/receiver/generator
	FLAG_DIR_CREATED  => (1<<1),  # generator
	FLAG_CONTENT_DIR  => (1<<2),  # sender/receiver/generator
	FLAG_MOUNT_DIR    => (1<<3),  # sender/generator (dirs only)
	FLAG_SKIP_HLINK   => (1<<3),  # receiver/generator (w/FLAG_HLINKED)
	FLAG_DUPLICATE    => (1<<4),  # sender
	FLAG_MISSING_DIR  => (1<<4),  # generator
	FLAG_HLINKED      => (1<<5),  # receiver/generator (checked on all types)
	FLAG_HLINK_FIRST  => (1<<6),  # receiver/generator (w/FLAG_HLINKED)
	FLAG_IMPLIED_DIR  => (1<<6),  # sender/receiver/generator (dirs only)
	FLAG_HLINK_LAST   => (1<<7),  # receiver/generator
	FLAG_HLINK_DONE   => (1<<8),  # receiver/generator (checked on all types)
	FLAG_LENGTH64     => (1<<9),  # sender/receiver/generator
	FLAG_SKIP_GROUP   => (1<<10), # receiver/generator
	FLAG_TIME_FAILED  => (1<<11), # generator
	FLAG_MOD_NSEC     => (1<<12), # sender/receiver/generator
};

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
		$self->push_state('DaemonServerCheckAuth');
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
			$self->pop_state;
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
		# Protocol < 30 uses newline terminator.  Later versions terminate with NUL
		# They both end with a double terminator.
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

STATE DaemonServerRun => (
	send_filelist_entry => sub {
		my ($self, $f)= @_;
		return $self->_skip_error_filelist_entry($f, 'File name too long')
			if length $f->{name} > $self->maxpathlen;
		return $self->
	},
	_skip_error_filelist_entry => sub {
		...
	},
);

STATE ClientLogin => (
	parse => sub {
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
	},
	send_user_pass => sub {
		my ($self, $username, $password)= @_;
		defined $self->daemon_challenge or croak "Can't perform login without challenge";
		my $digest= Rsync::Protocol::Checksum->select_class(undef, $self->protocol_version);
		my $passhash= $digest->new->add($password)->add($self->daemon_challenge)->b64digest;
		$passhash =~ s/=+$//;
		$self->wbuf->pack_line("$username $passhash");
	}

	start_remote_sender => sub {
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
);

STATE Receiver => (
	parse => sub {
		my $self= shift;
		return;
	},
);

sub _get_name_for_uid {
	my ($self, $uid)= @_;
	# TODO: allow user to override lists
	scalar getpwnam($uid);
}

sub _get_name_for_gid {
	my ($self, $gid)= @_;
	# TODO: allow user to override lists
	scalar getgrnam($gid);
}

has _filelist_checksum_class => ( is => 'rw' );
sub _build__filelist_checksum_class {
	my $self= shift;
	Rsync::Protocol::Checksum->select_class(
		$self->opt->checksum_flist_choice,
		$self->protocol_version
	);
}

has _xfer_checksum_class => ( is => 'rw' );
sub _build__xfer_checksum_class {
	my $self= shift;
	Rsync::Protocol::Checksum->select_class(
		$self->opt->checksum_xfer_choice,
		$self->protocol_version
	);
}

# The rsync file-list has undergone quite a lot of changes across protocol versions.
# It also differs significantly based on which options are in effect.
# It is really slow to check all of these conditions for every single file list entry,
# so this routine dynamically assembles perl code to perform only the needed processing
# per call.  As an added benefit, it can close over local variables to speed up the
# comparison to the previous encoded entry.

sub _generate_flist_encoder {
	my $self= shift;
	my $ver=  $self->protocol_version;
	my $code= 'sub {
		my ($self, $f)= @_;
		my $buf= $self->wbuf;';

	# Initialize flags
	my $flags;
	if ($ver >= 30) {
		$code .= '
		$flags= !($f->{mode} & S_IFDIR)? 0
			: ($f->{flags} && ($f->{flags} & FLAG_CONTENT_DIR))? $f->{flags} & FLAG_TOP_DIR;
			: ($f->{flags} && ($f->{flags} & FLAG_IMPLIED_DIR))? XMIT_TOP_DIR | XMIT_NO_CONTENT_DIR
			: XMIT_NO_CONTENT_DIR;';
	} else {
		$code .= '
		$flags= !($f->{mode} & S_IFDIR)? 0
			: $f->{flags} & FLAG_TOP_DIR;';
	}

	# Same mode as previous?
	my $mode= -1;
	$code .= '
	$flags |= XMIT_SAME_MODE if $mode == $f->{mode};
	$mode= $f->{mode};';

	# Same device 'rdev' as before?
	my ($rdev, $xmit_rdev);
	if ($self->opt->devices) {
		$rdev= -1;
		$code .= '
		if ($mode & (S_IFBLK|S_IFCHR)) {';
		if ($ver < 28) {
			# Protocol 27 and below have flag for recurring device numbers
			$code .= '
			$xmit_rdev= $rdev != $f->{rdev};
			$flags |= XMIT_SAME_RDEV_pre28 unless $xmit_rdev;';
		} else {
			# protocol 28 and above have flag for re-using device.major
			$code .= '
			$xmit_rdev= 1;
			$flags |= XMIT_SAME_RDEV_MAJOR if defined $rdev && major($f->{rdev}) == major($rdev);';
			# Protocol 28, 29 have a flag for xmitting device.minor as a single byte
			$code .= '
			$flags |= XMIT_RDEV_MINOR_8_pre30 if minor($f->{rdev}) <= 0xFF;';
				if $ver < 30;
		}
		$code .= '
			$rdev= $f->{rdev};
		}';
	}
	# Version 31 no longer transmits a rdev for specials (since not needed)
	if ($self->opt->specials && $ver < 31) {
		$code .= '
		'.($self->opt->devices?' els':'').'if ($mode & (S_IFIFO|S_IFSOCK)) {';
		# Special files don't need an rdev number, so just make
		# the historical transmission of the value efficient.
		if ($ver < 28) {
			$code .= '
			$xmit_rdev= 0;
			$flags |= XMIT_SAME_RDEV_pre28;';
		}
		else {
			$code .= '
			$xmit_rdev= 1;
			$rdev= MAKEDEV(major($rdev), 0);
			$flags |= XMIT_SAME_RDEV_MAJOR '.($ver < 30? '| XMIT_RDEV_MINOR_8_pre30':'').';';
		}
		$code .= '
		}';
	}
	if ($ver < 28) {
		# 27 and below always overwrite rdev if current entry is not a device/special.
		$code .= ($self->opt->devices || $self->opt->specials)? ' else {
			$xmit_rdev= 0;
			$rdev= MAKEDEV(0, 0);
		}' : '
		$xmit_rdev= 0;
		$rdev= MAKEDEV(0, 0);';
	}

	# Same UID as previous?
	my ($uid, $username, %uid_map);
	if (!$self->opt->user) {
		$code .= '
		$flags |= XMIT_SAME_UID;';
	} else {
		$uid= -1;
		$code .= '
		if ($uid == ($f->{uid} || 0)) {
			$flags |= XMIT_SAME_UID;
		} else {
			$uid= $f->{uid} || 0;';
		if (!$self->opt->numeric_ids) {
			$code .= '
			if (!defined $uid_map{$uid}++) {
				$username= $self->_get_username_for_uid($uid);';
			$code .= '
				$flags |= XMIT_USER_NAME_FOLLOWS if defined $username && length($username) < 255;'
				if $self->opt->inc_recurse;
			$code .= '
			}';
		}
		$code .= '
		}';
	}

	# Same GID as previous?
	my ($gid, $groupname, %gid_map);
	if (!$self->opt->group) {
		$code .= '
		$flags |= XMIT_SAME_GID;';
	} else {
		$gid= -1;
		$code .= '
		if ($gid == ($f->{gid} || 0)) {
			$flags |= XMIT_SAME_GID;
		} else {
			$gid= $f->{gid} || 0;';
		if (!$self->opt->numeric_ids) {
			$code .= '
			if (!defined $gid_map{$gid}++) {
				$groupname= $self->_get_groupname_for_gid($gid);';
			$code .= '
				$flags |= XMIT_GROUP_NAME_FOLLOWS if defined $groupname && length($groupname) < 255;'
				if $self->opt->inc_recurse;
			$code .= '
			}';
		}
		$code .= '
		}';
	}
	
	# Same mtime as previous?
	my $mtime;
	$code .= '
	$flags |= XMIT_SAME_TIME if defined $mtime and $f->{mtime} == $mtime;
	$mtime= $f->{mtime}';
	$code .= '
	$flags |= XMIT_MOD_NSEC if defined $f->{mtime_nsec};'
		if $ver >= 31;

	# Hard Links.
	# Version 30 of the protocol writes first occurrence of an inode with the "HLINK_FIRST"
	# flag, and then if it appears again it writes out the previous index within the filelist.
	# Previous versions wrote the device number and inode into the filelist for every file.
	my ($hlink_found, %hlink_map, $dev, $prev_dev, $fake_inode);
	if ($self->opt->hard_links) {
		$code .= '
		$flags |= XMIT_HLINKED;
		my $prev_dev= $dev;
		($dev, $ino)= @{$f}{"dev","ino");';
		if ($ver >= 30) {
			$code .= '
			$hlink_found= defined $dev && defined $ino? $hlink_map{$dev}{$ino} : undef;
			if (!defined $hlink_found) {
				$flags |= XMIT_HLINK_FIRST;
				$hlink_map{$dev}{$ino}= $first_ndx + $ndx;
			}';
		} else {
			# If the user of this library doesn't supply device/inode, then fake them.
			# This is only needed for versions older than 30 where the dev/inode values
			# get sent to the receiver.
			$code .= '
			if (defined $dev && defined $ino) {
				$dev++ if $dev >= 120; # make room for our fake device
			} else {
				($dev, $ino)= (120, ++$fake_inode);
			}'.($ver >= 28? '
			$flags |= XMIT_SAME_DEV_pre30 if defined $prev_dev && $dev == $prev_dev;' : '').'
			$dev= $f->{dev};';
		}
	}

	# Compare previous and current filename
	my ($name, $prev_name);
	$code .= '
	my $match_n= 0;
	($name, $prev_name)= ($f->{name}, $name);
	my $match_lim= min 255, length($name);
	$match_n++
		while $match_n < $match_lim
		   && substr($name, $match_n, 1) eq substr($prev_name, $match_n, 1);
	my $name_diff= substr($name, $match_n);
	$flags |= XMIT_SAME_NAME if $match_n;
	$flags |= XMIT_LONG_NAME if length $name_diff > 255;';

	# Write Flags
	# Make sure at least one bit is set in flags
	if ($ver >= 28) {
		$code .= '
		# Use XMIT_TOP_DIR on non-dir, which has no meaning
		$flags |= XMIT_TOP_DIR if !$flags && !($mode & S_IFDIR);
		# Else use longer flags encoding
		if (($flags & 0xFF00) || !$flags) {
			$flags |= XMIT_EXTENDED_FLAGS;
			$buf->write_shortint($flags);
		} else {
			$buf->write_byte($flags);
		}';
	} else {
		$code .= '
		$flags |= ($mode & S_IFDIR) ? XMIT_LONG_NAME : XMIT_TOP_DIR
			unless $flags & 0xFF;
		$buf->write_byte($flags);';
	}
	
	# Write Name (portion different from previous)
	$code .= '
	$buf->write_byte($match_n) if $flags & XMIT_SAME_NAME;
	if ($flags & XMIT_LONG_NAME) {
		$buf->write_varint30(length $name_diff);
	} else {
		$buf->write_byte(length $name_diff);
	}
	$buf->append($name_diff);
	';
	
	# If repeated hardlink in version 30+, write the file list index and skip the rest.
	$code .= '
	if (defined $hlink_found) {
		$buf->write_varint($hlink_found);
		return if $hlink_found < $first_ndx;
	}' if $self->opt->hard_links && $ver >= 30;
	
	# File Size
	$code .= '
	$buf->write_varlong30($f->{size}, 3);';

	# Mtime
	$code .= $ver >= 30? '
	$buf->write_varlong($mtime, 4) unless $flags & XMIT_SAME_TIME;' : '
	$buf->write_int($mtime) unless $flags & XMIT_SAME_TIME;';
	$code .= '
	$buf->write_varint($f->{mtime_nsec}) if $flags & XMIT_MOD_NSEC;';
	
	# Mode
	$code .= '
	$buf->write_int(to_wire_mode($mode)) unless $flags & XMIT_SAME_MODE;';

	# UID and maybe User Name
	if ($self->opt->user) {
		if ($ver < 30) {
			$code .= '
			$buf->write_int($uid) unless $flags & XMIT_SAME_UID;';
		} else {
			$code .= '
			unless ($flags & XMIT_SAME_UID) {
				$buf->write_varint($uid);
				if ($flags & XMIT_USER_NAME_FOLLOWS) {
					$buf->write_byte(length $username);
					$buf->append($username);
				}
			}';
		}
	}

	# GID and maybe Group Name
	if ($self->opt->group) {
		if ($ver < 30) {
			$code .= '
			$buf->write_int($gid) unless $flags & XMIT_SAME_GID;';
		} else {
			$code .= '
			unless ($flags & XMIT_SAME_GID) {
				$buf->write_varint($gid);
				if ($flags & XMIT_GROUP_NAME_FOLLOWS) {
					$buf->write_byte(length $groupname);
					$buf->append($groupname);
				}
			}';
		}
	}

	# Device node major/minor
	$code .= '
	if ($xmit_rdev) {';
	if ($ver < 28) {
		$code .= '
		$buf->write_int($rdev);';
	} elsif ($ver < 30) {
		$code .= '
		$buf->write_varint30(major($rdev))
			unless $flags & XMIT_SAME_RDEV_MAJOR;
		if ($flags & XMIT_RDEV_MINOR_8_pre30) {
			$buf->write_byte(minor($rdev));
		} else {
			$buf->write_int(minor($rdev));
		}';
	} else {
		$code .= '
		$buf->write_varint30(major($rdev))
			unless $flags & XMIT_SAME_RDEV_MAJOR;
		$buf->write_varint(minor($rdev));';
	}
	$code .= '
	}';

	# Symlink content
	$code .= '
	if (defined $f->{symlink}) {
		$buf->write_varint30(length $f->{symlink});
		$buf->append($f->{symlink});
	}';

	# Device/Inode.  Only needed if hardlinks enabled and protocol < 30 where the receiver
	# needs to know all device/inode numbers.  dev number is incremented to avoid sending 0.
	if ($self->opt->hard_links && $ver < 26) {
		$code .= '
		$buf->write_int($dev+1);
		$buf->write_int($ino);';
	}
	# Protocol 27..29 use 64-bit dev/inode
	elsif ($self->opt->hard_links && $ver < 30) {
		$code .= '
		$buf->write_longint($dev+1) unless $flags & XMIT_SAME_DEV_pre30;
		$buf->write_longint($ino);';
	}

	# File Checksum
	my $empty_sum;
	if ($self->opt->checksum) {
		$code .= '
		if (S_ISREG($mode)) {
			$buf->append($self->_filelist_checksum_class->filelist_checksum($f));
		}';
		# Prior to 28, non-files had a bogus checksum
		if ($ver < 28) {
			$empty_sum= $self->_filelist_checksum_class->filelist_checksum({ data => '' });
			$empty_sum= "\0" x length $empty_sum;
			$code .= '
			else { $buf->append($empty_sum); }';
		}
	}
	
	$code .= "\n}\n";
	
	# Now compile it!
	return eval($code) || croak "Failed to compile file-list encoder: $!\n\n$code";
}

