#
# IP Address block list / checker
#
# This is a DXSpider compatible, optional skin over Net::CIDR::Lite
# If Net::CIDR::Lite is not present, then a find will always returns 0
#

package DXCIDR;

use strict;
use warnings;
use 5.16.1;
use DXVars;
use DXDebug;
use DXUtil;
use DXLog;
use IO::File;
use File::Copy;

use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);

our $active = 0;
our $badipfn = "badip";
my $ipv4;
my $ipv6;
my $count4 = 0;
my $count6 = 0;

sub _fn
{
	return localdata($badipfn);
}

sub _read
{
	my $suffix = shift;
	my $fn = _fn();
	$fn .= ".$suffix" if $suffix;
	my $fh = IO::File->new($fn);
	my @out;

	if ($fh) {
		while (<$fh>) {
			chomp;
			next if /^\s*\#/;
			next unless /[\.:]/;
			push @out, $_;
		}
		$fh->close;
	} else {
		LogDbg('err', "DXCIDR: $fn read error ($!)");
	}
	return @out;
}

sub _load
{
	my $suffix = shift;
	my @in = _read($suffix);
	return scalar add(@in);
}

sub _put
{
	my $suffix = shift;
	my $fn = _fn() . ".$suffix";
	my $r = rand;
	my $fh = IO::File->new (">$fn.$r");
	my $count = 0;
	if ($fh) {
		for ($ipv4->list, $ipv6->list) {
			$fh->print("$_\n");
			++$count;
		}
		move "$fn.$r", $fn;
		LogDbg('cmd', "DXCIDR: put (re-)written $fn");
	} else {
		LogDbg('err', "DXCIDR: cannot write $fn.$r $!");
	}
	return $count;
}

sub append
{
	return 0 unless $active;
	
	my $suffix = shift;
	my @in = @_;
	my @out;
	
	if ($suffix) {
		my $fn = _fn() . ".$suffix";
		my $fh = IO::File->new;
		if ($fh->open("$fn", "a+")) {
			$fh->seek(0, 2);  	# belt and braces !!
			print $fh "$_\n" for @in;
			$fh->close;
		} else {
			LogDbg('err', "DXCIDR::append error appending to $fn $!");
		}
	} else {
		LogDbg('err', "DXCIDR::append require badip suffix");
	}
	return scalar @in;
}

sub add
{
	return 0 unless $active;
	my $count = 0;
	
	for my $ip (@_) {
		# protect against stupid or malicious
		next if $ip =~ /^127\./;
		next if $ip =~ /^::1$/;
		if ($ip =~ /\./) {
			$ipv4->add_any($ip);
			++$count;
			++$count4;
		} elsif ($ip =~ /:/) {
			$ipv6->add_any($ip);
			++$count;
			++$count6;
		} else {
			LogDbg('err', "DXCIDR::add non-ip address '$ip' read");
		}
	}
	return $count;
}

sub clean_prep
{
	return unless $active;

	if ($ipv4 && $count4) {
		$ipv4->clean;
		$ipv4->prep_find;
	}
	if ($ipv6 && $count6) {
		$ipv6->clean;
		$ipv6->prep_find;
	}
}

sub _sort
{
	my @in;
	my @out;
	for (@_) {
		push @in, [inet_pton(m|:|?AF_INET6:AF_INET, $_), split m|/|];
	}
	@out = sort {$a->[0] <=> $b->[0]} @in;
	return map { "$_->[1]/$_->[2]"} @out;
}

sub list
{
	return () unless $active;
	my @out;
	push @out, $ipv4->list if $count4;
	push @out, $ipv6->list if $count6;
	return _sort(@out);
}

sub find
{
	return 0 unless $active;
	return 0 unless $_[0];

	if ($_[0] =~ /\./) {
		return $ipv4->find($_[0]) if $count4;
	}
	return $ipv6->find($_[0]) if $count6;
}

sub init
{
	eval { require Net::CIDR::Lite };
	if ($@) {
		LogDbg('DXProt', "DXCIDR: load (cpanm) the perl module Net::CIDR::Lite to check for bad IP addresses (or CIDR ranges)");
		return;
	}

	import Net::CIDR::Lite;
	$active = 1;

	my $fn = _fn();
	if (-e $fn) {
		move $fn, "$fn.base";
	}

	_touch("$fn.local");
	
	reload();

}

sub _touch
{
	my $fn = shift;
	my $now = time;
	local (*TMP);
	utime ($now, $now, $fn) || open (TMP, ">>$fn") || LogDbg('err', "DXCIDR::touch: Couldn't touch $fn: $!");
}

sub reload
{
	return 0 unless $active;

	new();

	my $count = 0;
	my $files = 0;

	LogDbg('DXProt', "DXCIDR::reload reload database" );

	my $dir;
	opendir($dir, $main::local_data);
	while (my $fn = readdir $dir) {
		next unless my ($suffix) = $fn =~ /^badip\.(\w+)$/;
		my $c = _load($suffix);
		LogDbg('DXProt', "DXCIDR::reload: $fn read containing $c ip addresses" );
		$count += $c;
		$files++;
	}
	closedir $dir;
	
	LogDbg('DXProt', "DXCIDR::reload $count ip addresses found (IPV4: $count4 IPV6: $count6) in $files badip files" );

	return $count;
}

sub new
{
	return 0 unless $active;

	$ipv4 = Net::CIDR::Lite->new;
	$ipv6 = Net::CIDR::Lite->new;
	$count4 = $count6 = 0; 
}

1;
