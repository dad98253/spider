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

# load the badip file
sub load
{
	if ($active) {
		_load();
	}
	LogDbg('DXProt', "DXCIDR: loaded $count4 IPV4 addresses and $count6 IPV6 addresses");
	return $count4 + $count6;
}

sub _fn
{
	return localdata($badipfn);
}

sub _load
{
	my $fn = _fn();
	my $fh = IO::File->new($fn);
	my $count = 0;

	new();
	
	if ($fh) {
		while (<$fh>) {
			chomp;
			next if /^\s*\#/;
			next unless /[\.:]/;
			add($_);
			++$count;
		}
		$fh->close;
	} elsif (-r $fn) {
		LogDbg('err', "DXCIDR: $fn not found ($!)");
	}

	clean_prep();
	
	return $count;
}

sub _put
{
	my $fn = _fn();
	my $r = rand;
	my $fh = IO::File->new (">$fn.$r");
	my $count = 0;
	if ($fh) {
		for ($ipv4->list, $ipv6->list) {
			$fh->print("$_\n");
			++$count;
		}
		move "$fn.$r", $fn;
	} else {
		LogDbg('err', "DXCIDR: cannot write $fn.$r $!");
	}
	return $count;
}

sub add
{
	my $count = 0;
	
	for my $ip (@_) {
		# protect against stupid or malicious
		next if /^127\./;
		next if /^::1$/;
		if (/\./) {
			$ipv4->add_any($ip);
			++$count;
			++$count4;
		} elsif (/:/) {
			$ipv6->add_any($ip);
			++$count;
			++$count6;
			LogDbg('DXProt', "DXCIDR: Added IPV6 $ip address");
		}
	}
	return $count;
}

sub clean_prep
{
	if ($ipv4 && $count4) {
		$ipv4->clean;
		$ipv4->prep_find;
	}
	if ($ipv6 && $count6) {
		$ipv6->clean;
		$ipv6->prep_find;
	}
}

sub save
{
	return 0 unless $active;
	_put() if $count4 || $count6;
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

	new();

	load();
}

sub new
{
	$ipv4 = Net::CIDR::Lite->new;
	$ipv6 = Net::CIDR::Lite->new;
	$count4 = $count6 = 0; 
}

1;
