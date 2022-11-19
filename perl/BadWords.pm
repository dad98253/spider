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
use DXHash;
use DXDebug;

use IO::File;

use vars qw($badword $regexcode);

our $regex;

# load the badwords file
sub load
{
	my $bwfn = localdata("badword");
	filecopy("$main::data.issue", $bwfn) unless -e $bwfn;
	
	my @out;

	$badword = new DXHash "badword";
	
	push @out, create_regex(); 
	return @out;
}

sub create_regex
{
	$regex = localdata("badw_regex");
	filecopy("$regex.gb.issue", $regex) unless -e $regex;
	
	my @out;
	my $fh = new IO::File $regex;
	
	if ($fh) {
		my $s = "sub { my \$str = shift; my \@out; \n";
		while (<$fh>) {
			chomp;
			next if /^\s*\#/;
			my @list = split " ";
			for (@list) {
				# create a closure for each word so that it matches stuff with spaces/punctuation
				# and repeated characters in it
				my $w = uc $_;
				my @l = split //, $w;
				my $e = join '+[\s\W]*', @l;
				$s .= qq{push \@out, \$1 if \$str =~ m|\\b($e+)|;\n};
			}
		}
		$s .= "return \@out;\n}";
		$regexcode = eval $s;
		dbg($s) if isdbg('badword');
		if ($@) {
			@out = ($@);
			dbg($@);
			return @out;
		}
		$fh->close;
	} else {
		my $l = "can't open $regex $!";
		dbg($l);
		push @out, $l;
	}
	
	return @out;
}

# check the text against the badwords list
sub check
{
	my $s = uc shift;
	my @out;

	push @out, &$regexcode($s) if $regexcode;
	
	return @out if @out;
	
	for (split(/\b/, $s)) {
		push @out, $_ if $badword->in($_);
	}

	return @out;
}

1;
