#! /usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/lib";
use RsyncTest;

plan tests => 7;
use_ok( 'Rsync::Protocol::Buffer' ) or BAIL_OUT;

subtest u8 => sub {
	my @vals= (
		0, 1, 0x7F, 0x80, 0xFE, 0xFF
	);
	for (@vals) {
		my $buf= Rsync::Protocol::Buffer->new;
		$buf->pack_u8($_);
		is( $buf->unpack_u8, $_, "write/read $_" );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_u8($_) for @vals;
	my @ret= map { $buf->unpack_u8 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( (try { $buf->unpack_u8; } catch { $_; }), $buf->EOF, 'EOF' );
};

subtest u16 => sub {
	my @vals= ( 0, 1, 0x7F, 0x80, 0xFE, 0xFF, 0x7FFF, 0x8000, 0xFFFF );
	for (@vals) {
		my $buf= Rsync::Protocol::Buffer->new;
		$buf->pack_u16($_);
		is( $buf->unpack_u16, $_, "write/read $_" );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_u16($_) for @vals;
	my @ret= map { $buf->unpack_u16 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( (try { $buf->unpack_u16; } catch { $_; }), $buf->EOF, 'EOF' );
};

subtest s32 => sub {
	my @vals= ( 0, 1, -1, 0x7F, 0x80, 0xFFFF, 0x7FFFFFFF, -0x7FFFFFFF );
	for (@vals) {
		my $buf= Rsync::Protocol::Buffer->new;
		$buf->pack_s32($_);
		is( $buf->unpack_s32, $_, "write/read $_" );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_s32($_) for @vals;
	my @ret= map { $buf->unpack_s32 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( (try { $buf->unpack_s32; } catch { $_; }), $buf->EOF, 'EOF' );
};

subtest s64 => sub {
	my @vals= ( 0, 1, -1, 0x7F, 0x80, 0xFFFF, 0x7FFFFFFF, -0x7FFFFFFF, 0x80000000, 0x7FFFFFFFFFFFFFFF );
	for (@vals) {
		my $buf= Rsync::Protocol::Buffer->new;
		$buf->pack_s64($_);
		is( $buf->unpack_s64, $_, "write/read $_" );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_s64($_) for @vals;
	my @ret= map { $buf->unpack_s64 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( (try { $buf->unpack_s64; } catch { $_; }), $buf->EOF, 'EOF' );
};

subtest 'v32' => sub {
	my @vals= (
		0, (map { 1 << $_ } 0..30), (map { 2 << $_ } 0..29), (map { 3 << $_ } 0..29),
		(map { 4 << $_ } 0..28), (map { 5 << $_ } 0..28), -1, -0x7F, -0x80, -0x80000000
	);
	for (@vals) {
		my $buf= Rsync::Protocol::Buffer->new;
		$buf->pack_v32($_);
		is( $buf->unpack_v32, $_, "write/read $_" );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_v32($_) for @vals;
	my @ret= map { $buf->unpack_v32 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( (try { $buf->unpack_v32; } catch { $_; }), $buf->EOF, 'EOF' );
};

subtest 'v64' => sub {
	my @vals= (
		0, (map { 1 << $_ } 0..62), (map { 2 << $_ } 0..61), (map { 3 << $_ } 0..61),
		(map { 4 << $_ } 0..60), (map { 5 << $_ } 0..60), -1, -0x7F, -0x80, -0x80000000
	);
	for my $min_bytes (3..5) {
		for (@vals) {
			my $buf= Rsync::Protocol::Buffer->new;
			$buf->pack_v64($_, $min_bytes);
			is( $buf->unpack_v64($min_bytes), $_, "write/read $_" );
		}
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_v64($_, 3) for @vals;
	my @ret= map { $buf->unpack_v64(3) } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( (try { $buf->unpack_v64(3); } catch { $_; }), $buf->EOF, 'EOF' );
};

