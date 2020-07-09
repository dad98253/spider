#
# The RBN connection system
#
# Copyright (c) 2020 Dirk Koopman G1TLH
#

use warnings;
use strict;

package RBN;

use 5.10.1;

use DXDebug;
use DXUtil;
use DXLog;
use DXUser;
use DXChannel;
use Math::Round qw(nearest);
use Date::Parse;
use Time::HiRes qw(clock_gettime CLOCK_REALTIME);
use Spot;
use JSON;
use IO::File;

our @ISA = qw(DXChannel);

our $startup_delay = 5*60;		# don't send anything out until this timer has expired
                                # this is to allow the feed to "warm up" with duplicates
                                # so that the "big rush" doesn't happen.

our $minspottime = 60*60;		# the time between respots of a callsign - if a call is
                                # still being spotted (on the same freq) and it has been
                                # spotted before, it's spotted again after this time
                                # until the next minspottime has passed.

our $beacontime = 5*60;			# same as minspottime, but for beacons (and shorter)

our $dwelltime = 10; 			# the amount of time to wait for duplicates before issuing
                                # a spot to the user (no doubt waiting with bated breath).

our $filterdef = $Spot::filterdef; # we use the same filter as the Spot system. Can't think why :-).

my $spots;						# the GLOBAL spot cache

my %runtime;					# how long each channel has been running

our $cachefn = localdata('rbn_cache');
our $cache_valid = 4*60;		# The cache file is considered valid if it is not more than this old

my $json;
my $noinrush = 0;				# override the inrushpreventor if set

sub init
{
	$json = JSON->new;
	$spots = {};
	if (check_cache()) {
		$noinrush = 1;
	}
	if (defined $DB::VERSION) {
		$noinrush = 1;
		$json->indent(1);
	}
}

sub new 
{
	my $self = DXChannel::alloc(@_);

	# routing, this must go out here to prevent race condx
	my $pkg = shift;
	my $call = shift;

	$self->{last} = 0;
	$self->{noraw} = 0;
	$self->{nospot} = 0;
	$self->{nouser} = {};
	$self->{norbn} = 0;
	$self->{noraw10} = 0;
	$self->{nospot10} = 0;
	$self->{nouser10} = {};
	$self->{norbn10} = 0;
	$self->{nospothour} = 0;
	$self->{nouserhour} = {};
	$self->{norbnhour} = 0;
	$self->{norawhour} = 0;
	$self->{sort} = 'N';
	$self->{lasttime} = $main::systime;
	$self->{minspottime} = $minspottime;
	$self->{beacontime} = $beacontime;
	$self->{showstats} = 0;
	$self->{pingint} = 0;
	$self->{nopings} = 0;

	return $self;
}

sub start
{ 
	my ($self, $line, $sort) = @_;
	my $user = $self->{user};
	my $call = $self->{call};
	my $name = $user->{name};
		
	# log it
	my $host = $self->{conn}->peerhost;
	$host ||= "unknown";
	$self->{hostname} = $host;

	$self->{name} = $name ? $name : $call;
	$self->state('prompt');		# a bit of room for further expansion, passwords etc
	$self->{lang} = $user->lang || $main::lang || 'en';
	if ($line =~ /host=/) {
		my ($h) = $line =~ /host=(\d+\.\d+\.\d+\.\d+)/;
		$line =~ s/\s*host=\d+\.\d+\.\d+\.\d+// if $h;
		unless ($h) {
			($h) = $line =~ /host=([\da..fA..F:]+)/;
			$line =~ s/\s*host=[\da..fA..F:]+// if $h;
		}
		if ($h) {
			$h =~ s/^::ffff://;
			$self->{hostname} = $h;
		}
	}
	$self->{width} = 80 unless $self->{width} && $self->{width} > 80;
	$self->{consort} = $line;	# save the connection type

	LogDbg('DXCommand', "$call connected from $self->{hostname}");

	# set some necessary flags on the user if they are connecting
	$self->{registered} = 1;
	# sort out privilege reduction
	$self->{priv} = 0;

	# get the filters
	my $nossid = $call;
	$nossid =~ s/-\d+$//;

	$self->{inrbnfilter} = Filter::read_in('rbn', $call, 1) 
		|| Filter::read_in('rbn', 'node_default', 1);
	
	# clean up qra locators
	my $qra = $user->qra;
	$qra = undef if ($qra && !DXBearing::is_qra($qra));
	unless ($qra) {
		my $lat = $user->lat;
		my $long = $user->long;
		$user->qra(DXBearing::lltoqra($lat, $long)) if (defined $lat && defined $long);  
	}

	# if we have been running and stopped for a while 
	# if the cache is warm enough don't operate the inrush preventor
	$self->{inrushpreventor} = exists $runtime{$call} && $runtime{$call} > $startup_delay || $noinrush ?  0 : $main::systime + $startup_delay;
	dbg("RBN: noinrush: $noinrush, setting inrushpreventor on $self->{call} to $self->{inrushpreventor}");
}

my @queue;						# the queue of spots ready to send

sub normal
{
	my $self = shift;
	my $line = shift;
	my @ans;
#	my $spots = $self->{spot};
	
	# save this for them's that need it
	my $rawline = $line;
	
	# remove leading and trailing spaces
	chomp $line;
	$line =~ s/^\s*//;
	$line =~ s/\s*$//;

	# add base RBN

	my $tim = $main::systime;

	# parse line
	dbg "RBN:RAW,$line" if isdbg('rbnraw');
	return unless $line=~/^DX\s+de/;

	my (undef, undef, $origin, $qrg, $call, $mode, $s, $m, $spd, $u, $sort, $t, $tx) = split /[:\s]+/, $line;

	# fix up FT8 spots from 7001
	$t = $u, $u = '' if !$t && is_ztime($u);
	$t = $sort, $sort = '' if !$t && is_ztime($sort);
	my $qra = $spd, $spd = '' if is_qra($spd);
	$u = $qra if $qra;

	# is this anything like a callsign?
	unless (is_callsign($call)) {
		dbg("RBN: ERROR $call from $origin on $qrg is invalid, dumped");
		return;
	}

	$origin =~ s/\-(?:\d{1,2}\-)?\#$//; # get rid of all the crap we aren't interested in


	$sort ||= '';
	$tx ||= '';
	$qra ||= '';
    dbg qq{RBN:input decode or:$origin qr:$qrg ca:$call mo:$mode s:$s m:$m sp:$spd u:$u sort:$sort t:$t tx:$tx qra:$qra} if isdbg('rbn');

	++$self->{noraw};
	++$self->{noraw10};
	++$self->{norawhour};
	
	my $b;
	
	if ($t || $tx) {

		# fix up times for things like 'NXDXF B' etc
		if ($tx && is_ztime($t)) {
			if (is_ztime($tx)) {
				$b = $t;
				$t = $tx;
			} else {
				dbg "RBN:ERR,$line";
				return (0);
			}
		}
		if ($sort && $sort eq 'NCDXF') {
			$mode = 'DXF';
			$t = $tx;
		}
		if ($sort && $sort eq 'BEACON') {
			$mode = 'BCN';
		}
		if ($mode =~ /^PSK/) {
			$mode = 'PSK';
		}
		if ($mode eq 'RTTY') {
			$mode = 'RTT';
		}

		# The main de-duping key is [call, $frequency], but we probe a bit around that frequency to find a
		# range of concurrent frequencies that might be in play. 

		# The key to this is deducing the true callsign by "majority voting" (the greater the number of spotters
        # the more effective this is) together with some lexical analsys probably in conjuction with DXSpider
		# data sources (for singleton spots) to then generate a "centre" from and to zone (whatever that will mean if it isn't the usual one)
		# and some heuristical "Kwalitee" rating given distance from the zone centres of spotter, recipient user
        # and spotted. A map can be generated once per user and spotter as they are essentially mostly static. 
		# The spotted will only get a coarse position unless other info is available. Programs that parse 
		# DX bulletins and the online data online databases could be be used and then cached. 

		# Obviously users have to opt in to receiving RBN spots and other users will simply be passed over and
		# ignored.

		# Clearly this will only work in the 'mojo' branch of DXSpider where it is possible to pass off external
		# data requests to ephemeral or semi resident forked processes that do any grunt work and the main
		# process to just the standard "message passing" which has been shown to be able to sustain over 5000 
		# per second (limited by the test program's output and network speed, rather than DXSpider's handling).

		my $nqrg = nearest(1, $qrg);  # normalised to nearest Khz
		my $sp = "$call|$nqrg";		  # hopefully the skimmers will be calibrated at least this well!
		my $spp = sprintf("$call|%d", $nqrg+1); # but, clearly, my hopes are rudely dashed
		my $spm = sprintf("$call|%d", $nqrg-1); # in BOTH directions!

		# do we have it?
		my $spot = $spots->{$sp};
		$spot = $spots->{$spp}, $sp = $spp, dbg(qq{RBN: SPP using $spp for $sp}) if isdbg('rbn') && !$spot && exists $spots->{$spp};
		$spot = $spots->{$spm}, $sp = $spm, dbg(qq{RBN: SPM using $spm for $sp}) if isdbg('rbn') && !$spot && exists $spots->{$spm};
		

		# if we have one and there is only one slot and that slot's time isn't expired for respot then return
		my $respot = 0;
		if ($spot && ref $spot) {
			if (@$spot == 1) {
				unless ($self->{minspottime} > 0 && $tim - $spot->[0] >= $self->{minspottime}) {
					dbg("RBN: key: '$sp' call: $call qrg: $qrg DUPE \@ ". atime(int $spot->[0])) if isdbg('rbn');
					return;
				}
				
				dbg("RBN: key: '$sp' RESPOTTING call: $call qrg: $qrg last seen \@ ". atime(int $spot->[0])) if isdbg('rbn');
				undef $spot;	# it's about to be recreated (in one place)
				++$respot;
			}

			# otherwise we have a spot being built up at the moment
		} elsif ($spot) {
			dbg("RBN: key '$sp' = '$spot' not ref");
			return;
		}

		# here we either have an existing spot record buildup on the go, or we need to create the first one
		unless ($spot) {
			$spots->{$sp} = $spot = [clock_gettime(CLOCK_REALTIME)];;
			dbg("RBN: key: '$sp' call: $call qrg: $qrg NEW" . ($respot ? ' RESPOT' : '')) if isdbg('rbn');
		}

		# add me to the display queue unless we are waiting for initial in rush to finish
		return unless $noinrush || $self->{inrushpreventor} < $main::systime;

		# build up a new record and store it in the buildup
		# deal with the unix time
		my ($hh,$mm) = $t =~ /(\d\d)(\d\d)Z$/;
		my $utz = $hh*3600 + $mm*60 + $main::systime_daystart; # possible issue with late spot from previous day
		$utz -= 86400 if $utz > $tim+3600;					   # too far ahead, drag it back one day

		# create record and add into the buildup
		my $r = [$origin, nearest(.1, $qrg), $call, $mode, $s, $t, $utz, $respot, $u];
		my @s =  Spot::prepare($r->[1], $r->[2], $r->[6], '', $r->[0]);
		if ($s[5] == 666) {
			dbg("RBN: ERROR invalid prefix/callsign $call from $origin-# on $qrg, dumped");
			return;
		}
		
		if ($self->{inrbnfilter}) {
			my ($want, undef) = $self->{inrbnfilter}->it($s);
			return unless $want;	
		}
		$r->[9] = \@s;

		push @{$self->{queue}}, $sp if @$spot == 1; # queue the KEY (not the record)

		dbg("RBN: key: '$sp' ADD RECORD call: $call qrg: $qrg origin: $origin") if isdbg('rbn');

		push @$spot, $r;

		# At this point we run the queue to see if anything can be sent onwards to the punter
		my $now = clock_gettime(CLOCK_REALTIME);

		# now run the waiting queue which just contains KEYS ($call|$qrg)
		foreach $sp (@{$self->{queue}}) {
			my $cand = $spots->{$sp};
			unless ($cand && $cand->[0]) {
				dbg "RBN Cand " . ($cand ? 'def' : 'undef') . " [0] " . ($cand->[0] ? 'def' : 'undef') . " dwell $dwelltime";
				next;
			} 
			if ($now >= $cand->[0] + $dwelltime ) {
				# we have a candidate, create qualitee value(s);
				unless (@$cand > 1) {
					dbg "RBN: QUEUE key '$sp' MISSING RECORDS " . dd($cand) if isdbg 'rbn';
					shift @{$self->{queue}};
					next;
				}
				my $savedtime = shift @$cand; # save the start time
				my $r = $cand->[0];
				my $quality = @$cand;
				$quality = 9 if $quality > 9;
				$quality = "Q:$quality";
				if (isdbg('progress')) {
					my $s = "RBN: SPOT key: '$sp' = $r->[2] on $r->[1] by $r->[0] \@ $r->[5] $quality";
					$s .=  " route: $self->{call}";
					dbg($s);
				}
				
				send_dx_spot($self, $quality, $cand);
				
				# clear out the data and make this now just "spotted", but no further action required until respot time
				dbg "RBN: QUEUE key '$sp' cleared" if isdbg 'rbn';
				
				$spots->{$sp} = [$savedtime];
				shift @{$self->{queue}};
			} else {
				dbg sprintf("RBN: QUEUE key: '$sp' SEND time not yet reached %.1f secs left", $spot->[0] + $dwelltime - $now) if isdbg 'rbnqueue'; 
			}
		}
	} else {
		dbg "RBN:DATA,$line" if isdbg('rbn');
	}
}

sub per_minute
{
	foreach my $dxchan (DXChannel::get_all()) {
		next unless $dxchan->is_rbn;
		dbg "RBN:STATS minute $dxchan->{call} raw: $dxchan->{noraw} sent: $dxchan->{norbn} delivered: $dxchan->{nospot} users: " . scalar keys %{$dxchan->{nousers}} if isdbg('rbnstats');
		if ($dxchan->{noraw} == 0 && $dxchan->{lasttime} > 60) {
			LogDbg('RBN', "RBN: no input from $dxchan->{call}, disconnecting");
			$dxchan->disconnect;
		}
		$dxchan->{noraw} = $dxchan->{norbn} = $dxchan->{nospot} = 0; $dxchan->{nousers} = {};
		$runtime{$dxchan->{call}} += 60;
	}

	# save the spot cache
	write_cache() unless $main::systime + $startup_delay < $main::systime;;
}

sub per_10_minute
{
	my $count = 0;
	my $removed = 0;
	while (my ($k,$v) = each %{$spots}) {
		if ($main::systime - $v->[0] > $minspottime*2) {
			delete $spots->{$k};
			++$removed;
		}
		else {
			++$count;
		}
	}
	dbg "RBN:STATS spot cache remain: $count removed: $removed"; # if isdbg('rbn');
	foreach my $dxchan (DXChannel::get_all()) {
		next unless $dxchan->is_rbn;
		dbg "RBN:STATS 10-minute $dxchan->{call} raw: $dxchan->{noraw10} sent: $dxchan->{norbn10} delivered: $dxchan->{nospot10} users: " . scalar keys %{$dxchan->{nousers10}};
		$dxchan->{noraw10} = $dxchan->{norbn10} = $dxchan->{nospot10} = 0; $dxchan->{nousers10} = {};
	}
}

sub per_hour
{
	foreach my $dxchan (DXChannel::get_all()) {
		next unless $dxchan->is_rbn;
		dbg "RBN:STATS hour $dxchan->{call} raw: $dxchan->{norawhour} sent: $dxchan->{norbnhour} delivered: $dxchan->{nospothour} users: " . scalar keys %{$dxchan->{nousershour}};
		$dxchan->{norawhour} = $dxchan->{norbnhour} = $dxchan->{nospothour} = 0; $dxchan->{nousershour} = {};
	}
}

# we should get the spot record minus the time, so just an array of record (arrays)
sub send_dx_spot
{
	my $self = shift;
	my $quality = shift;
	my $spot = shift;

	++$self->{norbn};
	++$self->{norbn10};
	++$self->{norbnhour};
	
	# $r = [$origin, $qrg, $call, $mode, $s, $utz, $respot];

	my $mode = $spot->[0]->[3]; # as all the modes will be the same;
	
	my @dxchan = DXChannel::get_all();

	foreach my $dxchan (@dxchan) {
		next unless $dxchan->is_user;
		my $user = $dxchan->{user};
		next unless $user &&  $user->wantrbn;

		# does this user want this sort of spot at all?
		my $want = 0;
		++$want if $user->wantbeacon && $mode =~ /^BCN|DXF/;
		++$want if $user->wantcw && $mode =~ /^CW/;
		++$want if $user->wantrtty && $mode =~ /^RTT/;
		++$want if $user->wantpsk && $mode =~ /^PSK|FSK|MSK/;
		++$want if $user->wantft && $mode =~ /^FT/;

		dbg(sprintf("RBN: spot selection for $dxchan->{call} mode: '$mode' want: $want flags rbn:%d ft:%d bcn:%d cw:%d psk:%d rtty:%d",
					$user->wantrbn,
					$user->wantft,
					$user->wantbeacon,
					$user->wantcw,
					$user->wantpsk,
					$user->wantrtty,
				   )) if isdbg('rbnll');

		# send one spot to one user out of the ones that we have
		$self->dx_spot($dxchan, $quality, $spot) if $want;
	}
}

sub dx_spot
{
	my $self = shift;
	my $dxchan = shift;
	my $quality = shift;
	my $spot = shift;
	my $call = $dxchan->{call};
	

	my $strength = 100;		# because it could if we talk about FTx
	my $saver;

	my %zone;
	my %qrg;
	my $respot;
	my $qra;

	++$self->{nousers}->{$call};
	++$self->{nousers10}->{$call};
	++$self->{nousershour}->{$call};
	
	foreach my $r (@$spot) {
		# $r = [$origin, $qrg, $call, $mode, $s, $t, $utz, $respot, $qra];
		# Spot::prepare($qrg, $call, $utz, $comment, $origin);

		my $comment = sprintf "%-3s %2ddB $quality", $r->[3], $r->[4];
		$respot = 1 if $r->[7];
		$qra = $r->[8] if !$qra && $r->[8] && is_qra($r->[8]);

		my $s = $r->[9];		# the prepared spot
		$s->[3] = $comment;		# apply new generated comment
		
		
		++$zone{$s->[11]};		# save the spotter's zone
		++$qrg{$s->[0]};		# and the qrg

 
		my $want = 0;
		my $rf = $dxchan->{rbnfilter} || $dxchan->{spotsfilter};
		if ($rf) {
			($want, undef) = $rf->it($s);
			next unless $want;
			$saver = $s;
			dbg("RBN: FILTERED call: $s->[1] qrg: $s->[0] origin: $s->[4] dB: $r->[4]") if isdbg 'rbn';
			last;
		}

		# save the lowest strength one
		if ($r->[4] < $strength) {
			$strength = $r->[4];
			$saver = $s;
			dbg("RBN: STRENGTH call: $s->[1] qrg: $s->[0] origin: $s->[4] dB: $r->[4]") if isdbg 'rbn';
		}
	}

	if ($saver) {
		my $buf;
		# create a zone list of spotters
		delete $zone{$saver->[11]};  # remove this spotter's zone (leaving all the other zones)
		my $z = join ',', sort {$a <=> $b} keys %zone;

		# determine the most likely qrg and then set it
		my $mv = 0;
		my $fk;
		my $c = 0;
		while (my ($k, $v) = each %qrg) {
			$fk = $k, $mv = $v if $v > $mv;
			++$c;
		}
		$saver->[0] = $fk;
		$saver->[3] .= '*' if $c > 1;
		$saver->[3] .= '+' if $respot;
		$saver->[3] .= " Z:$z" if $z;
		
		dbg("RBN: SENDING call: $saver->[1] qrg: $saver->[0] origin: $saver->[4] $saver->[3]") if isdbg 'rbn';
		if ($dxchan->{ve7cc}) {
			my $call = $saver->[4];
			$saver->[4] .= '-#';
			$buf = VE7CC::dx_spot($dxchan, @$saver);
			$saver->[4] = $call;
		} else {
			my $call = $saver->[4];
			$saver->[4] = substr($call, 0, 6);
			$saver->[4] .= '-#';
			$buf = $dxchan->format_dx_spot(@$saver);
			$saver->[4] = $call;
		}
#		$buf =~ s/^DX/RB/;
		$dxchan->local_send('N', $buf);

		++$self->{nospot};
		++$self->{nospot10};
		++$self->{nospothour};
		
		if ($qra) {
			my $user = DXUser::get_current($saver->[1]) || DXUser->new($saver->[1]);
			unless ($user->qra && is_qra($user->qra)) {
				$user->qra($qra);
				dbg("RBN: update qra on $saver->[1] to $qra");
				$user->put;
			}
		}
	}
}

sub finish
{
	write_cache();
}

sub write_cache
{
	my $fh = IO::File->new(">$cachefn") or confess("writing $cachefn $!");
	my $s = $json->encode($spots);
	$fh->print($s);
	$fh->close;
}

sub check_cache
{
	if (-e $cachefn) {
		my $mt = (stat($cachefn))[9];
		my $t = $main::systime - $mt || 1;
		my $p = difft($mt);
		if ($t < $cache_valid) {
			dbg("RBN:check_cache '$cachefn' spot cache exists, created $p ago and not too old");
			my $fh = IO::File->new($cachefn);
			my $s;
			if ($fh) {
				local $/ = undef;
				$s = <$fh>;
				dbg("RBN:check_cache cache read size " . length $s);
				$fh->close;
			} else {
				dbg("RBN:check_cache file read error $!");
				return undef;
			}
			if ($s) {
				eval {$spots = $json->decode($s)};
				if ($spots && ref $spots) {
					dbg("RBN:check_cache spot cache restored");
					return 1;
				}
			}
			dbg("RBN::checkcache error decoding $@");
		} else {
			my $d = difft($main::systime-$cache_valid);
			dbg("RBN::checkcache '$cachefn' created $p ago is too old (> $d), ignored");
		}
	} else {
		dbg("RBN:check_cache '$cachefn' spot cache not present");
	}
	
	return undef;
}

1;
