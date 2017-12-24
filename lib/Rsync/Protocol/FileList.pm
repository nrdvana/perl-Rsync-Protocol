package Rsync::Protocol::FileList;

use Moo;
use Carp;

has proto     => ( is => 'rw', weak_ref => 1 );
has id        => ( is => 'rw' );
has start_idx => ( is => 'rw' );
has files     => ( is => 'rw', default => sub { [] } );

# The ->files list needs to remain un-sorted, because those index numbers are used during
# the transfer.  So, sorted is a second array built on demand.  Note that the sort order
# depends on the protocol version, so this depends on $proto->protocol_version

has sorted    => ( is => 'lazy' );

sub _build_sorted {
	my $self= shift;
	defined $self->proto->protocol_version
		or croak "Can't sort file list until protocol version is known";
	# Remove all dead entries
	my @sorted= grep { defined $_ && defined $_->{name} } @{ $self->files };
	# Calculate canonical path for each
	$_->{_key}= $self->_sort_key_for_item($_) for @sorted;
	# Sort all entries
	@sorted= sort { $a->{_key} cmp $b->{_key} } @sorted;
	\@sorted;
}

sub remove_duplicates_from_sorted {
	my $self= shift;
	my $sorted= $self->sorted;
	my $ver= $self->proto->protocol_version;
	my %by_key;
	for my $i (0 .. $#$sorted) {
		my $cur= $sorted->[$i];
		my $key= $cur->{_key};
		# With version 29, the keys for files contain a NUL byte to make them
		# sort first.  Remove it so we can check for conflicts without regard to type.
		$key =~ s/\0// if $ver >= 29 && !($cur->{mode} & S_IFDIR);
		my $dup_idx= $by_key{$key};
		if (!defined $dup_idx) {
			$by_key{$key}= $i;
		}
		else {
			my $dup= $sorted->[$dup_idx];
			# Keep the directory, but if both are then keep the first one.
			# Only remove from the list if we are not sender.
			if ($cur->{mode} & S_IFDIR) {
				if ($dup->{mode} & S_IFDIR) {
					if ($self->proto->opt->sender) {
						$cur->{flags} |= FLAG_DUPLICATE;
					} else {
						$dup->{flags} |= $cur->{flags} & (FLAG_TOP_DIR|FLAG_CONTENT_DIR);
						$dup->{flags} &= $cur->{flags} | ~FLAG_IMPLIED_DIR;
						$sorted->[$i]= undef;
					}
				} elsif (!$self->proto->opt->sender) {
					$sorted->[$dup_idx]= undef;
					$by_key{$key}= $i;
				}
			} else {
				$sorted->[$i]= undef unless $self->proto->opt->sender;
			}
		}
	}
	# clean away any removed items
	@$sorted= grep defined, @$sorted;
	1;
}

# The rsync file-list has undergone quite a lot of changes across protocol versions.
# It also differs significantly based on which options are in effect.
# It is really slow to check all of these conditions for every single file list entry,
# so this routine dynamically assembles perl code to perform only the needed processing
# per call.  As an added benefit, it can close over local variables to speed up the
# comparison to the previous encoded entry.

has _entry_encoder => ( is => 'lazy' );
sub _build__entry_encoder {
	my $self= shift;
	my $proto= $self->proto;
	my $ver= $proto->protocol_version;
	my $code= 'sub {
		my ($self, $f)= @_;
		my $proto= $self->proto;
		my $buf= $proto->wbuf;';

	# Initialize flags
	my $flags;
	if ($ver >= 30) {
		$code .= '
		$flags= !($f->{mode} & S_IFDIR)? 0
			: ($f->{flags} && ($f->{flags} & FLAG_CONTENT_DIR))? $f->{flags} & FLAG_TOP_DIR;
			: ($f->{flags} && ($f->{flags} & FLAG_IMPLIED_DIR))? XMIT_TOP_DIR | XMIT_NO_CONTENT_DIR
			: XMIT_NO_CONTENT_DIR;';
	} else {
		$code .= '
		$flags= !($f->{mode} & S_IFDIR)? 0
			: $f->{flags} & FLAG_TOP_DIR;';
	}

	# Same mode as previous?
	my $mode= -1;
	$code .= '
	$flags |= XMIT_SAME_MODE if $mode == $f->{mode};
	$mode= $f->{mode};';

	# Same device 'rdev' as before?
	my ($rdev, $xmit_rdev);
	if ($opt->devices) {
		$rdev= -1;
		$code .= '
		if ($mode & (S_IFBLK|S_IFCHR)) {';
		if ($ver < 28) {
			# Protocol 27 and below have flag for recurring device numbers
			$code .= '
			$xmit_rdev= $rdev != $f->{rdev};
			$flags |= XMIT_SAME_RDEV_pre28 unless $xmit_rdev;';
		} else {
			# protocol 28 and above have flag for re-using device.major
			$code .= '
			$xmit_rdev= 1;
			$flags |= XMIT_SAME_RDEV_MAJOR if defined $rdev && major($f->{rdev}) == major($rdev);';
			# Protocol 28, 29 have a flag for xmitting device.minor as a single byte
			$code .= '
			$flags |= XMIT_RDEV_MINOR_8_pre30 if minor($f->{rdev}) <= 0xFF;'
				if $ver < 30;
		}
		$code .= '
			$rdev= $f->{rdev};
		}';
	}
	# Version 31 no longer transmits a rdev for specials (since not needed)
	if ($opt->specials && $ver < 31) {
		$code .= '
		'.($opt->devices?' els':'').'if ($mode & (S_IFIFO|S_IFSOCK)) {';
		# Special files don't need an rdev number, so just make
		# the historical transmission of the value efficient.
		if ($ver < 28) {
			$code .= '
			$xmit_rdev= 0;
			$flags |= XMIT_SAME_RDEV_pre28;';
		}
		else {
			$code .= '
			$xmit_rdev= 1;
			$rdev= MAKEDEV(major($rdev), 0);
			$flags |= XMIT_SAME_RDEV_MAJOR '.($ver < 30? '| XMIT_RDEV_MINOR_8_pre30':'').';';
		}
		$code .= '
		}';
	}
	if ($ver < 28) {
		# 27 and below always overwrite rdev if current entry is not a device/special.
		$code .= ($opt->devices || $opt->specials)? ' else {
			$xmit_rdev= 0;
			$rdev= MAKEDEV(0, 0);
		}' : '
		$xmit_rdev= 0;
		$rdev= MAKEDEV(0, 0);';
	}

	# Same UID as previous?
	my ($uid, $username, %uid_map);
	if (!$opt->user) {
		$code .= '
		$flags |= XMIT_SAME_UID;';
	} else {
		$uid= -1;
		$code .= '
		if ($uid == ($f->{uid} || 0)) {
			$flags |= XMIT_SAME_UID;
		} else {
			$uid= $f->{uid} || 0;';
		if (!$opt->numeric_ids) {
			$code .= '
			if (!defined $uid_map{$uid}++) {
				$username= $proto->_get_username_for_uid($uid);';
			$code .= '
				$flags |= XMIT_USER_NAME_FOLLOWS if defined $username && length($username) < 255;'
				if $opt->inc_recurse;
			$code .= '
			}';
		}
		$code .= '
		}';
	}

	# Same GID as previous?
	my ($gid, $groupname, %gid_map);
	if (!$opt->group) {
		$code .= '
		$flags |= XMIT_SAME_GID;';
	} else {
		$gid= -1;
		$code .= '
		if ($gid == ($f->{gid} || 0)) {
			$flags |= XMIT_SAME_GID;
		} else {
			$gid= $f->{gid} || 0;';
		if (!$opt->numeric_ids) {
			$code .= '
			if (!defined $gid_map{$gid}++) {
				$groupname= $proto->_get_groupname_for_gid($gid);';
			$code .= '
				$flags |= XMIT_GROUP_NAME_FOLLOWS if defined $groupname && length($groupname) < 255;'
				if $opt->inc_recurse;
			$code .= '
			}';
		}
		$code .= '
		}';
	}
	
	# Same mtime as previous?
	my $mtime;
	$code .= '
	$flags |= XMIT_SAME_TIME if defined $mtime and $f->{mtime} == $mtime;
	$mtime= $f->{mtime}';
	$code .= '
	$flags |= XMIT_MOD_NSEC if defined $f->{mtime_nsec};'
		if $ver >= 31;

	# Hard Links.
	# Version 30 of the protocol writes first occurrence of an inode with the "HLINK_FIRST"
	# flag, and then if it appears again it writes out the previous index within the filelist.
	# Previous versions wrote the device number and inode into the filelist for every file.
	my ($hlink_found, %hlink_map, $dev, $prev_dev, $fake_inode);
	if ($opt->hard_links) {
		$code .= '
		$flags |= XMIT_HLINKED;
		my $prev_dev= $dev;
		($dev, $ino)= @{$f}{"dev","ino");';
		if ($ver >= 30) {
			$code .= '
			$hlink_found= defined $dev && defined $ino? $hlink_map{$dev}{$ino} : undef;
			if (!defined $hlink_found) {
				$flags |= XMIT_HLINK_FIRST;
				$hlink_map{$dev}{$ino}= $self->start_idx + $f->{idx};
			}';
		} else {
			# If the user of this library doesn't supply device/inode, then fake them.
			# This is only needed for versions older than 30 where the dev/inode values
			# get sent to the receiver.
			$code .= '
			if (defined $dev && defined $ino) {
				$dev++ if $dev >= 120; # make room for our fake device
			} else {
				($dev, $ino)= (120, ++$fake_inode);
			}'.($ver >= 28? '
			$flags |= XMIT_SAME_DEV_pre30 if defined $prev_dev && $dev == $prev_dev;' : '').'
			$dev= $f->{dev};';
		}
	}

	# Compare previous and current filename
	my ($name, $prev_name);
	$code .= '
	my $match_n= 0;
	($name, $prev_name)= ($f->{name}, $name);
	my $match_lim= min 255, length($name);
	$match_n++
		while $match_n < $match_lim
		   && substr($name, $match_n, 1) eq substr($prev_name, $match_n, 1);
	my $name_diff= substr($name, $match_n);
	$flags |= XMIT_SAME_NAME if $match_n;
	$flags |= XMIT_LONG_NAME if length $name_diff > 255;';

	# Write Flags
	# Make sure at least one bit is set in flags
	if ($ver >= 28) {
		$code .= '
		# Use XMIT_TOP_DIR on non-dir, which has no meaning
		$flags |= XMIT_TOP_DIR if !$flags && !($mode & S_IFDIR);
		# Else use longer flags encoding
		if (($flags & 0xFF00) || !$flags) {
			$flags |= XMIT_EXTENDED_FLAGS;
			$buf->write_shortint($flags);
		} else {
			$buf->write_byte($flags);
		}';
	} else {
		$code .= '
		$flags |= ($mode & S_IFDIR) ? XMIT_LONG_NAME : XMIT_TOP_DIR
			unless $flags & 0xFF;
		$buf->write_byte($flags);';
	}
	
	# Write Name (portion different from previous)
	$code .= '
	$buf->write_byte($match_n) if $flags & XMIT_SAME_NAME;
	if ($flags & XMIT_LONG_NAME) {
		$buf->write_varint30(length $name_diff);
	} else {
		$buf->write_byte(length $name_diff);
	}
	$buf->append($name_diff);
	';
	
	# If repeated hardlink in version 30+, write the file list index and skip the rest.
	$code .= '
	if (defined $hlink_found) {
		$buf->write_varint($hlink_found);
		return if $hlink_found < $self->start_idx;
	}' if $opt->hard_links && $ver >= 30;
	
	# File Size
	$code .= '
	$buf->write_varlong30($f->{size}, 3);';

	# Mtime
	$code .= $ver >= 30? '
	$buf->write_varlong($mtime, 4) unless $flags & XMIT_SAME_TIME;' : '
	$buf->write_int($mtime) unless $flags & XMIT_SAME_TIME;';
	$code .= '
	$buf->write_varint($f->{mtime_nsec}) if $flags & XMIT_MOD_NSEC;';
	
	# Mode
	$code .= '
	$buf->write_int(to_wire_mode($mode)) unless $flags & XMIT_SAME_MODE;';

	# UID and maybe User Name
	if ($opt->user) {
		if ($ver < 30) {
			$code .= '
			$buf->write_int($uid) unless $flags & XMIT_SAME_UID;';
		} else {
			$code .= '
			unless ($flags & XMIT_SAME_UID) {
				$buf->write_varint($uid);
				if ($flags & XMIT_USER_NAME_FOLLOWS) {
					$buf->write_byte(length $username);
					$buf->append($username);
				}
			}';
		}
	}

	# GID and maybe Group Name
	if ($opt->group) {
		if ($ver < 30) {
			$code .= '
			$buf->write_int($gid) unless $flags & XMIT_SAME_GID;';
		} else {
			$code .= '
			unless ($flags & XMIT_SAME_GID) {
				$buf->write_varint($gid);
				if ($flags & XMIT_GROUP_NAME_FOLLOWS) {
					$buf->write_byte(length $groupname);
					$buf->append($groupname);
				}
			}';
		}
	}

	# Device node major/minor
	$code .= '
	if ($xmit_rdev) {';
	if ($ver < 28) {
		$code .= '
		$buf->write_int($rdev);';
	} elsif ($ver < 30) {
		$code .= '
		$buf->write_varint30(major($rdev))
			unless $flags & XMIT_SAME_RDEV_MAJOR;
		if ($flags & XMIT_RDEV_MINOR_8_pre30) {
			$buf->write_byte(minor($rdev));
		} else {
			$buf->write_int(minor($rdev));
		}';
	} else {
		$code .= '
		$buf->write_varint30(major($rdev))
			unless $flags & XMIT_SAME_RDEV_MAJOR;
		$buf->write_varint(minor($rdev));';
	}
	$code .= '
	}';

	# Symlink content
	$code .= '
	if (defined $f->{symlink}) {
		$buf->write_varint30(length $f->{symlink});
		$buf->append($f->{symlink});
	}';

	# Device/Inode.  Only needed if hardlinks enabled and protocol < 30 where the receiver
	# needs to know all device/inode numbers.  dev number is incremented to avoid sending 0.
	if ($opt->hard_links && $ver < 26) {
		$code .= '
		$buf->write_int($dev+1);
		$buf->write_int($ino);';
	}
	# Protocol 27..29 use 64-bit dev/inode
	elsif ($opt->hard_links && $ver < 30) {
		$code .= '
		$buf->write_longint($dev+1) unless $flags & XMIT_SAME_DEV_pre30;
		$buf->write_longint($ino);';
	}

	# File Checksum
	my ($checksum_class, $empty_sum);
	if ($opt->checksum) {
		$checksum_class= $self->_get_checksum_class($ver, $opt);
		$code .= '
		if (S_ISREG($mode)) {
			$buf->append($checksum_class->filelist_checksum($f));
		}';
		# Prior to 28, non-files had a bogus checksum
		if ($ver < 28) {
			$empty_sum= $checksum_class->filelist_checksum({ data => '' });
			$empty_sum= "\0" x length $empty_sum;
			$code .= '
			else { $buf->append($empty_sum); }';
		}
	}
	
	$code .= "\n}\n";
	
	# Now compile it!
	return eval($code) || croak "Failed to compile file-list encoder: $!\n\n$code";
}

sub _get_checksum_class {
	my ($self, $ver, $opt)= @_;
	Rsync::Protocol::Checksum->select_class($opt->checksum_flist_choice, $ver);
}

sub _sort_key_for_item {
	my ($self, $item)= @_;
	my ($dir, $name)= @{$item}{'dir','name'};
	defined $name or croak "Missing 'name' in file list entry";
	# Prior to 29, the files and directories were sorted together by name, as-is.
	# With version 29, the directories are sorted as if they contained a trailing '/'
	# and the '.' directory is treated as the directory itself, but also we have to
	# guarantee that files in a directory are sorted before subdirs in that directory.
	# So, use a NUL byte in place of the final directory separator for all non-dir
	# entries.
	# So for example,
	#   dir => 'foo',      name => '.'                      key => 'foo'
	#   dir => 'foo',      name => 'bar9' (and is a file)   key => 'foo\0bar9'
	#   dir => 'foo',      name => 'bar1' (and is a dir)    key => 'foo/bar1'
	#   dir => 'foo/bar1', name => '.'                      key => 'foo/bar1'  #duplicate
	# In actual rsync, this is handled by complex comparison functions.  I estimate
	# that this key design will execute much faster in Perl though it will consume
	# extra memory.  (but we're already paying for a hash table per item)
	if ($self->proto->protocol_version < 29) {
		return defined $dir && length $dir? $dir.'/'.$name : $name;
	} elsif (!($item->{mode} & S_IFDIR)) {
		return defined $dir && length $dir? $dir."\0".$name : "\0".$name;
	} elsif ($name eq '.') {
		return defined $dir && length $dir? $dir : '';
	} else {
		return defined $dir && length $dir? $dir."/".$name : $name;
	}
}

1;

__END__
# Sort function operates on $a,$b
sub _cmp_fname_29 {
	local ($a, $b)= @_ if @_;
	# If the entry is a directory itself, append to the directory string, and if it is '.'
	# then consider that equivalent to the name of the directory.
	my ($a_dir, $a_name)= @{$a}{'dir','name'};
	my ($b_dir, $b_name)= @{$b}{'dir','name'};
	if ($a->{mode} & S_IFDIR) {
		$a_dir= length $a_dir? $a_dir.'/'.$a_name : $a_name
			unless $a_name eq '.';
		$a_name= '';
	}
	if ($b->{mode} & S_IFDIR) {
		$b_dir= length $b_dir? $b_dir.'/'.$b_name : $b_name
			unless $b_name eq '.';
		$b_name= '';
	}
	return (
		$a_dir cmp $b_dir
		or $a_name cmp $b_name
	);
}

# Sort function operates on $a,$b
sub _cmp_fname_pre29 {
	local ($a, $b)= @_ if @_;
	# Compare dirname+filename, except don't prefix '/' for empty dirname
	return (
		( length $a->{dir}? "$a->{dir}/$a->{name}" : $a->{name} )
		cmp
		( length $b->{dir}? "$b->{dir}/$b->{name}" : $b->{name} );
	);
}

