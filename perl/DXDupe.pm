#
# class to handle all dupes in the system
#
# each dupe entry goes into a tied hash file 
#
# the only thing this class really does is provide a
# mechanism for storing and checking dups
#

package DXDupe;

use DXDebug;
use DXUtil;
use DXVars;

use vars qw{$lasttime $dbm %d $default $fn};

$default = 48*24*60*60;
$lasttime = 0;
$fn = "$main::data/dupefile";

sub init
{
	$dbm = tie (%d, 'DB_File', $fn) or confess "can't open dupe file: $fn ($!)";
}

sub finish
{
	undef $dbm;
	untie %d;
}

sub check
{
	my ($s, $t) = @_;
	return 1 if exists $d{$s};
	$t = $main::systime + $default unless $t;
	$d{$s} = $t;
	return 0;
}

sub del
{
	my $s = shift;
	delete $d{$s};
}

sub process
{
	# once an hour
	if ($main::systime - $lasttime >=  3600) {
		while (($k, $v) = each %d) {
			delete $d{$k} if $main::systime >= $v;
		}
		$lasttime = $main::systime;
	}
}

sub get
{
	my $start = shift;
	my @out;
	while (($k, $v) = each %d) {
		push @out, $k, $v if !$start || $k =~ /^$start/; 
	}
	return @out;
}

sub listdups
{
	my $let = shift;
	my $dupage = shift;
	my $regex = shift;

	$regex =~ s/[\^\$\@\%]//g;
	$regex = "^$let" . $regex;
	my @out;
	for (sort { $d{$a} <=> $d{$b} } grep { m{$regex}i } keys %d) {
		my ($dum, $key) = unpack "a1a*", $_;
		push @out, "$key = " . cldatetime($d{$_} - $dupage);
	}
	return @out;
}
1;
