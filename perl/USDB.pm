#
# Package to handle US Callsign -> City, State translations
#
# Copyright (c) 2002 Dirk Koopman G1TLH
#
# 

use strict;

use DXVars;
use DB_File;
use File::Copy;
use DXDebug;
use Compress::Zlib;

use vars qw($VERSION $BRANCH);
$VERSION = sprintf( "%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/ );
$BRANCH = sprintf( "%d.%03d", q$Revision$ =~ /\d+\.\d+\.(\d+)\.(\d+)/  || (0,0));
$main::build += $VERSION;
$main::branch += $BRANCH;

use vars qw(%db $present);

my $dbfn = "$main::data/usdb.v1";

sub init
{
	end();
	tie %db, 'DB_File', $dbfn and $present = 1;
}

sub end
{
	return unless $present;
	untie %db;
	undef $present;
}

sub get
{
	return () unless $present;
	my $ctyn = $db{$_[0]};
	my @s = split /\|/, $db{$ctyn} if $ctyn;
	return @s;
}

sub getstate
{
	return () unless $present;
	my @s = get($_[0]);
	return @s ? $s[1] : undef;
}

sub getcity
{
	return () unless $present;
	my @s = get($_[0]);
	return @s ? $s[0] : undef;
}

#
# load in / update an existing DB with a standard format (GZIPPED)
# "raw" file.
#
# Note that this removes and overwrites the existing DB file
# You will need to init again after doing this
#

sub load
{
	# create the new output file
	my $a = new DB_File::BTREEINFO;
	$a->{psize} = 4096 * 2;
	my $s;
	if ($s = -s $dbfn && $s > 1024 * 1024) {
		$a->{cachesize} = int(($s / (1024*1024)) / 2) * 1024 * 1024;
	}
	my %dbn;
	if (-e $dbfn ) {
		syscopy($dbfn, "$dbfn.new") or return "cannot copy $dbfn -> $dbfn.new $!";
	}
	
	tie %dbn, 'DB_File', "$dbfn.new", O_RDWR|O_CREAT, 0664, $a or return "cannot tie $dbfn.new $!";
	
	# now write away all the files
	for (@_) {
		my $fn = shift;
		my $f = gzopen($fn, "r") or return "Cannot open $fn $!";
		while ($f->gzreadline) {
			chomp;
			my ($call, $city, $state) = split /\|/;
			
			# lookup the city 
			my $s = "$city|$state";
			my $ctyn = $dbn{$s};
			unless ($ctyn) {
				my $no = $dbn{'##'} || 1;
				$ctyn = "#$no";
				$dbn{$s} = $ctyn;
				$dbn{$ctyn} = $s; 
				$no++;
				$dbn{'##'} = "$no";
			}
			$dbn{$call} = $ctyn; 
		}
		$f->gzclose;
	}
	
	untie %dbn;
	rename "$dbfn.new", $dbfn;
}

1;
