package Rsync::Protocol::Checksum;

use strict;
use warnings;
use Carp;

# ABSTRACT: Various digest implementations needed by Rsync::Protocol

=head1 DESCRIPTION

Rsync uses several checksum algorithms depending on version and user options.  It also uses
several different I<behaviors> for each digest depending on version of the protocol and stage
of processing.  This base class encapsulates the various utility code surrounding use of
digests.

=head1 CLASS METHODS

=head2 select_class

  my $class= Rsync::Protocol::Checksum->select_class( $name, $version );

Find the class of the specified name (undef for default) and version of the protocol.

Currently, protocol versions 26 and earlier are unsupported because they need a broken MD4
implementation.  (it would not be hard to add, but would require a new XS module and probably
nobody would ever use it anyway)

=cut

sub select_class {
	my ($class, $name, $protocol_version)= @_;
	if (!$name || $name eq 'auto') {
		return 'Rsync::Protocol::Checksum::MD5' if $protocol_version >= 30;
		return 'Rsync::Protocol::Checksum::MD4' if $protocol_version >= 27;
		croak "Can't support checksums prior to protocol 27 (would require a broken MD4 implementation)";
	} elsif ($name eq 'md4') {
		return 'Rsync::Protocol::Checksum::MD4' if $protocol_version >= 27;
		croak "Can't support checksums prior to protocol 27 (would require a broken MD4 implementation)";
	} elsif ($name eq 'md5') {
		return 'Rsync::Protocol::Checksum::MD5';
	} elsif ($name eq 'none') {
		return 'Rsync::Protocol::Checksum::None';
	} else {
		croak "Unknown checksum format '$name'";
	}
}

=head2 filelist_checksum

  my $checksum_string= $class->filelist_checksum( \%filelist_entry );

Given a file list entry, calculate the checksum string that should be included in the file list.
This can take advantage of pre-calculated C<< ->{md5} >> or C<< ->md4 >> in the record, else
it checksums C<< ->{data} >>, C<< ->{handle} >>, or C<< ->{path} >> (whichever is defined).
If it can't find anything to digest, it dies.

=cut

sub filelist_checksum {
	my ($class, $flist_entry)= @_;
	if ($flist_entry->{data}) {
		return $class->new->add($flist_entry->{data})->digest;
	} elsif ($flist_entry->{handle}) {
		return $class->new->addfile($flist_entry->{handle})->digest;
	} elsif ($flist_entry->{path}) {
		open my $fh, '<:raw', $flist_entry->{path} or croak "open($flist_entry->{path}): $!";
		return $class->new->addfile($fh)->digest;
	} else {
		croak "File list entry lacks handle/data/path required for checksum calculation";
	}
}

require Digest::base;
@Rsync::Protocol::Checksum::None::ISA= ( __PACKAGE__, 'Digest::base' );

sub Rsync::Protocol::Checksum::None::new { my $x; bless \$x, shift; }
sub Rsync::Protocol::Checksum::None::add { shift; }
sub Rsync::Protocol::Checksum::None::addfile { shift; }
sub Rsync::Protocol::Checksum::None::digest { "\0"; }
sub Rsync::Protocol::Checksum::None::filelist_checksum { "\0"; }

require Digest::MD4;
@Rsync::Protocol::Checksum::MD4::ISA= ( __PACKAGE__, 'Digest::MD4' );

sub Rsync::Protocol::Checksum::MD4::filelist_checksum {
	my ($class, $flist_entry)= @_;
	$flist_entry->{md4} || $class->SUPER::filelist_checksum($flist_entry);
}

require Digest::MD5;
@Rsync::Protocol::Checksum::MD5::ISA= ( __PACKAGE__, 'Digest::MD5' );

sub Rsync::Protocol::Checksum::MD5::filelist_checksum {
	my ($class, $flist_entry)= @_;
	$flist_entry->{md5} || $class->SUPER::filelist_checksum($flist_entry);
}

1;
