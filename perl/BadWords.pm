#
# Search for bad words in strings
#
# Copyright (c) 2000 Dirk Koopman
#
#
#

package BadWords;

use strict;

use DXUtil;
use DXVars;
use DXDebug;

use IO::File;

our $regex;					# the big bad regex generated from @relist
our @relist; # the list of regexes to try, record = [canonical word, regex] 
my %in;	# the collection of words we are building up and their regexes


# load the badwords file(s)
sub load
{
	%in = ();
	@relist = ();
	$regex = '';

	my @inw;
	my @out;
	my $wasold;
	

	my $newfn = localdata("badword.new");
	filecopy("$main::data/badword.new.issue", $newfn) unless -e $newfn;
	if (-e $newfn) {
		# new style
		dbg("BadWords: Found new style badword.new file");
		my $fh = new IO::File $newfn;
		if ($fh) {
			while (<$fh>) {
				chomp;
				next if /^\s*\#/;
				add_regex(uc $_);
			}
			$fh->close;
			@relist = sort {$a->[0] cmp $b->[0]} @relist; # just in case...
			dbg("BadWords: " . scalar @relist . " new style badwords read");
		}
		else {
			my $l = "BadWords: can't open $newfn $!";
			dbg($l);
			push @out, $l;
			return @out;
		}
	}
	else {

		# using old style files 
		my $bwfn = localdata("badword");
		filecopy("$main::data/badword.issue", $bwfn) unless -e $bwfn;
	
		# parse the existing static file
		dbg("BadWords: Using old style badword file");
	
		my $fh = new IO::File $bwfn;
		if ($fh) {
			my $line = 0;
			while (<$fh>) {
				chomp;
				++$line;
				next if /^\s*\#/;
				unless (/\w+\s+=>\s+\d+,/) {
					dbg("BadWords: syntax error in $bwfn:$line '$_'");
					next;
				}
				my @line =  split /\s+/, uc $_;
				shift @line unless $line[0];
				push @inw, $line[0];
			}
			$fh->close;
		}
		else {
			my $l = "BadWords: can't open $bwfn $!";
			dbg($l);
			push @out, $l;
			return @out;
		}

		# do the same for badw_regex
		my $regexfn = localdata("badw_regex");
		filecopy("$main::data/badw_regex.gb.issue", $regexfn) unless -e $regexfn;
		dbg("BadWords: Using old style badw_regex file");
		$fh = new IO::File $regexfn;
	
		if ($fh) {
			while (<$fh>) {
				chomp;
				next if /^\s*\#/;
				next if /^\s*$/;
				push @inw, split /\s+/, uc $_;
			}
			$fh->close;
		}
		else {
			my $l = "BadWords: can't open $regexfn $!";
			dbg($l);
			push @out, $l;
			return @out;
		}

		++$wasold;
	}

	# catch most of the potential duplicates
	@inw = sort @inw;
	for (@inw) {
		add_regex($_);
	}
	
	# create the master regex
	generate_regex();
	
	# use new style from now on
	put() if $wasold;
	

	return @out;
}

sub generate_regex
{
	my $res;
	@relist = sort {$a->[0] cmp $b->[0]} @relist;
	for (@relist) {
		$res .= qq{(?:$_->[1]) |\n};
	}
	$res =~ s/\s*\|\s*$//;
	$regex = qr/\b($res)/x;
}


sub _cleanword
{
	my $w = uc shift;
	$w =~ tr/01/OI/;			# de-leet any incoming words
	my $last = '';	# remove duplicate letters (eg BOLLOCKS > BOLOCKS)
	my @w;
	for (split //, $w) {
		next if $last eq $_;
		$last = $_;
		push @w, $_;
	}
	return @w ? join('', @w) : '';
}

sub add_regex
{
	my @list = split /\s+/, shift;
	my @out;
	
	for (@list) {
		my $w = uc $_;
		$w = _cleanword($w);

		next unless $w && $w =~ /^\w+$/; # has to be a word
		next if $in{$w};	   # ignore any we have already dealt with
		next if _slowcheck($w); # check whether this will already be detected

		# re-leet word (in regex speak)if required
		my @l = map { s/O/[O0]/g; s/I/[I1]/g; $_ } split //, $w;
		my $e = join '+[\s\W]*',  @l;
		my $q = $e;
		push @relist, [$w, $q];
		$in{$w} = $q;
		dbg("$w = $q") if isdbg('badword');
		push @out, $w;
	}
	return @out;
}

sub del_regex
{
	my @list = split /\s+/, shift;
	my @out;

	for (@list) {
		my $w = uc $_;
		$w = _cleanword($w);
		next unless $in{$w};
		delete $in{$w};
		@relist = grep {$_->[0] ne $w} @relist;
		push @out, $w
	}
	return @out;
}

sub list_regex
{
	my $full = shift;
	return map { $full ? "$_->[0] = $_->[1]" : $_->[0] } @relist;
}

# check the text against the badwords list
sub check
{
	my $s = uc shift;
	my @out;
	
	if ($regex) {
		my %uniq;
		@out = grep {++$uniq{$_}; $uniq{$_} == 1 ? $_ : undef }($s =~ /\b($regex)/g);
		dbg("BadWords: check '$s' = '" . join(', ', @out) . "'") if isdbg('badword');
		return @out;
	}
	return _slowcheck($s) if @relist;
	return;
}


sub _slowcheck
{
	my $w = shift;
	my @out;
	
	for (@relist) {
		push @out, $w =~ /\b($_->[1])/;
	}
	return @out;
}

# write out the new bad words list
sub put
{
	my @out;
	my $newfn = localdata("badword.new");
	my $fh = new IO::File ">$newfn";
	if ($fh) {
		dbg("BadWords: put new badword.new file");
		@relist = sort {$a->[0] cmp $b->[0]} @relist;
		for (@relist) {
			print $fh "$_->[0]\n";
		}
		$fh->close;
	}
	else {
		my $l = "BadWords: can't open $newfn $!";
		dbg($l);
		push @out, $l;
		return @out;
	}
}
1;
