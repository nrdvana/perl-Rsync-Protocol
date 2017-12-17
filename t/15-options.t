#! /usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/lib";
use RsyncTest;

use_ok( 'Rsync::Protocol::Options' ) or BAIL_OUT;
new_ok( 'Rsync::Protocol::Options' ) or BAIL_OUT;

# Try calling every 'opt' method
subtest option_methods => sub {
	for my $opt (grep { /^opt_/ } sort keys %Rsync::Protocol::Options::) {
		my $name= substr($opt, 4);
		my $vtype= Rsync::Protocol::Options->option_val_type($name);
		my @arg= (!$vtype? ()
			: ($name eq 'M' or $name eq 'remote_option')? ('-Foo')
			: ('1'));
		die "WTF opt=$opt name=$name" if ($opt eq 'opt_M' && $arg[0] ne '-Foo');
		local $@;
		ok(
			eval { Rsync::Protocol::Options->new->$opt(@arg); 1; },
			"set $opt"
		) or diag "$opt(@arg): $@";
	}
};

subtest parse_size => sub {
	my $opt= Rsync::Protocol::Options->new;
	my @tests= (
		'10' => 10,
		'10b' => 10,
		'10kb' => 10000,
		'10mb' => 10000000,
		'2gb' => 2000000000,
		'2.13gb' => 2130000000,
		'2K' => 2048,
		'2M' => 2048*1024,
		'2G' => 2048*1024*1024,
		'2GiB' => 2048*1024*1024,
	);
	while (my ($spec, $value)= splice(@tests, 0, 2)) {
		$opt->opt_min_size($spec);
		is( $opt->min_size, $value, $spec );
	}
};

done_testing;
