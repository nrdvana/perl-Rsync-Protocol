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
	is( $buf->unpack_u8, undef, 'EOF' );
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
	is( $buf->unpack_u16, undef, 'EOF' );
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
	is( $buf->unpack_s32, undef, 'EOF' );
};

subtest s64 => sub {
	my @vals= ( 0, 1, -1, 0x7F, 0x80, 0xFFFF, 0x7FFFFFFF, -0x7FFFFFFF, (1<<31), (1<<63)-1 );
	for (@vals) {
		my $buf= Rsync::Protocol::Buffer->new;
		$buf->pack_s64($_);
		is( $buf->unpack_s64, $_, "write/read $_" );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_s64($_) for @vals;
	my @ret= map { $buf->unpack_s64 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( $buf->unpack_s64, undef, 'EOF' );
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
		is( $buf->pos, $buf->len );
	}
	my $buf= Rsync::Protocol::Buffer->new;
	$buf->pack_v32($_) for @vals;
	my @ret= map { $buf->unpack_v32 } @vals;
	is_deeply( \@ret, \@vals, 'all in sequence' );
	is( $buf->unpack_v32, undef, 'EOF' );
};

subtest 'v64' => sub {
	my @vals= (
		0, (map { 1 << $_ } 0..46), (map { 2 << $_ } 0..45), (map { 3 << $_ } 0..45),
		(map { 4 << $_ } 0..44), (map { 5 << $_ } 0..44)
	);
	my @vals_high= (
		(map { 1 << $_ } 47..62), (map { 2 << $_ } 46..61), (map { 3 << $_ } 46..61),
		(map { 4 << $_ } 45..60), (map { 5 << $_ } 45..60),
		-1, -0x7F, -0x80, -0x80000000
	);
	for my $min_bytes (1..5) {
		my $buf;
		for (@vals, ($min_bytes >= 3? @vals_high : ())) {
			$buf= Rsync::Protocol::Buffer->new;
			$buf->pack_v64($_, $min_bytes);
			is( $buf->unpack_v64($min_bytes), $_, "write/read $_" );
			is( $buf->pos, $buf->len );
		}
		is( $buf->unpack_v64($min_bytes), undef, 'EOF' );
	}
};

