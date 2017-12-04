package Rsync::Protocol::Buffer;

use strict;
use warnings;
use overload '""' => sub { ${$_[0]} };

=head1 CONSTANTS

=head2 EOF

This is a global reference, thrown as an exception during unpack operations when we reach the
end of the buffer.

=cut

use constant EOF => \'EOF';

=head1 METHODS

=head2 new

  my $buf= Rsync::Protocol::Buffer->new( $bytes // '' );

Construct a new buffer.  The buffer can be initialized with a scalar, else it defaults to an
empty string.

=cut

sub new {
	my ($class, $buffer)= @_;
	$buffer= '' unless defined $buffer;
	pos($buffer)= 0;
	bless \$buffer, $class;
}

=head2 pos

Gets or sets current unpacking position within the buffer.

=head2 len

Returns the length of the buffer.

=cut

sub pos { pos(${$_[0]})= $_[1] if @_ > 1; pos ${$_[0]}; }
*len= \&CORE::length;

=head2 pack_u8

=head2 unpack_u8

Pack or unpack unsigned 8-bit integer.  Supplied argument will be masked to C<0..0xFF>.
Unpack dies with L</EOF> unless there is at least one byte at C<pos($buf)>.

  $buf->pack_u8( 0x40 );  # number, not character
  my $x= $buf->unpack_u8;

=head2 pack_u16

=head2 unpack_u16

Pack or unpack unsigned 16-bit integer.  Integer will be masked to C<0..0xFFFF>.  Unpack dies
with L</EOF> unless there are at least two bytes between C<pos($buf)> and C<length($buf)>.

  $buf->pack_u16( 0xFFFF );
  my $x= $buf->unpack_u16;

=cut

sub pack_u8 {
	${$_[0]} .= chr($_[1] & 0xFF);
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

=head2 pack_s32

=head2 unpack_s32

Pack or unpack signed 32-bit integer.  Supplied argument will be truncated to 32-bits.
Unpack dies with L</EOF> unless there are at least four bytes between C<pos($buf)> and
C<length($buf)>.

  $buf->pack_s32( 0x7FFFFFFF );
  my $x= $buf->unpack_s32;

=head2 pack_s64

=head2 unpack_s64

Pack or unpack signed 64-bit integer.  Supplied argument will be interpreted as signed even if
it was an unsigned value.  Unpack dies with L</EOF> unless there are at least eight bytes
between C<pos($buf)> and C<length($buf)>.

  $buf->pack_s64( 0x7FFFFFFF_FFFFFFFF );
  my $x= $buf->unpack_s64;

=cut

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
		# Yes, it is actually encoded as a 32-bit flag followed by a 64-bit
		$$self .= pack('l<q<', -1, $val);
	}
}

sub unpack_s64 {
	${$_[0]} =~ /\G(....)/sgc or die EOF;
	my $v= unpack 'l<', $1;
	return $v unless $v == -1; # -1 means it is actually 64-bit
	${$_[0]} =~ /\G(........)/sgc or die EOF;
	return unpack 'q<', $1;
}

=head2 pack_v32

=head2 unpack_v32

Pack or unpack a variable-length integer up to 32 bits.  Integer gets encoded as one to five
bytes, and always succeeds.  Decoding will throw an exception if there are insufficient bytes
or if the encoding indicates a value composed of more than five bytes.

  $buf->pack_v32( 0x7FFFFFFF );
  my $x= $buf->unpack_v32;

Note that this uses the same encoding as L</pack_v64> with C<$min_bytes=1>, except that five
bytes could indicate a value greater than 32-bit and this method silently discards any bits
above 32.

=cut

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

=head2 pack_v64

=head2 unpack_v64

Pack or unpack a variable-length integer up to 32 bits.  Integer gets encoded as one to five
bytes, and always succeeds.  Decoding will throw an exception if there are insufficient bytes
or if the encoding indicates a value composed of more than five bytes.

  $buf->pack_v32( 0x7FFFFFFF );
  my $x= $buf->unpack_v32;

Note that this uses the same encoding as L</pack_v64> with C<$min_bytes=1>, except that five
bytes could indicate a value greater than 32-bit and this method silently discards any bits
above 32.

=cut

sub pack_v64 {
	my ($self, $val, $min_bytes)= @_;
	my $packed= pack('q<', $val);
	$packed =~ s/\0+\z//;
	if (length $packed >= $min_bytes) {
		my $hibit= 1 << (7-length($packed)+$min_bytes);
		# Rsync code makes no protection against encoding a value too big for min_bytes.
		# The implementation cannot support more than 6 "variable" bytes in addition to
		# min_bytes, so min_bytes must be at least 3 in order to encode all 64-bit numbers.
		# Interestingly, the encoding could logically support up to 8 variable bytes but
		# the implementation artifically caps it at 6, and would silently corrupt
		# values > 2**48 at min_bytes = 1.
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
	croak "Overflow in unpack_V64" if $n_bytes > 9;
	my $buf= substr($$self, pos($$self)+1, $n_bytes-1);
	pos($$self) += $n_bytes;
	if ($n_bytes < 9) {
		$buf .= "\0"x(9-$n_bytes);
		return unpack('q<', $buf)
			| (($x & ((1 << (8+$min_bytes-$n_bytes))-1)) << (8*($n_bytes-1)));
	} else {
		# this silently discards any data bits in $x.
		return unpack('q<', $buf);
	}
}

=head2 pack_vstring

=head2 unpack_vstring

Pack or unpack a variable length string from the buffer.  The string must be less than 0x7FFF
bytes long.

  $buf->pack_vstring($str);
  $str= $buf->unpack_vstring;

=cut

sub pack_vstring {
	my ($self, $str)= @_;
	$$self .= length $str < 0x80? chr(length $str)
	        : length $str < 0x8000? pack('n', 0x8000 | length $str)
	        : croak "Attempting to send over-long vstring (len=".length($str).')';
	$$self .= $str;
}

sub unpack_vstring {
	my $self= shift;
	$$self =~ /\G( [\0-\x7F] | .. )/xgc or die EOF;
	my $len= unpack('n', $1."\0") & 0x7FFF;
	my $p= pos($$self);
	$p + $len <= length($$self) or die EOF;
	pos($$self) += $len;
	return substr($$self, $p, $len);
}

1;
