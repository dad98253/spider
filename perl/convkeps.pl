#!/usr/bin/perl -w
#
# Convert an Amsat 2 line keps bull into Sun.pm format
#
# This program will accept on stdin a standard AMSAT 2 line keps
# bull such as you would find in an email or from the packet network
#
# It will write a file called /spider/local/Keps.pm, this means that
# the latest version will be read in every time you restart the 
# cluster.pl. You can also call Sun::load from a cron line if
# you like to re-read it automatically. If you update it manually
# load/keps will load the latest version into the cluster
#
# This program is designed to be called from /etc/aliases or
# a .forward file so you can get yourself on the keps mailing
# list from AMSAT and have the keps updated automatically once
# a week.
#
# I will distribute the latest keps with every patch but you can
# get your own data from: 
#
# http://www.amsat.org/amsat/ftp/keps/current/nasa.all
#
# Please note that this will UPDATE your keps file
# 
# Usage: 
#    email | convkeps.pl        (in amsat email format)  
#    convkeps.pl -p keps.in     (a file with just plain keps)
# 
# Copyright (c) 2000 Dirk Koopman G1TLH
#
# $Id$
#

require 5.004;
package Sun;

# search local then perl directories
BEGIN {
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
	
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
}

use strict;
use vars qw($root %keps);

use Data::Dumper;
use Keps;

my $fn = "$root/local/Keps.pm";
my $state = 0;
my $name;
my $ref;
my $line;
my $f = \*STDIN;

while (@ARGV) {
	my $arg = shift @ARGV;
	if ($arg eq '-p') {
		$state = 1;
	} elsif ($arg eq '-e') {
		$state = 0;
	} elsif ($arg =~ /^-/) {
		die "Usage: convkeps.pl [-e|-p] [<filename>]\n\t-p - plain file just containing keps\n\t-e - amsat email format input file (default)\n";
	} else {
		open (IN, $arg) or die "cannot open $arg (!$)";
		$f = \*IN;
	}
}
while (<$f>) {
	++$line;
	chomp;
	s/^\s+//;
    s/\s+$//;
	next unless $_;
	last if m{^/EX}i;
	last if m{^-};
	
	if ($state == 0 && /^TO ALL/) {
		$state = 1;
	} elsif ($state == 1) {
		last if m{^/EX/i};
		
		if (/^\w+/) {
			s/\s/-/g;
			$name = $_;
			$ref = $keps{$name} = {}; 
			$state = 2;
		}
	} elsif ($state == 2) {
		if (/^1 /) {
			my ($id, $number, $epoch, $decay, $mm2, $bstar, $elset) = unpack "xxa5xxa5xxxa15xa10xa8xa8xxxa4x", $_;
			$ref->{id} = $id - 0;
			$ref->{number} = $number - 0;
			$ref->{epoch} = $epoch - 0;
			$ref->{mm1} = $decay - 0;
			$ref->{mm2} = genenum($mm2);
			$ref->{bstar} = genenum($bstar);
			$ref->{elset} = $elset - 0;
#			print "$id $number $epoch $decay $mm2 $bstar $elset\n"; 
#			print "mm2: $ref->{mm2} bstar: $ref->{bstar}\n";
			
			$state = 3;
		} else {
			print "out of order on line $line\n";
			undef $ref;
			delete $keps{$name};
			$state = 1;
		}
	} elsif ($state == 3) {
		if (/^2 /) {
			my ($id, $incl, $raan, $ecc, $peri, $man, $mmo, $orbit) = unpack "xxa5xa8xa8xa7xa8xa8xa11a5x", $_;
			$ref->{meananomaly} = $man - 0;
			$ref->{meanmotion} = $mmo - 0;
			$ref->{inclination} = $incl - 0;
			$ref->{eccentricity} = ".$ecc" - 0;
			$ref->{argperigee} = $peri - 0;
			$ref->{raan} = $raan - 0;
			$ref->{orbit} = $orbit - 0;
		} else {
			print "out of order on line $line\n";
			delete $keps{$name};
		}
		undef $ref;
		$state = 1;
	}
}

my $dd = new Data::Dumper([\%keps], [qw(*keps)]);
$dd->Indent(1);
$dd->Quotekeys(0);
open(OUT, ">$fn") or die "$fn $!";
print OUT "#\n# this file is automatically produced by convkeps.pl\n#\n";
print OUT "# Last update: ", scalar gmtime, "\n#\n";
print OUT "\npackage Sun;\n\n";
print OUT $dd->Dumpxs;
print OUT "\n";
close(OUT);


# convert (+/-)00000-0 to (+/-).00000e-0
sub genenum
{
	my ($sign, $frac, $esign, $exp) = unpack "aa5aa", shift;
	my $n = $sign . "." . $frac . 'e' . $esign . $exp;
	return $n - 0;
}

