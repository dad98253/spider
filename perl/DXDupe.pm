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
localdata_mv("dupefile");
$fn = localdata("dupefile");

sub init
{
	unlink $fn;
	$dbm = tie (%d, 'DB_File', $fn);
	confess "cannot open $fn $!" unless $dbm;
}

sub finish
{
	dbg("DXDupe finishing");
	undef $dbm;
	untie %d;
	undef %d;
	unlink $fn;
}

sub check
{
	my $s = shift;
	return 1 if find($s);
	add($s, shift);
	return 0;
}

sub find
{
	return 0 unless $_[0];
	return $d{$_[0]};
}

sub add
{
	my $s = shift;
	my $t = shift || $main::systime + $default;
	return unless $s;

	$d{$s} = $t;
	dbg("DXDupe::add key: $s time: " . ztime($t)) if isdbg('dxdupe');
}

sub del
{
	my $s = shift;
	return unless $s;
	
	my $t = $d{$s};
	dbg("DXDupe::del key: $s time: " . ztime($t)) if isdbg('dxdupe');
	delete $d{$s};
}

sub process
{
	# once an hour
	if ($main::systime - $lasttime >=  3600) {
		my @del;
		while (($k, $v) = each %d) {
			push @del, $k  if $main::systime >= $v;
		}
		del($k) for @del;
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
	$regex = ".*$regex" if $regex;
	$regex = "^$let" . $regex;
	my @out;
	for (sort { $d{$a} <=> $d{$b} } grep { m{$regex}i } keys %d) {
		my ($dum, $key) = unpack "a1a*", $_;
		push @out, "$key = " . cldatetime($d{$_} - $dupage) . " expires " . cldatetime($d{$_});
	}
	return @out;
}

sub END
{
	if ($dbm) {
		dbg("DXDupe ENDing");
		finish();
	}
}
1;
