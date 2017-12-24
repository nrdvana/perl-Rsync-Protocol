#! /usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/lib";
use RsyncTest;

plan tests => 4;

use_ok( 'Rsync::Protocol' ) or BAIL_OUT;

my @collection= (
	{ dir => '',  name => 'a',              dev => 0x10303, ino => 0x5025FD, mode => 0x41ED, uid => 0x000, gid => 0x000, mtime => 0x5A3D9431 },
	{ dir => 'a', name => 'file1',          dev => 0x10303, ino => 0x5025FE, mode => 0x81A4, uid => 0x402, gid => 0x000, mtime => 0x5A3D91F1, size => 0, data => '' },
	{ dir => 'a', name => 'file2',          dev => 0x10303, ino => 0x5025FF, mode => 0x81A4, uid => 0x000, gid => 0x402, mtime => 0x5A3D9392, size => 0, data => '' },
	{ dir => 'a', name => 'file3',          dev => 0x10303, ino => 0x502600, mode => 0x81A4, uid => 0x403, gid => 0x000, mtime => 0x5A3D91F9, size => 5, data => "test\n" },
	{ dir => 'a', name => 'file4-link',     dev => 0x10303, ino => 0x5025FE, mode => 0x81A4, uid => 0x402, gid => 0x000, mtime => 0x5A3D91F1, size => 0, symlink => 'file1' },
	{ dir => 'a', name => 'file5-hardlink', dev => 0x10303, ino => 0x502600, mode => 0x81A4, uid => 0x403, gid => 0x000, mtime => 0x5A3D91F9, size => 5, data => "test\n" },
	{ dir => 'a', name => 'null',           dev => 0x10303, ino => 0x502606, mode => 0x21B6, uid => 0x000, gid => 0x000, mtime => 0x5A3CCB43, rdev => 0x0103 },
	{ dir => 'a', name => 'sg0',            dev => 0x10303, ino => 0x502607, mode => 0x21B0, uid => 0x000, gid => 0x05D, mtime => 0x5A3CCB43, rdev => 0x1500 },
	{ dir => 'a', name => 'sg1',            dev => 0x10303, ino => 0x502608, mode => 0x21B0, uid => 0x000, gid => 0x006, mtime => 0x5A3CCB44, rdev => 0x1501 }, 
	{ dir => 'a', name => 'sg2',            dev => 0x10303, ino => 0x502609, mode => 0x21B0, uid => 0x000, gid => 0x006, mtime => 0x5A3CCB44, rdev => 0x1502 }, 
	{ dir => '',  name => 'b',              dev => 0x10303, ino => 0x502602, mode => 0x41ED, uid => 0x000, gid => 0x000, mtime => 0x5A3D92A7 },
	{ dir => 'b', name => '_',              dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => '__',             dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => '___',            dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => '____',           dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => '_____',          dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => '______',         dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => '_______',        dev => 0x10303, ino => 0x502605, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D92C3, size => 0x5, data => "test\n" }, 
	{ dir => 'b', name => 'asdfgh',         dev => 0x10303, ino => 0x502604, mode => 0x81A4, uid => 0x400, gid => 0x000, mtime => 0x5A3D9281, size => 0xE, data => "testing 4 5 6\n" }, 
	{ dir => 'b', name => 'qwerty',         dev => 0x10303, ino => 0x502603, mode => 0x81A4, uid => 0x401, gid => 0x000, mtime => 0x5A3D9270, size => 0xE, data => "testing 1 2 3\n" }, 
);

subtest basic => sub {
	my $p= new_ok( 'Rsync::Protocol' );
	my ($client, $server)= concat_trace_client_server(load_trace 'rsyncd-list-only-a-31');
	test_parse_with_interruptions(
		[
			[ start_daemon_server => () ],
			[ send_ok => () ],
			[ send_file_list => [ @collection ] ],
		],
		$server, $client,
		[
			[ 'PROTOCOL', '30' ],
			[ 'MODULE', 'collection' ],
			[ 'COMMAND', '--server', '--sender', '-vlogDtprxe.iLsfxC', '--list-only', '.', 'collection' ],
		],
	);
};
