package Rsync::Protocol::Options;
use Moo;
use Try::Tiny;

has motd => ( is => 'rw', default => sub { 1 } );
has implied_dirs => ( is => 'rw', default => sub { 1 } );
has human_readable => ( is => 'rw', default => sub { 1 } );
has inc_recursive => ( is => 'rw', default => sub { 1 } );
sub opt_delete_before { shift->delete('before') }
sub opt_delete_during { shift->delete('during') }
sub opt_delete_after  { shift->delete('after') }
sub opt_delete_delay  { shift->delete('delay') }
sub opt_quiet {
	$_[0]->verbose( ($_[0]->verbose||0) - 1)
}
sub opt_archive {
	my $self= shift;
	$self->recursive(1) unless $self->recursive;
	$self->links(1);
	$self->perms(1);
	$self->times(1);
	$self->group(1);
	$self->owner(1);
	$self->devices(1);
	$self->specials(1);
}
sub opt_old_dirs   { shift->dirs('old'); }
sub opt_fake_super { shift->super('fake'); }
sub opt_D {
	$_[0]->devices(1);
	$_[0]->specials(1);
}
sub opt_no_D {
	$_[0]->devices(0);
	$_[0]->specials(0);
}
sub opt_append_verify {
	shift->append('verify');
}
sub opt_remove_sent_files {
	shift->remove_source_files('sent');
}
has filters => ( is => 'rw' );
sub add_filter {
	my $self= shift;
	my $f= $self->filters;
	$self->filters( $f= [] ) unless $f;
	push @$f, shift;
}

sub opt_F {
	my $called= ++$_[0]{-F};
	# first time, it adds this:
	$_[0]->add_filter(': /.rsync-filter') if $called == 1;
	# second time it is called, it adds this:
	$_[0]->add_filter('- .rsync-filter') if $called == 2;
}
sub opt_filter { $_[0]->add_filter($_[1]); }
sub opt_exclude { $_[0]->add_filter($_[1] =~ /^[-] /? $_[1] : "- $_[1]"); }
sub opt_include { $_[0]->add_filter($_[1] =~ /^[+] /? $_[1] : "+ $_[1]"); }
sub opt_exclude_from { $_[0]->add_filter('merge,- '.$_[1]); }
sub opt_include_from { $_[0]->add_filter('merge,+ '.$_[1]); }
sub opt_old_compress { shift->compress('old') }
sub opt_new_compress { shift->compress('new') }
has partial => ( is => 'rw' );
sub opt_partial {
	$_[0]->partial($_[1]);
	$_[0]->progress(1) if $_[1]; # enable progress if partial being enabled
}
has remote_options => ( is => 'rw' );
sub opt_remote_option {
	my ($self, $opt)= @_;
	$opt =~ /^-/ or die "option must begin with '-': $opt\n";
	my $ropts= $self->remote_options;
	$self->remote_options( $ropts= [ undef ] );
	push @$ropts, $opt;
}
has batch_name => ( is => 'rw' );
has read_batch => ( is => 'rw' );
has write_batch => ( is => 'rw' );
sub opt_read_batch  { $_[0]->batch_name($_[1]); $_[0]->read_batch(1); }
sub opt_write_batch { $_[0]->batch_name($_[1]); $_[0]->write_batch(1); }
sub opt_only_write_batch { $_[0]->batch_name($_[1]); $_[0]->write_batch(-1); }
has max_size => ( is => 'rw' );
has min_size => ( is => 'rw' );
sub opt_max_size {
	my ($self, $size)= @_;
	$self->max_size( _parse_size($size, 'b') );
}
sub opt_min_size {
	my ($self, $size)= @_;
	$self->min_size( _parse_size($size, 'b') );
}
has bwlimit => ( is => 'rw' );
sub opt_bwlimit {
	my ($self, $size)= @_;
	$self->bwlimit( _parse_size($size, 'K') );
}
has append => ( is => 'rw' );
sub opt_append {
	my $self= shift;
	# For servers, it increments.  For clients, it sets to 1.
	$self->append( $self->server? (($self->append||0) + 1) : 1 );
}

has basis_dirs   => ( is => 'rw' );
sub _add_basis_dir {
	my $self= shift;
	my $bdirs= $self->basis_dirs;
	$self->basis_dirs( $bdirs= [] ) unless $bdirs;
	push @$bdirs, shift;
}
has link_dest    => ( is => 'rw' );
has copy_dest    => ( is => 'rw' );
has compare_dest => ( is => 'rw' );
sub opt_link_dest {
	my $self= shift;
	$self->_add_basis_dir(shift);
	$self->link_dest(1);
}
sub opt_copy_dest {
	my $self= shift;
	$self->_add_basis_dir(shift);
	$self->copy_dest(1);
}
sub opt_compare_dest {
	my $self= shift;
	$self->_add_basis_dir(shift);
	$self->compare_dest(1);
}
has usermap => ( is => 'rw' );
has groupmap => ( is => 'rw' );
sub opt_chown {
	my ($self, $u_g)= @_;
	my ($user, $group)= split /:/, $u_g, 2;
	$self->usermap("*:$user");
	$self->groupmap("*:$group") if defined $group;
}
sub opt_usermap {
	my ($self, $map)= @_;
	die "usermap already set\n" if defined $self->usermap;
	$self->usermap($map);
}
sub opt_groupmap {
	my ($self, $map)= @_;
	die "groupmap already set\n" if defined $self->groupmap;
}
has acls => ( is => 'rw' );
sub opt_acls {
	# --acls implies --perms
	$_[0]->acls(1);
	$_[0]->perms(1);
}
has source => ( is => 'rw' );
has dest   => ( is => 'rw' );

our @options= qw(
	8-bit-output|8!
	acls|A!
	address=s
	append!
	append-verify
	archive|a
	backup!
	backup-dir=s
	blocking-io!
	block-size|B
	bwlimit!=s
	checksum|c!
	checksum-seed=i
	chmod=s
	chown=s
	compare-dest=s
	compress-level=i
	compress|z+
	config=s
	contimeout!=i
	copy-dest=s
	copy-dirlinks|k
	copy-links|L
	copy-unsafe-links
	cvs-exclude
	D!
	daemon
	debug=s
	delay-updates
	delete
	delete-after
	delete-before
	delete-delay
	delete-during|del
	delete-excluded
	delete-missing-args
	detach!
	devices!
	dirs|d!
	dparam=s
	dry-run|n
	exclude-from=s
	exclude=s
	executability|E
	F
	fake-super
	files-from=s
	filter|f=s
	force!
	from0!
	fuzzy|y!+
	group|g!
	groupmap=s
	hard-links|H!+
	help
	human-readable|h!+
	iconv!=s
	ignore-errors!
	ignore-existing
	ignore-missing-args
	ignore-non-existing|existing
	ignore-times|I
	implied-dirs|i-d!
	include-from=s
	include=s
	inc-recursive|i-r!
	info=s
	inplace!
	ipv4|4
	ipv6|6
	itemize-changes|i!+
	keep-dirlinks|K
	link-dest=s
	links|l!
	list-only
	log-file-format=s
	log-file=s
	max-delete=i
	max-size=s
	min-size=s
	modify-window=i
	motd!
	msgs2stderr
	munge-links!
	new-compress
	no-iconv
	numeric-ids!
	old-compress
	old-dirs|old-d
	omit-dir-times|O!
	omit-link-times|J!
	one-file-system|x!+
	only-write-batch=s
	outbuf=s
	out-format|log-format=s
	owner|o!
	P
	partial!
	partial-dir=s
	password-file=s
	perms|p!
	port=i
	preallocate
	progress!
	protect-args|s!
	protocol=i
	prune-empty-dirs|m!
	qsort
	quiet|q
	read-batch=s
	recursive|r!
	relative|R!
	remote-option|M=s
	remove-sent-files
	remove-source-files
	rsh|e=s
	rsync-path=s
	safe-links
	sender
	server
	size-only
	skip-compress=s
	sockopts=s
	sparse|S!
	specials!
	stats
	suffix=s
	super!
	temp-dir|T=s
	timeout!=i
	times|t!
	update|u
	usermap=s
	verbose|v!+
	version
	whole-file|W!
	write-batch=s
	xattrs|X!
);
our %option_val_type;
sub option_val_type { $option_val_type{$_[1]} }

__PACKAGE__->_setup_option($_) for @options;
sub _setup_option {
	my ($class, $spec)= @_;
	# Spec is compoased of names and optional negation, and the accessor is either
	# a boolean (default) or incrementer or value-capture.
	my ($names, $neg, $inc, $val)= ($spec =~ /^([^=!]+)(!)?([+])?(=[si])?$/)
		or die "Invalid option spec '$spec'";
	$names =~ s/-/_/g;
	my ($attr, @aliases)= split /\|/, $names;
	# Keep track of which options need an extra argument
	if (defined $val) {
		$option_val_type{$_}= substr($val,1) for $attr, @aliases;
	}
	my $method= "opt_".$attr;
	no strict 'refs';
	# If the opt_X is not defined, then declare the attribute and method
	unless ($class->can($method)) {
		$class->can('has')->($attr, is => 'rw') unless $class->can($attr);
		*{ $class . '::' . $method }=
			$inc? sub { $_[0]->$attr( ($_[0]->$attr || 0) + 1 ) }
			: $val? sub { $_[0]->$attr($_[1]) }
			: sub { $_[0]->$attr(1) };
	}
	# point the aliases at it
	*{ $class . '::opt_' . $_ }= $class->can($method) for @aliases;
	# Create negations if needed
	if ($neg) {
		my $neg_method= 'opt_no_'.$attr;
		unless ($class->can($neg_method)) {
			*{ $class . '::' . $neg_method }=
				$val? sub { $_[0]->$attr($_[1]); }
				: sub { $_[0]->$attr(0); }
		}
		*{ $class . '::opt_no_' . $_ }= *{ $class . '::' . $neg_method }
			for @aliases;
	}
}

my %suffix_mult= (
	b => 1, bb => 1, bib => 1,
	kb => 1000,
	mb => 1000000,
	gb => 1000000000,
	k => 1024, kib => 1024,
	m => 1024*1024, mib => 1024*1024,
	g => 1024*1024*1024, gib => 1024*1024*1024,
);
sub _parse_size {
	my ($str, $default_suffix)= @_;
	$str =~ /^(\d*\.?\d*)([kmgb](?:i?b)?)?([+-]1)?$/i
		or die "invalid size: '$str'\n";
	return $1 * $suffix_mult{lc($2 || $default_suffix)} + ($3 || 0);
}

sub apply_argv_return_error {
	my ($self, @argv)= @_;
	try {
		$self->apply_argv(@argv);
		undef;
	} catch {
		chomp;
		$_;
	};
}

sub apply_argv {
	my ($self, @argv)= @_;
	while (@argv) {
		my $arg= shift @argv;
		# Long option
		if (my ($name, $val)= ($arg =~ /^--([^=]+)=?(.*)/)) {
			$name =~ s/-/_/g;
			my $method= $self->can("opt_$name") or die "unknown option $arg\n";
			if ($option_val_type{$name}) {
				defined $val or @argv && $argv[0] !~ /^-/
					or die "Missing required value for '$arg'\n";
				$method->($self, defined $val? $val : shift @argv);
			} else {
				$method->($self);
			}
		}
		# Short option, possibly bundled
		elsif (my ($opts)= ($arg =~ /^-([^-].*)$/)) {
			my $i= 0;
			while ($i < length $opts) {
				my $o= substr($opts, $i++, 1);
				my $method= $self->can("opt_$o") or die "unknown option -$o\n";
				if ($option_val_type{$o}) {
					# A short option that takes a value will consume the rest of the bundle
					# Else it consumes the next argument
					$method->($self, $i < length $opts? substr($opts, $i) : shift @argv);
					$i= length $opts;
				} else {
					$method->($self);
				}
			}
		}
		# End of options
		elsif ($arg eq '--') {
			return 1;
		}
		else {
			!(grep /^-/, @argv)
				or die "Encountered stray argument before end of options\n";
			unshift @argv, $arg;
			last;
		}
	}
	
	@argv <= 2
		or die "Too many non-options at end of argument list\n";
	$self->source(shift @argv) if @argv;
	$self->dest(shift @argv) if @argv;
	return 1;
}

1;
