package Rsync::Protocol::Checksum::None;

require Rsync::Protocol::Checksum;

=head1 DESCRIPTION

This checksum class always returns a single NUL byte as it's digest.
It has mock methods to make it look like a normal Digest:: class.

=cut
