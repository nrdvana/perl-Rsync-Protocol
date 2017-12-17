#! /usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/lib";
use RsyncTest;

use_ok( 'Rsync::Protocol::Options' )
 && new_ok( 'Rsync::Protocol::Options' ) or BAIL_OUT;

# Try calling every 'opt' method
subtest option_methods => sub {
	for my $opt (grep { /^opt_/ } sort keys %Rsync::Protocol::Options::) {
		my $name= substr($opt, 4);
		my $vtype= Rsync::Protocol::Options->option_val_type($name);
		my @arg= !$vtype? ()
			: ($name eq 'M' or $name eq 'remote_option')? ('-Foo')
			: ('1');
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

subtest parse_argv => sub {
	my @defaults= (
		motd => 1,
		implied_dirs => 1,
		human_readable => 1,
		inc_recursive => 1,
	);
	my @tests= (
		[qw( -avxH --delete )],
		{
			@defaults,
			recursive => 1, owner => 1, group => 1, perms => 1, times => 1,
			devices => 1, specials => 1, links => 1,
			verbose => 1,
			one_file_system => 1,
			hard_links => 1,
			delete => 1,
		}
	);
	while (my ($argv, $attrs)= splice(@tests, 0, 2)) {
		my $opt= Rsync::Protocol::Options->new;
		$opt->apply_argv( @$argv );
		is_deeply( { %$opt }, $attrs, join(' ', @$argv) )
			or diag explain { %$opt };
	}
};

done_testing;
