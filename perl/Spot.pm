#
# the dx spot handler
#
# Copyright (c) - 1998 Dirk Koopman G1TLH
#
#
#

package Spot;

use IO::File;
use DXVars;
use DXDebug;
use DXUtil;
use DXLog;
use Julian;
use Prefix;
use DXDupe;
use Data::Dumper;
use QSL;
use DXSql;
use Time::HiRes qw(gettimeofday tv_interval);


use strict;

use vars qw($fp $statp $maxspots $defaultspots $maxdays $dirprefix $duplth $dupage $filterdef
			$totalspots $hfspots $vhfspots $maxcalllth $can_encode $use_db_for_search);

$fp = undef;
$statp = undef;
$maxspots = 100;					# maximum spots to return
$defaultspots = 10;				# normal number of spots to return
$maxdays = 100;				# normal maximum no of days to go back
$dirprefix = "spots";
$duplth = 20;					# the length of text to use in the deduping
$dupage = 1*3600;               # the length of time to hold spot dups
$maxcalllth = 12;                               # the max length of call to take into account for dupes
$filterdef = bless ([
					 # tag, sort, field, priv, special parser 
					 ['freq', 'r', 0, 0, \&decodefreq],
					 ['on', 'r', 0, 0, \&decodefreq],
					 ['call', 'c', 1],
					 ['info', 't', 3],
					 ['spotter', 'c', 4],
					 ['by', 'c', 4],
					 ['dxcc', 'nc', 5],
					 ['call_dxcc', 'nc', 5],
					 ['by_dxcc', 'nc', 6],
					 ['origin', 'c', 7, 9],
					 ['call_itu', 'ni', 8],
					 ['itu', 'ni', 8],
					 ['call_zone', 'nz', 9],
					 ['cq', 'nz', 9],
					 ['zone', 'nz', 9],
					 ['by_itu', 'ni', 10],
					 ['byitu', 'ni', 10],
					 ['by_zone', 'nz', 11],
					 ['byzone', 'nz', 11],
					 ['bycq', 'nz', 11],
					 ['call_state', 'ns', 12],
					 ['state', 'ns', 12],
					 ['by_state', 'ns', 13],
					 ['bystate', 'ns', 13],
					 ['ip', 'c', 14],
#					 ['channel', 'c', 15],
#					 ['rbn', 'a', 4, 0, \&filterrbnspot],
					], 'Filter::Cmd');
$totalspots = $hfspots = $vhfspots = 0;
$use_db_for_search = 0;

our %spotcache;					# the cache of data within the last $spotcachedays 0 or 2+ days
our $spotcachedays = 2;			# default 2 days worth
our $minselfspotqrg = 1240000;	# minimum freq above which self spotting is allowed

our $readback = 1;

if ($readback) {
	$readback = `which tac`;
	chomp $readback;
}

# create a Spot Object
sub new
{
	my $class = shift;
	my $self = [ @_ ];
	return bless $self, $class;
}

sub decodefreq
{
	my $dxchan = shift;
	my $l = shift;
	my @f = split /,/, $l;
	my @out;
	my $f;
	
	foreach $f (@f) {
		my ($a, $b); 
		if ($f =~ m{^\d+/\d+$}) {
			push @out, $f;
		} elsif (($a, $b) = $f =~ m{^(\w+)(?:/(\w+))?$}) {
			$b = lc $b if $b;
			my @fr = Bands::get_freq(lc $a, $b);
			if (@fr) {
				while (@fr) {
					$a = shift @fr;
					$b = shift @fr;
					push @out, "$a/$b";  # add them as ranges
				}
			} else {
				return ('dfreq', $dxchan->msg('dfreq1', $f));
			}
		} else {
			return ('dfreq', $dxchan->msg('e20', $f));
		}
	}
	return (0, join(',', @out));			 
}

# filter setup for rbn spot so return the regex to detect it
sub filterrbnspot
{
	my $dxchan = shift;
	return ('-#$');
}

sub init
{
	mkdir "$dirprefix", 0777 if !-e "$dirprefix";
	$fp = DXLog::new($dirprefix, "dat", 'd');
	$statp = DXLog::new($dirprefix, "dys", 'd');
	my $today = Julian::Day->new(time);

	# load up any old spots 
	if ($main::dbh) {
		unless (grep $_ eq 'spot', $main::dbh->show_tables) {
			dbg('initialising spot tables');
			my $t = time;
			my $total;
			$main::dbh->spot_create_table;
			
			my $now = Julian::Day->alloc(1995, 0);
			my $sth = $main::dbh->spot_insert_prepare;
			while ($now->cmp($today) <= 0) {
				my $fh = $fp->open($now);
				if ($fh) {
#					$main::dbh->{RaiseError} = 0;
					$main::dbh->begin_work;
					my $count = 0;
					while (<$fh>) {
						chomp;
						my @s = split /\^/;
						if (@s < 14) {
							my @a = (Prefix::cty_data($s[1]))[1..3];
							my @b = (Prefix::cty_data($s[4]))[1..3];
							push @s, $b[1] if @s < 7;
							push @s, '' if @s < 8;
							push @s, @a[0,1], @b[0,1] if @s < 12;
							push @s,  $a[2], $b[2] if @s < 14;
						} 
						$main::dbh->spot_insert(\@s, $sth);
						$count++;
					}
					$main::dbh->commit;
					dbg("inserted $count spots from $now->[0] $now->[1]");
					$fh->close;
					$total += $count;
				}
				$now = $now->add(1);
			}
			$main::dbh->begin_work;
			$main::dbh->spot_add_indexes;
			$main::dbh->commit;
#			$main::dbh->{RaiseError} = 1;
			$t = time - $t;
			my $min = int($t / 60);
			my $sec = $t % 60;
			dbg("$total spots converted in $min:$sec");
		}
		unless ($main::dbh->has_ipaddr) {
			$main::dbh->add_ipaddr;
			dbg("added ipaddr field to spot table");
		}
	}

	# initialise the cache if required
	if ($spotcachedays > 0) {
		my $t0 = [gettimeofday];
		$spotcachedays = 2 if $spotcachedays < 2;
		dbg "Spot::init - reading in $spotcachedays days of spots into cache"; 
		for (my $i = 0; $i < $spotcachedays; ++$i) {
			my $now = $today->sub($i);
			my $fh = $fp->open($now);
			if ($fh) {
				my @in;
				my $rec;
				for ($rec = 0; <$fh>; ++$rec) {
					chomp;
					my @s = split /\^/;
					if (@s < 14) {
						my @a = (Prefix::cty_data($s[1]))[1..3];
						my @b = (Prefix::cty_data($s[4]))[1..3];
						push @s, $b[1] if @s < 7;
						push @s, '' if @s < 8;
						push @s, @a[0,1], @b[0,1] if @s < 12;
						push @s,  $a[2], $b[2] if @s < 14;
					}
					unshift @in, \@s; 
				}
				$fh->close;
				dbg("Spot::init read $rec spots from " . _cachek($now));
				$spotcache{_cachek($now)} = \@in;
			}
			$now->add(1);
		}
		dbg("Spot::init $spotcachedays files of spots read into cache in " . _diffms($t0) . "mS")
	}
}

sub prefix
{
	return $fp->{prefix};
}

# fix up the full spot data from the basic spot data
# input is
# freq, call, time, comment, spotter, origin[, ip_address]
sub prepare
{
	# $freq, $call, $t, $comment, $spotter, node, ip address = @_
	my @out = @_[0..4];      # just up to the spotter

	# normalise frequency
	$out[0] = sprintf "%.1f", $out[0];
  
	# remove ssids and /xxx if present on spotter
	$out[4] =~ s/-\d+$//o;

	# remove leading and trailing spaces from comment field
	$out[3] = unpad($out[3]);
	
	# add the 'dxcc' country on the end for both spotted and spotter, then the cluster call
	my @spd = Prefix::cty_data($out[1]);
	push @out, $spd[0];
	my @spt = Prefix::cty_data($out[4]);
	push @out, $spt[0];
	push @out, $_[5];
	push @out, @spd[1,2], @spt[1,2], $spd[3], $spt[3];
	push @out, $_[6] if $_[6] && is_ipaddr($_[6]);

	# thus we now have:
	# freq, call, time, comment, spotter, call country code, spotter country code, origin, call itu, call cqzone, spotter itu, spotter cqzone, call state, spotter state, spotter ip address
	return @out;
}

sub add
{
	my $buf = join('^', @_);
	$fp->writeunix($_[2], $buf);
	if ($spotcachedays > 0) {
		my $now = Julian::Day->new($_[2]);
		my $day = _cachek($now);
		my $r = (exists $spotcache{$day}) ? $spotcache{$day} : ($spotcache{$day} = []);
		unshift @$r, \@_;
	}
	if ($main::dbh) {
		$main::dbh->begin_work;
		$main::dbh->spot_insert(\@_);
		$main::dbh->commit;
	}
	$totalspots++;
	if ($_[0] <= 30000) {
		$hfspots++;
	} else {
		$vhfspots++;
	}
	if ($_[3] =~ /(?:QSL|VIA)/i) {
		my $q = QSL::get($_[1]) || new QSL $_[1];
		$q->update($_[3], $_[2], $_[4]);
	}
}

# search the spot database for records based on the field no and an expression
# this returns a set of references to the spots
#
# the expression is a legal perl 'if' statement with the possible fields indicated
# by $f<n> where :-
#
#   $f0 = frequency
#   $f1 = call
#   $f2 = date in unix format
#   $f3 = comment
#   $f4 = spotter
#   $f5 = spotted dxcc country
#   $f6 = spotter dxcc country
#   $f7 = origin
#   $f8 = spotted itu
#   $f9 = spotted cq zone
#   $f10 = spotter itu
#   $f11 = spotter cq zone
#   $f12 = spotted us state
#   $f13 = spotter us state
#   $f14 = ip address
#
# In addition you can specify a range of days, this means that it will start searching
# from <n> days less than today to <m> days less than today
#
# Also you can select a range of entries so normally you would get the 0th (latest) entry
# back to the 5th latest, you can specify a range from the <x>th to the <y>the oldest.
#
# This routine is designed to be called as Spot::search(..)
#

sub search
{
	my ($expr, $dayfrom, $dayto, $from, $to, $hint, $dofilter, $dxchan) = @_;
	my @out;
	my $ref;
	my $i;
	my $count;
	my $today = Julian::Day->new(time());
	my $fromdate;
	my $todate;

	$dayfrom = 0 if !$dayfrom;
	$dayto = $maxdays unless $dayto;
	$dayto = $dayfrom + $maxdays if $dayto < $dayfrom;
	$fromdate = $today->sub($dayfrom);
	$todate = $fromdate->sub($dayto);
	$from = 0 unless $from;
	$to = $defaultspots unless $to;
	$hint = $hint ? "next unless $hint" : "";
	$expr = "1" unless $expr;
	
	$to = $from + $maxspots if $to - $from > $maxspots || $to - $from <= 0;

	if ($main::dbh && $use_db_for_search) {
		return $main::dbh->spot_search($expr, $dayfrom, $dayto, $from, $to, $hint, $dofilter, $dxchan);
	}

	#	$expr =~ s/\$f(\d\d?)/\$ref->[$1]/g; # swap the letter n for the correct field name
	#  $expr =~ s/\$f(\d)/\$spots[$1]/g;               # swap the letter n for the correct field name
  

	dbg("Spot::search hint='$hint', expr='$expr', spotno=$from-$to, day=$dayfrom-$dayto\n") if isdbg('search');
  
	# build up eval to execute
	dbg("Spot::search Spot eval: $expr") if isdbg('searcheval');
	$expr =~ s/\$r/\$_[0]/g;
	my $eval = qq{ sub { return $expr; } };
	dbg("Spot::search Spot eval: $eval") if isdbg('searcheval');
	my $ecode = eval $eval;
	return ("Spot search error", $@) if $@;
	
	
	my $fh;
	my $now = $fromdate;
	my $today = Julian::Day->new($main::systime);
	
	for ($i = $count = 0; $count < $to && $i < $maxdays; ++$i) { # look thru $maxdays worth of files only
		last if $now->cmp($todate) <= 0;


		my $this = $now->sub($i);
		my $fn = $fp->fn($this);
		my $cachekey = _cachek($this); 
		my $rec = 0;

		if ($spotcachedays > 0 && $spotcache{$cachekey}) {
			foreach my $r (@{$spotcache{$cachekey}}) {
				++$rec;
				if ($dofilter && $dxchan && $dxchan->{spotsfilter}) {
					my ($gotone, undef) = $dxchan->{spotsfilter}->it(@$r);
					next unless $gotone;
				}
				if (&$ecode($r)) {
					++$count;
					next if $count < $from;
					push @out, $r;
					last if $count >= $to;
				}
			}
			dbg("Spot::search cache recs read: $rec") if isdbg('search');
		} else {
			if ($readback) {
				dbg("Spot::search search using tac fn: $fn $i") if isdbg('search');
				$fh = IO::File->new("$readback $fn |");
			}
			else {
				dbg("Spot::search search fn: $fp->{fn} $i") if isdbg('search');
				$fh = $fp->open($now->sub($i));	# get the next file
			}
			if ($fh) {
				my $in;
				while (<$fh>) {
					chomp;
					my @r = split /\^/;
					++$rec;
					if ($dofilter && $dxchan && $dxchan->{spotsfilter}) {
						my ($gotone, undef) = $dxchan->{spotsfilter}->it(@r);
						next unless $gotone;
					}
					if (&$ecode(\@r)) {
						++$count;
						next if $count < $from;
						if ($readback) {
							push @out, \@r;
							last if $count >= $to;
						} else {
							push @out, \@r;
							shift @out if $count >= $to;
						}
					}
				}
				dbg("Spot::search file recs read: $rec") if isdbg('search');
				last if $count >= $to; # stop after to
			}
		}
	}
	return ("Spot search error", $@) if $@;

	@out = sort {$b->[2] <=> $a->[2]} @out if @out;
	return @out;
}

# change a freq range->regular expression
sub ftor
{
	my ($a, $b) = @_;
	return undef unless $a < $b;
	$b--;
	my $d = $b - $a;
	my @a = split //, $a;
	my @b = split //, $b;
	my $out;
	while (@b > @a) {
		$out .= shift @b;
	}
	while (@b) {
		my $aa = shift @a;
		my $bb = shift @b;
		if (@b < (length $d)) {
			$out .= '\\d';
		} elsif ($aa eq $bb) {
			$out .= $aa;
		} elsif ($aa < $bb) {
			$out .= "[$aa-$bb]";
		} else {
			$out .= "[0-$bb$aa-9]";
		}
	}
	return $out;
}

# format a spot for user output in list mode
sub formatl
{
	my $t = ztime($_[3]);
	my $d = cldate($_[3]);
	my $spotter = "<$_[5]>";
	my $comment = $_[4] || '';
	$comment =~ s/\t+/ /g;
	my $cl = length $comment;
	my $s = sprintf "%9.1f %-11s %s %s", $_[1], $_[2], $d, $t;
	my $width = ($_[0] ? $_[0] : 80) - length($spotter) - length($s) - 4;
	
	$comment = substr $comment, 0, $width if $cl > $width;
	$comment .= ' ' x ($width-$cl) if $cl < $width;

#	return sprintf "%8.1f  %-11s %s %s  %-28.28s%7s>", $_[0], $_[1], $d, $t, ($_[3]||''), "<$_[4]" ;
	return "$s $comment$spotter";
}

# enter the spot for dup checking and return true if it is already a dup
sub dup
{
	my ($freq, $call, $d, $text, $by, $node) = @_; 

	# dump if too old
	return 2 if $d < $main::systime - $dupage;
	
	# turn the time into minutes (should be already but...)
	$d = int ($d / 60);
	$d *= 60;

	# remove SSID or area
	$by =~ s|[-/]\d+$||;
	
#	$freq = sprintf "%.1f", $freq;       # normalise frequency
	$freq = int $freq;       # normalise frequency
	$call = substr($call, 0, $maxcalllth) if length $call > $maxcalllth;

	chomp $text;
	$text =~ s/\%([0-9A-F][0-9A-F])/chr(hex($1))/eg;
	$text = uc unpad($text);
	my $otext = $text;
#	$text = Encode::encode("iso-8859-1", $text) if $main::can_encode && Encode::is_utf8($text, 1);
	$text =~ s/^\+\w+\s*//;			# remove leading LoTW callsign
	$text =~ s/\s{2,}[\dA-Z]?[A-Z]\d?$// if length $text > 24;
	$text =~ s/[\W\x00-\x2F\x7B-\xFF]//g; # tautology, just to make quite sure!
	$text = substr($text, 0, $duplth) if length $text > $duplth; 
	my $ldupkey = "X$|$call|$by|$node|$freq|$d|$text";
	my $t = DXDupe::find($ldupkey);
	return 1 if $t && $t - $main::systime > 0;
	
	DXDupe::add($ldupkey, $main::systime+$dupage);
	$otext = substr($otext, 0, $duplth) if length $otext > $duplth; 
	$otext =~ s/\s+$//;
	if (length $otext && $otext ne $text) {
		$ldupkey = "X$freq|$call|$by|$otext";
		$t = DXDupe::find($ldupkey);
		return 1 if $t && $t - $main::systime > 0;
		DXDupe::add($ldupkey, $main::systime+$dupage);
	}
	return undef;
}

sub listdups
{
	return DXDupe::listdups('X', $dupage, @_);
}

sub genstats($)
{
	my $date = shift;
	my $in = $fp->open($date);
	my $out = $statp->open($date, 'w');
	my @freq;
	my %list;
	my @tot;
	
	if ($in && $out) {
		my $i = 0;
		@freq = map {[$i++, Bands::get_freq($_)]} qw(136khz 160m 80m 60m 40m 30m 20m 17m 15m 12m 10m 6m 4m 2m 220 70cm 23cm 13cm 9cm 6cm 3cm 12mm 6mm);
		while (<$in>) {
			chomp;
			my ($freq, $by, $dxcc) = (split /\^/)[0,4,6];
			my $ref = $list{$by} || [0, $dxcc];
			for (@freq) {
				next unless defined $_;
				if ($freq >= $_->[1] && $freq <= $_->[2]) {
					$$ref[$_->[0]+2]++;
					$tot[$_->[0]+2]++;
					$$ref[0]++;
					$tot[0]++;
					$list{$by} = $ref;
					last;
				}
			}
		}

		for ($i = 0; $i < @freq+2; $i++) {
			$tot[$i] ||= 0;
		}
		$statp->write($date, join('^', 'TOTALS', @tot));

		for (sort {$list{$b}->[0] <=> $list{$a}->[0]} keys %list) {
			my $ref = $list{$_};
			my $call = $_;
			for ($i = 0; $i < @freq+2; ++$i) {
				$ref->[$i] ||= 0;
			}
			$statp->write($date, join('^', $call, @$ref));
		}
		$statp->close;
	}
}

# return true if the stat file is newer than than the spot file
sub checkstats($)
{
	my $date = shift;
	my $in = $fp->mtime($date);
	my $out = $statp->mtime($date);
	return defined $out && defined $in && $out >= $in;
}

# daily processing
sub daily
{
	my $date = Julian::Day->new($main::systime)->sub(1);
	genstats($date) unless checkstats($date);
	clean_cache();
}

sub _cachek
{
	return "$_[0]->[0]|$_[0]->[1]";
}

sub clean_cache
{
	if ($spotcachedays > 0) {
		my $now = Julian::Day->new($main::systime);
		for (my $i = $spotcachedays; $i < $spotcachedays + 5; ++$i ) {
			my $k = _cachek($now->sub($i));
			if (exists $spotcache{$k}) {
				dbg("Spot::spotcache deleting day $k, more than $spotcachedays days old");
				delete $spotcache{$k};
			}
		}
	}
}
1;




