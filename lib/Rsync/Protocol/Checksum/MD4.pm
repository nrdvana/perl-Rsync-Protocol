package Rsync::Protocol::Checksum::MD4;

require Rsync::Protocol::Checksum;

=head1 DESCRIPTION

This class is a simple wrapper around Digest::MD4, with the extra methods that Rsync::Protocol
needs.  It does I<not> implement the buggy MD4 implementation needed by Rsync protocol 26 or
earlier.

=cut
