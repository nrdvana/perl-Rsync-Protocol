package Rsync::Protocol::Buffer;

use strict;
use warnings;

use constant EOF => \'EOF';

sub new {
	my ($class, $buffer)= @_;
	$buffer= '' unless defined $buffer;
	pos($buffer)= 0;
	bless \$buffer, $class;
}

sub pack_u8 {
	${$_[0]} .= chr($_[1]);
}

sub unpack_u8 {
	${$_[0]} =~ /\G(.)/sgc or die EOF;
	return ord($1);
}

sub pack_u16 {
	${$_[0]} .= pack('v', $_[1]);
}

sub unpack_u16 {
	${$_[0]} =~ /\G(..)/sgc or die EOF;
	return unpack 'v', $1;
}

sub pack_s32 {
	${$_[0]} .= pack('l<', $_[1]);
}

sub unpack_s32 {
	${$_[0]} =~ /\G(....)/sgc or die EOF;
	return unpack 'l<', $1;
}

sub pack_s64 {
	my ($self, $val)= @_;
	if ($val >= 0 && $val < 0x7FFFFFFF) {
		$$self .= pack('l<', $val);
	} else {
		$$self .= pack('l<q<', -1, $val);
	}
}

sub unpack_s64 {
	${$_[0]} =~ /\G(....)/sgc or die EOF;
	my $v= unpack 'l<', $1;
	return $v unless $v == -1;
	${$_[0]} =~ /\G(........)/sgc or die EOF;
	return unpack 'q<', $1;
}

sub pack_v32 {
	my ($self, $val)= @_;
	my $packed= pack('l<', $val);
	$packed =~ s/\0+\z//;
	if (length $packed) {
		my $hibit= 1 << (8-length $packed);
		my $tail_val= ord(substr($packed, -1));
		if ($tail_val >= $hibit) {
			$$self .= chr(0xFF & ~($hibit-1)) . $packed;
		} else {
			$$self .= chr(0xFF & ((~($hibit*2 - 1)) | $tail_val)) . substr($packed,0,-1);
		}
	} else {
		$$self .= "\0";
	}
}

sub unpack_v32 {
	${$_[0]} =~ /\G
		( ([\0-\x7F])
		| ([\x80-\xBF]) (.)
		| ([\xC0-\xDF]) (..)
		| ([\xE0-\xEF]) (...)
		| ([\xF0-\xF7]) (....)
		| [\xF8-\xFB] .....
		| [\xFC-\xFF] ...... ) /xsgc or die EOF;
	return defined $2? ord($2)
		: defined $3? ord($4) | ((ord($3)&0x7F) << 8)
		: defined $5? unpack('S<', $6) | ((ord($5)&0x3F)<<16)
		: defined $7? unpack('l<', $8."\0") | ((ord($7)&0x1F)<<24)
		: defined $9? unpack('l<', $10) # ignore the 4 bits in $9... looks like a bug but thats how rsync is written
		: die "Overflow in unpack_v32\n"
}

sub pack_v64 {
	my ($self, $val, $min_bytes)= @_;
	my $packed= pack('q<', $val);
	$packed =~ s/\0+\z//;
	if (length $packed >= $min_bytes) {
		my $hibit= 1 << (7-length($packed)+$min_bytes);
		$hibit > 2 or die "min_bytes '$min_bytes' too small for variable 64-bit with packed length ".length($packed)."\n";
		my $tail_val= ord(substr($packed, -1));
		if ($tail_val >= $hibit) {
			$$self .= chr(0xFF & ~($hibit-1)) . $packed;
		} else {
			$$self .= chr(0xFF & ((~($hibit*2 - 1)) | $tail_val)) . substr($packed,0,-1);
		}
	} else {
		$$self .= "\0" . $packed . "\0"x($min_bytes - length($packed) - 1);
	}
}

sub unpack_v64 {
	my ($self, $min_bytes)= @_;
	no warnings 'uninitialized'; # pos($$self) might be undef
	my $x= ord(substr($$self, pos($$self), 1)); # no need for length check til later
	my $n_bytes= $min_bytes + (
		$x < 0x80? 0
		: $x < 0xC0? 1
		: $x < 0xE0? 2
		: $x < 0xF0? 3
		: $x < 0xF8? 4
		: $x < 0xFC? 5
		: 6
	);
	pos($$self) + $n_bytes <= length $$self or die EOF;
	die "Overflow in unpack_V64\n" if $n_bytes > 9;
	my $buf= substr($$self, pos($$self)+1, $n_bytes-1);
	pos($$self) += $n_bytes;
	if ($n_bytes < 9) {
		$buf .= "\0"x(9-$n_bytes);
		return unpack('q<', $buf)
			| (($x & ((1 << (8+$min_bytes-$n_bytes))-1)) << (8*($n_bytes-1)));
	} else {
		return unpack('q<', $buf);
	}
}

1;
