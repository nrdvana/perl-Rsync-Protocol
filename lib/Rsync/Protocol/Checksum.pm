package Rsync::Protocol::Checksum;

use strict;
use warnings;
use Carp;

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

sub filelist_checksum {
	my ($class, $flist_entry)= @_;
	if ($flist_entry->{handle}) {
		return $class->new->addfile($flist_entry->{handle})->digest;
	} elsif ($flist_entry->{data}) {
		return $class->new->add($flist_entry->{data})->digest;
	} elsif ($flist_entry->{path}) {
		open my $fh, '<:raw', $flist_entry->{path} or croak "open($flist_entry->{path}): $!";
		$class->new->addfile($fh)->digest;
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
