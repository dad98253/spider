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
		$count4 = _load($ipv4, 4);
		$count6 = _load($ipv6, 6);
	}
	LogDbg('DXProt', "DXCIDR: loaded $count4 IPV4 addresses and $count6 IPV6 addresses");
	return $count4 + $count6;
}

sub _fn
{
	return localdata($badipfn) . ".$_[0]";
}

sub _load
{
	my $list = shift;
	my $sort = shift;
	my $fn = _fn($sort);
	my $fh = IO::File->new($fn);
	my $count = 0;
	
	if ($fh) {
		while (<$fh>) {
			chomp;
			next if /^\s*\#/;
			next unless /[\.:]/;
			$list->add_any($_);
			++$count;
		}
		$fh->close;
		$list->clean if $count;
		$list->prep_find;
	} elsif (-r $fn) {
		LogDbg('err', "DXCIDR: $fn not found ($!)");
	}
	return $count;
}

sub _put
{
	my $list = shift;
	my $sort = shift;
	my $fn = _fn($sort);
	my $r = rand;
	my $fh = IO::File->new (">$fn.$r");
	if ($fh) {
		for ($list->list) {
			$fh->print("$_\n");
		}
		move "$fn.$r", $fn;
	} else {
		LogDbg('err', "DXCIDR: cannot write $fn.$r $!");
	}
}

sub add
{
	my $count = 0;
	
	for my $ip (@_) {
		# protect against stupid or malicious
		next if /^127\./;
		next if /^::1$/;
		if (/\./) {
			if ($ipv4->find($ip)) {
				LogDbg('DXProt', "DXCIDR: Ignoring existing IPV4 $ip");
				next;
			} 
			$ipv4->add_any($ip);
			++$count;
			++$count4;
		} elsif (/:/) {
			if ($ipv6->find($ip)) {
				LogDbg('DXProt', "DXCIDR: Ignoring existing IPV6 $ip");
				next;
			} 
			$ipv6->add_any($ip);
			++$count;
			++$count6;
			LogDbg('DXProt', "DXCIDR: Added IPV6 $ip address");
		}
	}
	if ($ipv4 && $count4) {
		$ipv4->prep_find;
		_put($ipv4, 4);
	}
	if ($ipv6 && $count6) {
		$ipv6->prep_find;
		_put($ipv6, 6);
	}
	return $count;
}

sub save
{
	return 0 unless $active;
	_put($ipv4, 4) if $count4;
	_put($ipv6, 6) if $count6;
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

	$ipv4 = Net::CIDR::Lite->new;
	$ipv6 = Net::CIDR::Lite->new;

	$active = 1;
	load();
}



1;
