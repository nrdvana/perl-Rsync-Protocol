#! /usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/lib";
use RsyncTest;

plan tests => 4;

use_ok( 'Rsync::Protocol' ) or BAIL_OUT;
subtest no_pasword => sub {
	my $p= new_ok( 'Rsync::Protocol' );
	test_parse_with_interruptions(
		[
			[ start_daemon_client => ('AllTheData') ]
		],
		"\@RSYNCD: 31.0\n"
		."AllTheData\n",
		"\@RSYNCD: 30.0\n"
		."\@RSYNCD: OK\n",
		[
			[ 'PROTOCOL', '30' ],
			[ 'OK' ],
		],
	);
};

subtest with_pasword => sub {
	test_parse_with_interruptions(
		[
			[ start_daemon_client => ('AllTheData','user','pass') ],
		],
		"\@RSYNCD: 31.0\n"
		."AllTheData\n"
		."user Zp77fT8TRrZ+9A9JFNT/UA\n",
		"\@RSYNCD: 30.0\n"
		."\@RSYNCD: AUTHREQD qwerty12345\n"
		."\@RSYNCD: OK\n",
		[
			[ 'PROTOCOL', '30' ],
			[ 'OK' ],
		]
	);
};

subtest motd_and_reject => sub {
	test_parse_with_interruptions(
		[
			[ start_daemon_client => ('AllTheData','user','pass') ],
		],
		"\@RSYNCD: 31.0\n"
		."AllTheData\n",
		"\@RSYNCD: 30.0\n"
		."Hello, the rsync server you have reached is unavailable.\n"
		."Please leave a message at the beep.\n"
		."\@RSYNCD: EXIT\n",
		[
			[ 'PROTOCOL', '30' ],
			[ 'INFO', "Hello, the rsync server you have reached is unavailable." ],
			[ 'INFO', "Please leave a message at the beep." ],
			[ 'EXIT' ],
		]
	);
};

