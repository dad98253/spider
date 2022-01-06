#
#
# This module impliments the handlers for the protocal mode for a dx cluster
#
# Copyright (c) 1998-2007 Dirk Koopman G1TLH
#
#
#

package DXProt;

@ISA = qw(DXChannel);

use DXUtil;
use DXChannel;
use DXUser;
use DXM;
use DXProtVars;
use DXCommandmode;
use DXLog;
use Spot;
use DXProtout;
use DXDebug;
use Filter;
use Local;
use DXDb;
use AnnTalk;
use Geomag;
use WCY;
use BadWords;
use DXHash;
use Route;
use Route::Node;
use Script;

use strict;
use warnings qw(all);

use vars qw($pc11_max_age $pc23_max_age $last_pc50 $eph_restime $eph_info_restime $eph_pc34_restime
			$last_hour $last10 %eph  %pings %rcmds $ann_to_talk
			$pingint $obscount %pc19list $chatdupeage $chatimportfn
			$investigation_int $pc19_version $myprot_version
			%nodehops $baddx $badspotter $badnode $censorpc
			$allowzero $decode_dk0wcy $send_opernam @checklist
			$eph_pc15_restime $pc9x_past_age $pc9x_dupe_age
			$pc10_dupe_age $pc92_slug_changes $last_pc92_slug
			$pc92Ain $pc92Cin $pc92Din $pc92Kin $pc9x_time_tolerance
			$pc92filterdef $senderverify
		   );

$pc9x_dupe_age = 60;			# catch loops of circular (usually) D records
$pc10_dupe_age = 45;			# just something to catch duplicate PC10->PC93 conversions
$pc92_slug_changes = 60*1;		# slug any changes going outward for this long
$last_pc92_slug = 0;			# the last time we sent out any delayed add or del PC92s
$pc9x_time_tolerance = 15*60;	# the time on a pc9x is allowed to be out by this amount
$pc9x_past_age = (122*60)+		# maximum age in the past of a px9x (a config record might be the only
$pc9x_time_tolerance;           # thing a node might send - once an hour and we allow an extra hour for luck)
                                # this is actually the partition between "yesterday" and "today" but old.
$senderverify = 0;				# 1 - check for forged PC11 or PC61.
                                # 2 - if forged, dump them.


$pc92filterdef = bless ([
			  # tag, sort, field, priv, special parser
			  ['call', 'c', 0],
			  ['by', 'c', 0],
			  ['dxcc', 'nc', 1],
			  ['itu', 'ni', 2],
			  ['zone', 'nz', 3],
			 ], 'Filter::Cmd');

our %pc11q;
# this is a place to park an incoming PC11 in the sure and certain hope that
# a PC61 will be along soon. This has the side benefit that it will delay a
# a PC11 for one second - assuming that it is not removed by a PC61 version

# incoming talk commands
sub handle_10
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# this is to catch loops caused by bad software ...
	if (eph_dup($line, $pc10_dupe_age)) {
		return;
	}

	# will we allow it at all?
	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($pc->[3])) {
			dbg("PCPROT: Bad words: @bad, dropped") if isdbg('chanerr');
			return;
		}
	}

	# is it for me or one of mine?
	my ($from, $to, $via, $call, $dxchan);
	$from = $pc->[1];
	if ($pc->[5] gt ' ') {
		$via = $pc->[2];
		$to = $pc->[5];
	} else {
		$to = $pc->[2];
	}

	# if this is a 'nodx' node then ignore it
	if ($badnode->in($pc->[6]) || ($via && $badnode->in($via))) {
		dbg("PCPROT: Bad Node, dropped") if isdbg('chanerr');
		return;
	}

	# if this is a 'bad spotter' user then ignore it
	my $nossid = $from;
	$nossid =~ s/-\d+$//;
	if ($badspotter->in($nossid)) {
		dbg("PCPROT: Bad Spotter, dropped") if isdbg('chanerr');
		return;
	}

	# if we are converting announces to talk is it a dup?
	if ($ann_to_talk) {
		if (AnnTalk::is_talk_candidate($from, $pc->[3]) && AnnTalk::dup($from, $to, $pc->[3])) {
			dbg("PCPROT: Dupe talk from announce, dropped") if isdbg('chanerr');
			return;
		}
	}

	# convert this to a PC93, coming from mycall with origin set and process it as such
	$main::me->normal(pc93($to, $from, $via, $pc->[3], $pc->[6]));
}

my $last;
my $pc11_saved;
my $pc11_saved_time;

# DX Spot handling
sub handle_11
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;
	my $recurse = shift || 0;

	# route 'foreign' pc26s
	if ($pcno == 26) {
		if ($pc->[7] ne $main::mycall) {
			$self->route($pc->[7], $line);
			return;
		}
	}

	dbg("INPUT PC$pcno $line origin $origin recurse: $recurse") if isdbg("pc11"); 

#	my ($hops) = $pc->[8] =~ /^H(\d+)/;

	# is the spotted callsign blank? This should really be trapped earlier but it
	# could break other protocol sentences. Also check for lower case characters.
	if ($pc->[2] =~ /^\s*$/) {
		dbg("PCPROT: blank callsign, dropped") if isdbg('chanerr');
		return;
	}
	if ($pc->[2] =~ /[a-z]/) {
		dbg("PCPROT: lowercase characters, dropped") if isdbg('chanerr');
		return;
	}


	# if this is a 'nodx' node then ignore it
	if ($badnode->in($pc->[7])) {
		dbg("PCPROT: Bad Node $pc->[7], dropped") if isdbg('chanerr');
		return;
	}

	# if this is a 'bad spotter' or an unknown user then ignore it. BUT if it's got an IP address then allow it through
	my $nossid = $pc->[6];
	$nossid =~ s/-\d+$//;
	if ($badspotter->in($nossid)) {
		dbg("PCPROT: Bad Spotter $pc->[6], dropped") if isdbg('chanerr');
		return;
	}

	# convert the date to a unix date
	my $d = cltounix($pc->[3], $pc->[4]);
	# bang out (and don't pass on) if date is invalid or the spot is too old (or too young)
	if (!$d || (($pcno == 11 || $pcno == 61) && ($d < $main::systime - $pc11_max_age || $d > $main::systime + 900))) {
		dbg("PCPROT: Spot ignored, invalid date or out of range ($pc->[3] $pc->[4])\n") if isdbg('chanerr');
		return;
	}

	# is it 'baddx'
	if ($baddx->in($pc->[2]) || BadWords::check($pc->[2])) {
		dbg("PCPROT: Bad DX spot, ignored") if isdbg('chanerr');
		return;
	}

	# do some de-duping
	$pc->[5] =~ s/^\s+//;			# take any leading blanks off
	$pc->[2] = unpad($pc->[2]);		# take off leading and trailing blanks from spotted callsign
	if ($pc->[2] =~ /BUST\w*$/) {
		dbg("PCPROT: useless 'BUSTED' spot") if isdbg('chanerr');
		return;
	}
	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($pc->[5])) {
			dbg("PCPROT: Bad words: @bad, dropped") if isdbg('chanerr');
			return;
		}
	}
	

	my @spot = Spot::prepare($pc->[1], $pc->[2], $d, $pc->[5], $nossid, $pc->[7], $pc->[8]);

	# global spot filtering on INPUT
	if ($self->{inspotsfilter}) {
		my ($filter, $hops) = $self->{inspotsfilter}->it(@spot);
		unless ($filter) {
			dbg("PCPROT: Rejected by input spot filter") if isdbg('chanerr');
			return;
		}
	}

	# this is where we decide to delay PC11s in the hope that a PC61 will be along soon.
	
	my $key = join '|', @spot[0..2,4,7]; # not including text
	unless ($recurse) {
		if ($pcno == 61) {
			if ($pc11_saved) {
				if ($key eq $pc11_saved->[0]) {
					dbg("saved PC11 spot $key dumped, better pc61 received") if isdbg("pc11");
					undef $pc11_saved;
				}
			} 
		}
		if ($pcno == 11) {
			if ($pc11_saved) {
				if ($key eq $pc11_saved->[0]) {
					dbg("saved PC11 spot $key, dupe pc11 received and dumped") if isdbg("pc11");
					return;		# because it's a dup
				}
			}

			# can we promote this to a PC61?
			my $r = Route::User::get($spot[4]); # find spotter
			if ($r && $r->ip) {	                # do we have an ip addres
				$pcno = 61;						# now turn this into a PC61
				$spot[14] = $r->ip;
				dbg("PC11 spot $key promoted to pc61 ip $spot[14]") if isdbg("pc11");
				undef $pc11_saved;
			}
		}

		if ($pc11_saved && $key ne $pc11_saved) {
			dbg("saved PC11 spot $pc11_saved->[0] ne new key $key, recursing") if isdbg("pc11");
			shift @$pc11_saved;	# saved key
			my $self = shift @$pc11_saved;
			my @saved = @$pc11_saved;
			undef $pc11_saved;
			$self->handle_11(@saved, 1);
		}

		# if we are still a PC11, save it for a better offer
		if ($pcno == 11) {
			$pc11_saved = [$key, $self, $pcno, $line, $origin, $pc];
			$pc11_saved_time = $main::systime;
			dbg("saved new PC11 spot $key for a better offer") if isdbg("pc11");
			return;
		} else {
			dbg("PC61 spot $key passed onward") if isdbg("pc11");
		}
	}

	
	# this goes after the input filtering, but before the add
	# so that if it is input filtered, it isn't added to the dup
	# list. This allows it to come in from a "legitimate" source
	if (Spot::dup(@spot[0..4,7])) {
		dbg("PCPROT: Duplicate Spot $pc->[0] $key ignored\n") if isdbg('chanerr') || isdbg('dupespot');
		return;
	}
	
	# here we verify the spotter is currently connected to the node it says it is one. AKA email sender verify
	# but without the explicit probe to the node. We are relying on "historical" information, but it very likely
	# to be current once we have seen the first PC92C from that node.
	#
	# As for spots generated from non-PC92 nodes, we'll see after about  do_pc9x3h20m...
	#
	if ($senderverify) {
		my $nroute = Route::Node::get($pc->[7]);
		my $uroute = Route::Node::get($pc->[6]);
		my $local = DXChannel::get($pc->[7]);
		
		if ($nroute && ($nroute->last_PC92C || ($local && !$local->do_pc9x))) {
			my $s = '';
			my $ip = $pcno == 61 ?  $pc->[8] : '';
#			$s .= "User $pc->[6] not logged in, " unless $uroute;
			$s .= "User $pc->[6] not on node $pc->[7], " unless $nroute->is_user($pc->[6]);
#			$s .= "Node $pc->[7] at '$ip' not on Node's IP " . $nroute->ip if $ip && $nroute && $nroute->ip && $nroute->ip ne $ip;
			if ($s) {
				my $action = $senderverify > 1 ? ", DUMPED" : '';
				$s =~ s/, $//;
				dbg("PCProt: Suspicious Spot $pc->[2] on $pc->[1] by $pc->[6]($ip)\@$pc->[7] $s$action");
				return unless $senderverify < 2;
			}
		}
	}

	# If is a new PC11, store it, releasing the one that is there (if any),
	# if a PC61 comes along then dump the stored PC11
	# If there is a different PC11 stored, release that one and store this PC11 instead,
	
	# add it
	Spot::add(@spot);

	my $ip = '';
	$ip ||= $spot[14] if exists $spot[14];
	if (isdbg('progress')) {
		my $sip = $ip ? sprintf "($ip)" : '' unless $ip =~ m|[\(\)\*]|;
		$sip ||= '';
		my $d = ztime($spot[2]);
		my $s = "SPOT: $spot[1] on $spot[0] \@ $d by $spot[4]$sip\@$spot[7]";
		$s .= $spot[3] ? " '$spot[3]'" : q{ ''};
		$s .=  " route: $origin";
		dbg($s);
	}
	
	#
	# @spot at this point contains:-
	# freq, spotted call, time, text, spotter, spotted cc, spotters cc, orig node
	# then  spotted itu, spotted cq, spotters itu, spotters cq
	# you should be able to route on any of these
	#

	# fix up qra locators of known users
	my $user = DXUser::get_current($spot[4]);
	if ($user) {
		my $qra = $user->qra;
		unless ($qra && is_qra($qra)) {
			my $lat = $user->lat;
			my $long = $user->long;
			if (defined $lat && defined $long) {
				$user->qra(DXBearing::lltoqra($lat, $long));
				$user->put;
			}
		}

		# send a remote command to a distant cluster if it is visible and there is no
		# qra locator and we havn't done it for a month.

		unless ($user->qra) {
			my $node;
			my $to = $user->homenode;
			my $last = $user->lastoper || 0;
			if ($send_opernam && $to && $to ne $main::mycall && $main::systime > $last + $DXUser::lastoperinterval && ($node = Route::Node::get($to)) ) {
				my $cmd = "forward/opernam $spot[4]";
				# send the rcmd but we aren't interested in the replies...
				my $dxchan = $node->dxchan;
				if ($dxchan && $dxchan->is_clx) {
					route(undef, $to, pc84($main::mycall, $to, $main::mycall, $cmd));
				} else {
					route(undef, $to, pc34($main::mycall, $to, $cmd));
				}
				if ($to ne $origin) {
					$to = $origin;
					$node = Route::Node::get($to);
					if ($node) {
						$dxchan = $node->dxchan;
						if ($dxchan && $dxchan->is_clx) {
							route(undef, $to, pc84($main::mycall, $to, $main::mycall, $cmd));
						} else {
							route(undef, $to, pc34($main::mycall, $to, $cmd));
						}
					}
				}
				$user->lastoper($main::systime);
				$user->put;
			}
		}
	}

	# local processing
	if (defined &Local::spot) {
		my $r;
		eval {
			$r = Local::spot($self, @spot);
		};
		return if $r;
	}

	# DON'T be silly and send on PC26s!
	return if $pcno == 26;

	# send out the filtered spots
	send_dx_spot($self, $line, @spot) if @spot;
}

# used to kick outstanding PC11 if required
sub pc11_process
{
	if ($pc11_saved && $main::systime > $pc11_saved_time) {
		dbg("saved PC11 spot $pc11_saved->[0] timed out waiting, recursing") if isdbg("pc11");
		shift @$pc11_saved;	# saved key
		my $self = shift @$pc11_saved;
		my @saved = @$pc11_saved;
		undef $pc11_saved;
		$self->handle_11(@saved, 1);
	}
}

# announces
sub handle_12
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# announce duplicate checking
	$pc->[3] =~ s/^\s+//;			# remove leading blanks

	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($pc->[3])) {
			dbg("PCPROT: Bad words: @bad, dropped") if isdbg('chanerr');
			return;
		}
	}

	# if this is a 'nodx' node then ignore it
	if ($badnode->in($pc->[5])) {
		dbg("PCPROT: Bad Node, dropped") if isdbg('chanerr');
		return;
	}

	# if this is a 'bad spotter' user then ignore it
	my $nossid = $pc->[1];
	$nossid =~ s/-\d+$//;
	if ($badspotter->in($nossid)) {
		dbg("PCPROT: Bad Spotter, dropped") if isdbg('chanerr');
		return;
	}

	# ignore PC12s from origins that use PCxx protocol
	my $oref = Route::get($origin);
	if ($oref->do_pc9x) {
		dbg("PCPROT: PC12 rxed from PC9x node, ignored") if isdbg('chanerr');
		return;
	}

	my $dxchan;

	if ((($dxchan = DXChannel::get($pc->[2])) && $dxchan->is_user) || $pc->[4] =~ /^[\#\w.]+$/){
		$self->send_chat(0, $line, @$pc[1..6]);
	} elsif ($pc->[2] eq '*' || $pc->[2] eq $main::mycall) {

		# ignore something that looks like a chat line coming in with sysop
		# flag - this is a kludge...
		if ($pc->[3] =~ /^\#\d+ / && $pc->[4] eq '*') {
			dbg('PCPROT: Probable chat rewrite, dropped') if isdbg('chanerr');
			return;
		}

		# here's a bit of fun, convert incoming ann with a callsign in the first word
		# or one saying 'to <call>' to a talk if we can route to the recipient
		if ($ann_to_talk) {
			my $call = AnnTalk::is_talk_candidate($pc->[1], $pc->[3]);
			if ($call) {
				my $ref = Route::get($call);
				if ($ref) {
					$dxchan = $ref->dxchan;
					$dxchan->talk($pc->[1], $call, undef, $pc->[3], $pc->[5]) if $dxchan != $self;
					return;
				}
			}
		}

		# send it
		$self->send_announce(0, $line, @$pc[1..6]);
	} else {
		$self->route($pc->[2], $line);
	}

	# local processing
	if (defined &Local::ann) {
		my $r;
		eval {
			$r = Local::ann($self, $line, @$pc[1..6]);
		};
		return if $r;
	}
}

sub handle_15
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if (eph_dup($line, $eph_pc15_restime)) {
		return;
	} else {
		unless ($self->{isolate}) {
			DXChannel::broadcast_nodes($line, $self) if $line =~ /\^H\d+\^?~?$/; # send it to everyone but me
		}
	}
}

# incoming user
sub handle_16
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# general checks
	my $dxchan;
	my $ncall = $pc->[1];
	my $newline = "PC16^";

	# dos I want users from this channel?
	unless ($self->user->wantpc16) {
		dbg("PCPROT: don't send users to $self->{call}") if isdbg('chanerr');
		return;
	}

	# is it me?
	if ($ncall eq $main::mycall) {
		dbg("PCPROT: trying to alter config on this node from outside!") if isdbg('chanerr');
		return;
	}

	my $h;
	$h = 1 if DXChannel::get($ncall);
	if ($h && $self->{call} ne $ncall) {
		dbg("PCPROT: trying to update a local node, ignored") if isdbg('chanerr');
		return;
	}

	if (eph_dup($line)) {
		return;
	}

	# isolate now means only accept stuff from this call only
	if ($self->{isolate} && $ncall ne $self->{call}) {
		dbg("PCPROT: $self->{call} isolated, $ncall ignored") if isdbg('chanerr');
		return;
	}

	my $parent = Route::Node::get($ncall);

	if ($parent) {
		$dxchan = $parent->dxchan;
		if ($dxchan && $dxchan ne $self) {
			dbg("PCPROT: PC16 from $self->{call} trying to alter locally connected $ncall, ignored!") if isdbg('chanerr');
			return;
		}

		# input filter if required
		return unless $self->in_filter_route($parent);
	} else {
		$parent = Route::Node->new($ncall);
	}

	unless ($h) {
		if ($parent->via_pc92) {
			dbg("PCPROT: non-local node controlled by PC92, ignored") if isdbg('chanerr');
			return;
		}
	}

	my $i;
	my @rout;
	for ($i = 2; $i < $#$pc; $i++) {
		my ($call, $conf, $here) = $pc->[$i] =~ /^(\S+) (\S) (\d)/o;
		next unless $call && $conf && defined $here && is_callsign($call);
		next if $call eq $main::mycall;

		eph_del_regex("^PC17\\^$call\\^$ncall");

		$conf = $conf eq '*';

		# reject this if we think it is a node already
		my $r = Route::Node::get($call);
		my $u = DXUser::get_current($call) unless $r;
		if ($r || ($u && $u->is_node)) {
			dbg("PCPROT: $call is a node") if isdbg('chanerr');
			next;
		}

		$r = Route::User::get($call);
		my $flags = Route::here($here)|Route::conf($conf);

		if ($r) {
			my $au = $r->addparent($parent);
			if ($r->flags != $flags) {
				$r->flags($flags);
				$au = $r;
			}
			push @rout, $r if $h && $au;
		} else {
			my @ans = $parent->add_user($call, $flags);
			push @rout, @ans if $h && @ans;
		}

		# add this station to the user database, if required
		my $user = DXUser::get_current($ncall);
		$user = DXUser->new($call) unless $user;
		$user->homenode($parent->call) if !$user->homenode;
		$user->node($parent->call);
		$user->lastin($main::systime) unless DXChannel::get($call);
		$user->put;

		# send info to all logged in thingies
		$self->tell_login('loginu', "$ncall: $call") if $user->is_local_node;
		$self->tell_buddies('loginb', $call, $ncall);
	}
	if (@rout) {
		$self->route_pc16($origin, $line, $parent, @rout) if @rout;
#		$self->route_pc92a($main::mycall, undef, $parent, @rout) if $h && $self->{state} eq 'normal';
	}
}

# remove a user
sub handle_17
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $dxchan;
	my $ncall = $pc->[2];
	my $ucall = $pc->[1];

	eph_del_regex("^PC16\\^$ncall.*$ucall");

	# do I want users from this channel?
	unless ($self->user->wantpc16) {
		dbg("PCPROT: don't send users to $self->{call}") if isdbg('chanerr');
		return;
	}

	if ($ncall eq $main::mycall) {
		dbg("PCPROT: trying to alter config on this node from outside!") if isdbg('chanerr');
		return;
	}

	# isolate now means only accept stuff from this call only
	if ($self->{isolate} && $ncall ne $self->{call}) {
		dbg("PCPROT: $self->{call} isolated, $ncall ignored") if isdbg('chanerr');
		return;
	}

	my $uref = Route::User::get($ucall);
	unless ($uref) {
		dbg("PCPROT: Route::User $ucall not in config") if isdbg('chanerr');
		return;
	}
	my $parent = Route::Node::get($ncall);
	unless ($parent) {
		dbg("PCPROT: Route::Node $ncall not in config") if isdbg('chanerr');
		return;
	}

	$dxchan = DXChannel::get($ncall);
	if ($dxchan && $dxchan ne $self) {
		dbg("PCPROT: PC17 from $self->{call} trying to alter locally connected $ncall, ignored!") if isdbg('chanerr');
		return;
	}

	unless ($dxchan) {
		if ($parent->via_pc92) {
			dbg("PCPROT: non-local node controlled by PC92, ignored") if isdbg('chanerr');
			return;
		}
	}

	if (DXChannel::get($ucall)) {
		dbg("PCPROT: trying do disconnect local user, ignored") if isdbg('chanerr');
		return;
	}

	# input filter if required and then remove user if present
#		return unless $self->in_filter_route($parent);
	$parent->del_user($uref);

	# send info to all logged in thingies
	my $user = DXUser::get_current($ncall);
	$self->tell_login('logoutu', "$ncall: $ucall") if $user && $user->is_local_node;
	$self->tell_buddies('logoutb', $ucall, $ncall);

	if (eph_dup($line)) {
		return;
	}

	$self->route_pc17($origin, $line, $parent, $uref);
#	$self->route_pc92d($main::mycall, undef, $parent, $uref) if $dxchan;
}

# link request
sub handle_18
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	$self->state('init');

	my $parent = Route::Node::get($self->{call});

	# record the type and version offered
	if (my ($version) = $pc->[1] =~ /DXSpider Version: (\d+\.\d+)/) {
		$self->{version} = 53 + $version;
		$self->user->version(53 + $version);
		$parent->version(0 + $version);
		my ($build) = $pc->[1] =~ /Build: (\d+(?:\.\d+)?)/;
		$self->{build} = 0 + $build;
		$self->user->build(0 + $build);
		$parent->build(0 + $build);
		dbg("$self->{call} = DXSpider version $version build $build");
		unless ($self->is_spider) {
			dbg("Change U " . $self->user->sort . " C $self->{sort} -> S");
			$self->user->sort('S');
			$self->user->put;
			$self->sort('S');
		}
#		$self->{handle_xml}++ if DXXml::available() && $pc->[1] =~ /\bxml/;
	} else {
		dbg("$self->{call} = Unknown software ($pc->[1] $pc->[2])");
		$self->version(50.0);
		$self->version($pc->[2] / 100) if $pc->[2] && $pc->[2] =~ /^\d+$/;
		$self->user->version($self->version);
	}

	if ($pc->[1] =~ /\bpc9x/) {
		if ($self->{isolate}) {
			dbg("$self->{call} pc9x recognised, but node is isolated, using old protocol");
		} elsif (!$self->user->wantpc9x) {
			dbg("$self->{call} pc9x explicitly switched off, using old protocol");
		} else {
			$self->{do_pc9x} = 1;
			dbg("$self->{call} Set do PC9x");
		}
	}

	# first clear out any nodes on this dxchannel
	my @rout = $parent->del_nodes;
	$self->route_pc21($origin, $line, @rout, $parent) if @rout;
	$self->send_local_config();
	$self->send(pc20());
}

sub check_add_user
{
	my $call = shift;
	my $type = shift;
	my $homenode = shift;

	# add this station to the user database, if required (don't remove SSID from nodes)
	my $user = DXUser::get_current($call);
	unless ($user) {
		$user = DXUser->new($call);
		$user->sort($type || 'U');
		if ($user->is_node) {
			$user->priv(1);		# I have relented and defaulted nodes
			$user->lockout(1) if $user->is_node;
		} else {
			$user->homenode($homenode) if $homenode;
			$user->node($homenode);
			$user->priv(0);
		}
		$user->lastin($main::systime); # this make it last longer than just this invocation
		$user->put;				# just to make sure it gets written away!!!
		dbg("DXProt: PC92 new user record for $call created");
	}

	# this is to fix a problem I introduced some build ago by using this function for users
	# whereas it was only being used for nodes.
	if ($user->is_user && $user->lockout && ($user->priv // 0) == 1) {
		$user->priv(0);
		$user->lockout(0);
		dbg("DXProt: PC92 user record for $call depriv'd and unlocked");
		$user->put;
	}
	return $user;
}

# incoming cluster list
sub handle_19
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $i;
	my $newline = "PC19^";

	# new routing list
	my (@rout, @pc92out);

	# first get the INTERFACE node
	my $parent = Route::Node::get($self->{call});
	unless ($parent) {
		dbg("PCPROT: my parent $self->{call} has disappeared");
		$self->disconnect;
		return;
	}

	my $h;

	# parse the PC19
	#
	# We are making a major change from now on. We are only going to accept
	# PC19s from directly connected nodes.  This means that we are probably
	# going to throw away most of the data that we are being sent.
	#
	# The justification for this is that most of it is wrong or out of date
	# anyway.
	#
	# From now on we are only going to believe PC92 data and locally connected
	# non-pc92 nodes.
	#
	for ($i = 1; $i < $#$pc-1; $i += 4) {
		my $here = $pc->[$i];
		my $call = uc $pc->[$i+1];
		my $conf = $pc->[$i+2];
		my $ver = $pc->[$i+3];
		next unless defined $here && defined $conf && is_callsign($call);

		eph_del_regex("^PC(?:21\\^$call|17\\^[^\\^]+\\^$call)");

		# check for sane parameters
		#				$ver = 5000 if $ver eq '0000';
		next unless $ver && $ver =~ /^\d+$/;
		next if $ver < 5000;	# only works with version 5 software
		next if length $call < 3; # min 3 letter callsigns
		next if $call eq $main::mycall || $call eq $main::myalias;

		# check that this PC19 isn't trying to alter the wrong dxchan
		$h = 0;
		my $dxchan = DXChannel::get($call);
		if ($dxchan) {
			if ($dxchan == $self) {
				$h = 1;
			} else {
				dbg("PCPROT: PC19 from $self->{call} trying to alter wrong locally connected $call, ignored!") if isdbg('chanerr');
				next;
			}
		}

		# isolate now means only accept stuff from this call only
		if ($self->{isolate} && $call ne $self->{call}) {
			dbg("PCPROT: $self->{call} isolated, $call ignored") if isdbg('chanerr');
			next;
		}

		my $user = check_add_user($call, 'A');

#		if (eph_dup($genline)) {
#			dbg("PCPROT: dup PC19 for $call detected") if isdbg('chanerr');
#			next;
#		}


		unless ($h) {
			if ($parent->via_pc92) {
				dbg("PCPROT: non-local node controlled by PC92, ignored") if isdbg('chanerr');
				next;
			}
		}

		my $r = Route::Node::get($call);
		my $flags = Route::here($here)|Route::conf($conf);

		# modify the routing table if it is in it, otherwise store it in the pc19list for now
		if ($r) {
			my $ar;
			if ($call ne $parent->call) {
				if ($self->in_filter_route($r)) {
					$ar = $parent->add($call, $ver, $flags);
#					push @rout, $ar if $ar;
				} else {
					next;
				}
			}
			if ($r->version ne $ver || $r->flags != $flags) {
				$r->version($ver);
				$r->flags($flags);
			}
			push @rout, $r;
		} else {
			if ($call eq $self->{call} || $user->wantroutepc19) {
				my $new = Route->new($call); # throw away
				if ($self->in_filter_route($new)) {
					my $ar = $parent->add($call, $ver, $flags);
					$user->wantroutepc19(1) unless defined $user->wantroutepc19;
					push @rout, $ar if $ar;
					push @pc92out, $r if $h;
				} else {
					next;
				}
			}
		}

		# unbusy and stop and outgoing mail (ie if somehow we receive another PC19 without a disconnect)
		my $mref = DXMsg::get_busy($call);
		$mref->stop_msg($call) if $mref;

		$user->lastin($main::systime) unless DXChannel::get($call);
		$user->put;
	}

	# we are not automatically sending out PC19s, we send out a composite PC21,PC19 instead
	# but remember there will only be one (pair) these because any extras will be
	# thrown away.
	if (@rout) {
#		$self->route_pc21($self->{call}, $line, @rout);
		$self->route_pc19($self->{call}, $line, @rout);
	}
	if (@pc92out && !$pc92_slug_changes) {
		$self->route_pc92a($main::mycall, $line, $main::routeroot, @pc92out) if $self->{state} eq 'normal';
	}
}

# send local configuration
sub handle_20
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($self->{do_pc9x} && $self->{state} ne 'init92') {
		$self->send("Reseting to oldstyle routing because login call not sent in any pc92");
		$self->{do_pc9x} = 0;
	}
	$self->send_local_config;
	$self->send(pc22());
	$self->state('normal');
	$self->{lastping} = 0;
	$self->route_pc92a($main::mycall, undef, $main::routeroot, Route::Node::get($self->{call}));
}

# delete a cluster from the list
#
# This should never occur for directly connected nodes.
#
sub handle_21
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = uc $pc->[1];

	eph_del_regex("^PC1[679].*$call");

	# if I get a PC21 from the same callsign as self then ignore it
	if ($call eq $self->{call}) {
		dbg("PCPROT: self referencing PC21 from $self->{call}");
		return;
	}

	# for the above reason and also because of the check for PC21s coming
	# in for self->call from outside being ignored further down
	# we don't need any isolation code here, because we will never
	# act on a PC21 with self->call in it.

	my $parent = Route::Node::get($self->{call});
	unless ($parent) {
		dbg("PCPROT: my parent $self->{call} has disappeared");
		$self->disconnect;
		return;
	}

	my @rout;

	if ($call ne $main::mycall && $call ne $main::myalias) { # don't allow malicious buggers to disconnect me!
		my $node = Route::Node::get($call);
		if ($node) {

			if ($node->via_pc92) {
				dbg("PCPROT: controlled by PC92, ignored") if isdbg('chanerr');
				return;
			}

			my $dxchan = DXChannel::get($call);
			if ($dxchan && $dxchan != $self) {
				dbg("PCPROT: PC21 from $self->{call} trying to alter locally connected $call, ignored!") if isdbg('chan');
				return;
			}

			# input filter it
			return unless $self->in_filter_route($node);

			# routing objects, force a PC21 if it is local
			push @rout, $node->del($parent);
			push @rout, $call if $dxchan && @rout == 0;
		}
	} else {
		dbg("PCPROT: I WILL _NOT_ be disconnected!") if isdbg('chan');
		return;
	}

	if (eph_dup($line)) {
		return;
	}

	if (@rout) {
		$self->route_pc21($origin, $line, @rout);
#		$self->route_pc92d($main::mycall, $line, $main::routeroot, @rout);
	}
}


sub handle_22
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($self->{do_pc9x}) {
		if ($self->{state} ne 'init92') {
			$self->send("Reseting to oldstyle routing because login call not sent in any pc92");
			$self->{do_pc9x} = 0;
		}
	}
	$self->{lastping} = 0;
	$self->state('normal');
	$self->route_pc92a($main::mycall, undef, $main::routeroot, Route::Node::get($self->{call}));
}

# WWV info
sub handle_23
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# route foreign' pc27s
	if ($pcno == 27) {
		if ($pc->[8] ne $main::mycall) {
			$self->route($pc->[8], $line);
			return;
		}
	}


	# do some de-duping
	my $d = cltounix($pc->[1], sprintf("%02d18Z", $pc->[2]));
	my $sfi = unpad($pc->[3]);
	my $k = unpad($pc->[4]);
	my $i = unpad($pc->[5]);
	my ($r) = $pc->[6] =~ /R=(\d+)/;
	$r = 0 unless $r;
	if (($pcno == 23 && $d < $main::systime - $pc23_max_age) || $d > $main::systime + 1500 || $pc->[2] < 0 || $pc->[2] > 23) {
		dbg("PCPROT: WWV Date ($pc->[1] $pc->[2]) out of range") if isdbg('chanerr');
		return;
	}

	# global wwv filtering on INPUT
	my @dxcc = ((Prefix::cty_data($pc->[7]))[0..2], (Prefix::cty_data($pc->[8]))[0..2]);
	if ($self->{inwwvfilter}) {
		my ($filter, $hops) = $self->{inwwvfilter}->it(@$pc[7,8], $origin, @dxcc);
		unless ($filter) {
			dbg("PCPROT: Rejected by input wwv filter") if isdbg('chanerr');
			return;
		}
	}
	$pc->[7] =~ s/-\d+$//o;		# remove spotter's ssid
	if (Geomag::dup($d,$sfi,$k,$i,$pc->[6],$pc->[7])) {
		dbg("PCPROT: Dup WWV Spot ignored\n") if isdbg('chanerr');
		return;
	}

	# note this only takes the first one it gets
	Geomag::update($d, $pc->[2], $sfi, $k, $i, @$pc[6..8], $r);
	dbg("WWV: <$pc->[2]>, sfi=$sfi k=$k info=$i '$pc->[6]' $pc->[7]\@$pc->[8] $r route: $origin") if isdbg('progress');

	if (defined &Local::wwv) {
		my $rep;
		eval {
			$rep = Local::wwv($self, $pc->[1], $pc->[2], $sfi, $k, $i, @$pc[6..8], $r);
		};
		return if $rep;
	}

	# DON'T be silly and send on PC27s!
	return if $pcno == 27;

	# broadcast to the eager world
	send_wwv_spot($self, $line, $d, $pc->[2], $sfi, $k, $i, @$pc[6..8]);
}

# set here status
sub handle_24
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = uc $pc->[1];
	my ($nref, $uref);
	$nref = Route::Node::get($call);
	$uref = Route::User::get($call);
	return unless $nref || $uref; # if we don't know where they are, it's pointless sending it on

	if (eph_dup($line)) {
		return;
	}

	$nref->here($pc->[2]) if $nref;
	$uref->here($pc->[2]) if $uref;
	my $ref = $nref || $uref;
	return unless $self->in_filter_route($ref);

	$self->route_pc24($origin, $line, $ref, $pc->[3]);
}

# merge request
sub handle_25
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] ne $main::mycall) {
		$self->route($pc->[1], $line);
		return;
	}
	if ($pc->[2] eq $main::mycall) {
		dbg("PCPROT: Trying to merge to myself, ignored") if isdbg('chan');
		return;
	}

	Log('DXProt', "Merge request for $pc->[3] spots and $pc->[4] WWV from $pc->[2]");

	# spots
	if ($pc->[3] > 0) {
		my @in = reverse Spot::search(1, undef, undef, 0, $pc->[3]);
		my $in;
		foreach $in (@in) {
			$self->send(pc26(@{$in}[0..4], $pc->[2]));
		}
	}

	# wwv
	if ($pc->[4] > 0) {
		my @in = reverse Geomag::search(0, $pc->[4], time, 1);
		my $in;
		foreach $in (@in) {
			$self->send(pc27(@{$in}[0..5], $pc->[2]));
		}
	}
}

sub handle_26 {goto &handle_11}
sub handle_27 {goto &handle_23}

# mail/file handling
sub handle_28
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] eq $main::mycall) {
		no strict 'refs';
		my $sub = "DXMsg::handle_$pcno";
		&$sub($self, @$pc);
	} else {
		$self->route($pc->[1], $line) unless $self->is_clx;
	}
}

sub handle_29 {goto &handle_28}
sub handle_30 {goto &handle_28}
sub handle_31 {goto &handle_28}
sub handle_32 {goto &handle_28}
sub handle_33 {goto &handle_28}

sub handle_34
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if (eph_dup($line, $eph_pc34_restime)) {
		return;
	} else {
		$self->process_rcmd($pc->[1], $pc->[2], $pc->[2], $pc->[3]);
	}
}

# remote command replies
sub handle_35
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	eph_del_regex("^PC35\\^$pc->[2]\\^$pc->[1]\\^");
	$self->process_rcmd_reply($pc->[1], $pc->[2], $pc->[1], $pc->[3]);
}

sub handle_36 {goto &handle_34}

# database stuff
sub handle_37
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] eq $main::mycall) {
		no strict 'refs';
		my $sub = "DXDb::handle_$pcno";
		&$sub($self, @$pc);
	} else {
		$self->route($pc->[1], $line) unless $self->is_clx;
	}
}

# node connected list from neighbour
sub handle_38
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;
}

# incoming disconnect
sub handle_39
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] eq $self->{call}) {
		$self->disconnect(1);
	} else {
		dbg("PCPROT: came in on wrong channel") if isdbg('chanerr');
	}
}

sub handle_40 {goto &handle_28}

# user info
sub handle_41
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = $pc->[1];
	my $sort = $pc->[2];
	my $val = $pc->[3];

	my $l = "PC41^$call^$sort";
	if (eph_dup($l, $eph_info_restime)) {
		return;
	}

	# input filter if required
	#			my $ref = Route::get($call) || Route->new($call);
	#			return unless $self->in_filter_route($ref);

	if ($val eq $sort || $val =~ /^\s*$/) {
		dbg('PCPROT: invalid value') if isdbg('chanerr');
		return;
	}

	if ($call eq $main::mycall || $call eq $main::myalias) {
		dbg "DXPROT: PC41 trying to update $call from outside via $origin, ignored";
		return;
	}
	my $chan = DXChannel::get($call);
	if ($chan) {
		dbg "DXPROT: PC41 trying to update online $call from outside via $origin, ignored";
		return;
	}

	# add this station to the user database, if required
	my $user = DXUser::get_current($call);
	$user = DXUser->new($call) unless $user;

	if ($sort == 1) {
		if (($val =~ /spotter/i || $val =~ /self/i) && $user->name && $user->name ne $val) {
			dbg("PCPROT: invalid name") if isdbg('chanerr');
			return;
		}
		$user->name($val);
	} elsif ($sort == 2) {
		$user->qth($val);
	} elsif ($sort == 3) {
		if (is_latlong($val)) {
			my ($lat, $long) = DXBearing::stoll($val);
			$user->lat($lat) if $lat;
			$user->long($long) if $long;
			$user->qra(DXBearing::lltoqra($lat, $long)) unless $user->qra;
		} else {
			dbg('PCPROT: not a valid lat/long') if isdbg('chanerr');
			return;
		}
	} elsif ($sort == 4) {
		$user->homenode($val);
	} elsif ($sort == 5) {
		if (is_qra(uc $val)) {
			my ($lat, $long) = DXBearing::qratoll(uc $val);
			$user->lat($lat) if $lat && !$user->lat;
			$user->long($long) if $long && !$user->long;
			$user->qra(uc $val);
		} else {
			dbg('PCPROT: not a valid QRA locator') if isdbg('chanerr');
			return;
		}
	}
	$user->lastoper($main::systime); # to cut down on excessive for/opers being generated
	$user->put;

	unless ($self->{isolate}) {
		DXChannel::broadcast_nodes($line, $self); # send it to everyone but me
	}

	#  perhaps this IS what we want after all
	#			$self->route_pc41($ref, $call, $sort, $val, $pc->[4]);
}

sub handle_42 {goto &handle_28}


# database
sub handle_44 {goto &handle_37}
sub handle_45 {goto &handle_37}
sub handle_46 {goto &handle_37}
sub handle_47 {goto &handle_37}
sub handle_48 {goto &handle_37}

# message and database
sub handle_49
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if (eph_dup($line)) {
		return;
	}

	if ($pc->[1] eq $main::mycall) {
		DXMsg::handle_49($self, @$pc);
	} else {
		$self->route($pc->[1], $line) unless $self->is_clx;
	}
}

# keep alive/user list
sub handle_50
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	return if (eph_dup($line));

	my $call = $pc->[1];

	my $node = Route::Node::get($call);
	if ($node) {
		return unless $node->call eq $self->{call};
		$node->usercount($pc->[2]) unless $node->users;
		$node->reset_obs;
		$node->PC92C_dxchan($self->call, $pc->[-1]);

		# input filter if required
#		return unless $self->in_filter_route($node);

		unless ($self->{isolate}) {
			DXChannel::broadcast_nodes($line, $self); # send it to everyone but me
		}
#		$self->route_pc50($origin, $line, $node, $pc->[2], $pc->[3]) unless eph_dup($line);
	}
}

# incoming ping requests/answers
sub handle_51
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $to = $pc->[1];
	my $from = $pc->[2];
	my $flag = $pc->[3];

	if ($to eq $main::myalias) {
		dbg("DXPROT: Ping addressed to \$myalias ($main::myalias), ignored") if isdbg('chan');
		return;
	}

	# is it for us?
	if ($to eq $main::mycall) {
		if ($flag == 1) {
			$self->send(pc51($from, $to, '0'));
		} else {
			DXXml::Ping::handle_ping_reply($self, $from);
		}
	} else {
		if (eph_dup($line)) {
			return;
		}
		# route down an appropriate thingy
		$self->route($to, $line);
	}
}

sub handle_61 { goto &handle_11; }

# dunno but route it
sub handle_75
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = $pc->[1];
	if ($call ne $main::mycall) {
		$self->route($call, $line);
	}
}

# WCY broadcasts
sub handle_73
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = $pc->[1];

	# do some de-duping
	my $d = cltounix($call, sprintf("%02d18Z", $pc->[2]));
	if (($pcno == 23 && $d < $main::systime - $pc23_max_age) || $d > $main::systime + 1500 || $pc->[2] < 0 || $pc->[2] > 23) {
		dbg("PCPROT: WCY Date ($call $pc->[2]) out of range") if isdbg('chanerr');
		return;
	}
	$pc = [ map { unpad($_) } @$pc ];
	if (WCY::dup($d)) {
		dbg("PCPROT: Dup WCY Spot ignored\n") if isdbg('chanerr');
		return;
	}

	my $wcy = WCY::update($d, @$pc[2..12]);
	dbg("WCY: <$pc->[2]> K=$pc->[5] expK=$pc->[6] A=$pc->[4] R=$pc->[7] SFI=$pc->[3] SA=$pc->[8] GMF=$pc->[9] Au=$pc->[10] $pc->[11]\@$pc->[12] route: $origin") if isdbg('progress');

	if (defined &Local::wcy) {
		my $rep;
		eval {
			$rep = Local::wcy($self, @$pc[1..12]);
		};
		return if $rep;
	}

	# broadcast to the eager world
	send_wcy_spot($self, $line, $d, @$pc[2..12]);
}

# remote commands (incoming)
sub handle_84
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	$self->process_rcmd($pc->[1], $pc->[2], $pc->[3], $pc->[4]);
}

# remote command replies
sub handle_85
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	$self->process_rcmd_reply($pc->[1], $pc->[2], $pc->[3], $pc->[4]);
}

# decode a pc92 call: flag call : version : build
sub _decode_pc92_call
{
	my $icall = shift;
	my @part = split /:/, $icall;
	my ($flag, $call) = unpack "A A*", $part[0];
	unless (defined $flag && $flag ge '0' && $flag le '7') {
		dbg("PCPROT: $icall no flag byte (0-7) at front of call, ignored") if isdbg('chanerr');
		return ();
	}
	unless ($call && is_callsign($call)) {
		dbg("PCPROT: $icall no recognisable callsign, ignored") if isdbg('chanerr');
		return ();
	}
	my $is_node = $flag & 4;
	my $is_extnode = $flag & 2;
	my $here = $flag & 1;
	my $version = $part[1] || 0;
	my $build = $part[2] || 0;
	my $ip = $part[3] || '';
	
	if ($version =~ /[,.]/) {
		$ip = $version;
		$version = 0;
	}
	$version =~ s/\D+//g;
	$build =~ s/^0\.//;
	$build =~ s/\D+//g;
	$ip =~ s/,/:/g if $ip;
	return ($call, $is_node, $is_extnode, $here, $version+0, $build+0, $ip);
}

# decode a pc92 call: flag call : version : build
sub _encode_pc92_call
{
	my $ref = shift;

	# plain call or value
	return $ref unless ref $ref;

	my $ext = shift || 0;
	my $flag = 0;
	my $call = $ref->call;
	my $extra = '';
	$flag |= $ref->here ? 1 : 0;
	if ($ref->isa('Route::Node') || $ref->isa('DXProt')) {
		$flag |= 4;
		my $dxchan = DXChannel::get($call);
		$flag |= 2 if $call ne $main::mycall && $dxchan && !$dxchan->{do_pc9x};
		if (($ext & 1) && $ref->version) {
			my $version = $ref->version || 1.0;
			$version =  $version * 100 + 5300 if $version < 50;
			$extra .= ":" . $version;
		}
	}
	if (($ext & 2) && $ref->ip) {
		my $ip = $ref->ip;
		$ip =~ s/:/,/g;
		$extra .= ':' . $ip;
	}
	return "$flag$call$extra";
}

my %things_add;
my %things_del;

sub _add_thingy
{
	my $parent = shift;
	my $s = shift;
	my $dxchan = shift;
	my $hops = shift;

	my ($call, $is_node, $is_extnode, $here, $version, $build, $ip) = @$s;
	my @rout;

	# remove spurious IPV6 prefix on IPV4 addresses
	$ip =~ s/^::ffff:// if $ip;
	$build ||= 0;
	$version ||= 0;

	if ($call) {
		my $ncall = $parent->call;
		if ($ncall ne $call) {
			my $user;
			my $r;

			# normalise call, delete any unnormalised calls in the users file.
			# then ignore this thingy
			my $normcall = normalise_call($call);
			if ($normcall ne $call) {
				next if DXChannel::get($call);
				$user = DXUser::get($call);
				dbg("DXProt::_add_thingy call $call normalised to $normcall, deleting spurious user $call");
				$user->del if $user;
			    $call = $normcall; # this is safe because a route add will ignore duplicates
			}
			
			if ($is_node) {
				dbg("ROUTE: added node $call to $ncall") if isdbg('routelow');
				$user = check_add_user($call, 'A');
				@rout = $parent->add($call, $version, Route::here($here), $ip);
				$r = Route::Node::get($call);
				$r->PC92C_dxchan($dxchan->call, $hops) if $r;
				if ($version && $version =~ /^\d+$/) {
					my $old = $user->sort;
					if ($user->is_ak1a && (($version >= 5455 &&  $build > 0) || ($version >= 3000 && $version <= 3500)) ) {
						$user->sort('S');
						dbg("PCProt::_add_thingy node $call v: $version b: $build sort ($old) updated to " . $user->sort);
					} elsif ($user->is_spider && $version =~ /^\d+$/ && ($version < 3000 || ($version > 4000 && $version < 5455))) {
						unless ($version == 5000 && $build == 0) {
							$user->sort('A');
							$build //= 0;
							dbg("PCProt::_add_thingy node $call v: $version b: $build sort ($old) downgraded to " . $user->sort);
						}
					}
				}
			} else {
				dbg("ROUTE: added user $call to $ncall") if isdbg('routelow');
				$user = check_add_user($call, 'U', $parent->call);
				@rout = $parent->add_user($call, Route::here($here), $ip);
				$dxchan->tell_buddies('loginb', $call, $ncall) if $dxchan;
				$r = Route::User::get($call);
			}
			if ($ip) {
				$r->ip($ip);
				Log('DXProt', "PC92A $call -> $ip on $ncall");
			}
			if ($pc92_slug_changes && $parent == $main::routeroot) {
				$things_add{$call} = Route::get($call);
				delete $things_del{$call};
			}
			$user->close($main::systime, $ip) if $user;		# this just updates lastseen and the connlist list containing the IP address
		} else {				
			dbgprintring(10) if isdbg('nologchan');
			dbg("DXProt::add_thingy: Trying to add parent $call to itself $ncall, ignored");
		}
	}
	
	return @rout;
}

sub _del_thingy
{
	my $parent = shift;
	my $s = shift;
	my $dxchan = shift;
	my ($call, $is_node, $is_extnode, $here, $version, $build) = @$s;
	my @rout;
	if ($call) {
		my $ref;
		if ($is_node) {
			$ref = Route::Node::get($call);
			dbg("ROUTE: deleting node $call from " . $parent->call) if isdbg('routelow');
			@rout = $ref->del($parent) if $ref;
		} else {
			dbg("ROUTE: deleting user $call from " . $parent->call) if isdbg('routelow');
			$ref = Route::User::get($call);
			if ($ref) {
				$dxchan->tell_buddies('logoutb', $call, $parent->call) if $dxchan;
				@rout = $parent->del_user($ref);
			}
		}
		if ($pc92_slug_changes && $parent == $main::routeroot) {
			$things_del{$call} = $ref unless exists $things_add{$call};
			delete $things_add{$call};
		}
	}
	return @rout;
}

# this will only happen if we are slugging changes and
# there are some changes to be sent, it will create an add or a delete
# or both
sub gen_pc92_changes
{
	my @add = values %things_add;
	my @del = values %things_del;
	return (\@add, \@del);
}

sub clear_pc92_changes
{
	%things_add = %things_del = ();
	$last_pc92_slug = $main::systime;
}

my $_last_time;
my $_last_occurs;
my $_last_pc9x_id;

sub last_pc9x_id
{
	return $_last_pc9x_id;
}

sub gen_pc9x_t
{
	if (!$_last_time || $_last_time != $main::systime) {
		$_last_time = $main::systime;
		$_last_occurs = 0;
		return $_last_pc9x_id = $_last_time - $main::systime_daystart;
	} else {
		$_last_occurs++;
		return $_last_pc9x_id = sprintf "%d.%02d", $_last_time - $main::systime_daystart, $_last_occurs;
	}
}

sub check_pc9x_t
{
	my $call = shift;
	my $t = shift;
	my $pc = shift;
	my $create = shift;

	# check that the time is between 0 >= $t < 86400
	unless ($t >= 0 && $t < 86400) {
		dbg("PCPROT: time invalid t: $t, ignored") if isdbg('chanerr');
		return undef;
	}

	# check that the time of this pc9x is within tolerance (default 15 mins either way)
	my $now = $main::systime - $main::systime_daystart ;
	my $diff = abs($now - $t);
	unless ($diff < $pc9x_time_tolerance || 86400 - $diff < $pc9x_time_tolerance) {
		my $c = ref $call ? $call->call : $call;
		dbg("PC9XERR: $c time out of range t: $t now: $now diff: $diff > $pc9x_time_tolerance, ignored") if isdbg('chan');
		return undef;
	}

	my $parent = ref $call ? $call : Route::Node::get($call);
	if ($parent) {
		# we only do this for external calls whose routing table
		# record come and go. The reference for mycall is permanent
		# and not that frequently used, it also never times out, so
		# the id on it is completely unreliable. Besides, only commands
		# originating on this box will go through this code...
		if ($parent->call ne $main::mycall) {
			my $lastid = $parent->lastid;
			if (defined $lastid) {
				if ($t < $lastid) {
					# note that this is where we determine whether this pc9x has come in yesterday
					# but is still greater (modulo 86400) than the lastid or is simply an old
					# duplicate sentence. To determine this we need to do some module 86400
					# arithmetic. High numbers mean that this is an old duplicate sentence,
					# low numbers that it is a new sentence.
					#
					# Typically you will see yesterday being taken on $t = 84, $lastid = 86235
					# and old dupes with $t = 234, $lastid = 256 (which give answers 249 and
					# 86378 respectively in the calculation below).
					#
					if ($t+86400-$lastid > $pc9x_past_age) {
						dbg("PCPROT: dup id on $t <= lastid $lastid, ignored") if isdbg('chanerr') || isdbg('pc92dedupe');
						return undef;
					}
				} elsif ($t == $lastid) {
					dbg("PCPROT: dup id on $t == lastid $lastid, ignored") if isdbg('chanerr') || isdbg('pc92dedupe');
					return undef;
				} else {
					# check that if we have a low number in lastid that yesterday's numbers
					# (likely in the 85000+ area) don't override them, thus causing flip flopping
					if ($lastid+86400-$t < $pc9x_past_age) {
						dbg("PCPROT: dup id on $t in yesterday, lastid $lastid, ignored") if isdbg('chanerr') || isdbg('pc92dedupe');
						return undef;
					}
				}
			}
		}
	} elsif ($create) {
		$parent = Route::Node->new($call);
	} else {
		dbg("PCPROT: $call does not exist, ignored") if isdbg('pc92dedupe');
		return undef;
	}
	if (isdbg('pc92dedupe')) {
		my $exists = exists $parent->{lastid}; # naughty, naughty :-)
		my $val = $parent->{lastid};
		my $s = $exists ? (defined $val ? $val : 'exists/undef') : 'undef';
		dbg("PCPROT: $call pc92 id lastid $s -> $t");
	}
	$parent->lastid($t);

	return $parent;
}

sub pc92_handle_first_slot
{
	my $self = shift;
	my $slot = shift;
	my $parent = shift;
	my $t = shift;
	my $hops = shift;
	my $oparent = $parent;

	my @radd;

	my ($call, $is_node, $is_extnode, $here, $version, $build) = @$slot;
	if ($call && $is_node) {
		if ($call eq $main::mycall) {
			LogDbg('err', "PCPROT: $self->{call} : $call looped back onto \$main::mycall ($main::mycall), ignored");
			return;
		}
		if ($call eq $main::myalias) {
			LogDbg('err', "PCPROT: $self->{call} : $call looped back onto \$main::myalias ($main::myalias), ignored");
			return;
		}
		# this is only accepted from my "self".
		# this also kills configs from PC92 nodes with external PC19 nodes that are also
		# locally connected. Local nodes always take precedence. But we remember the lastid
		# to try to reduce the number of dupe PC92s for this external node.
		if (DXChannel::get($call) && $call ne $self->{call}) {
			$parent = check_pc9x_t($call, $t, 92); # this will update the lastid time
			dbg("PCPROT: locally connected node $call from other another node $self->{call}, ignored") if isdbg('chanerr');
			return;
		}
		if ($is_extnode) {
			# reparent to external node (note that we must have received a 'C' or 'A' record
			# from the true parent node for this external before we get one for the this node
			unless ($parent = Route::Node::get($call)) {
				if ($is_extnode && $oparent) {
					@radd = _add_thingy($oparent, $slot, $self, $hops);
					$parent = $radd[0];
				} else {
					dbg("PCPROT: no previous C or A for this external node received, ignored") if isdbg('chanerr');
					return;
				}
			}
			$parent = check_pc9x_t($call, $t, 92) || return;
			$parent->via_pc92(1);
			$parent->PC92C_dxchan($self->{call}, $hops);
		}
	} else {
		dbg("PCPROT: must be \$mycall or external node as first entry, ignored") if isdbg('chanerr');
		return;
	}
	$parent->here(Route::here($here));
	$parent->version($version || $pc19_version) if $version;
    $parent->build($build) if $build;
	$parent->PC92C_dxchan($self->{call}, $hops) unless $self->{call} eq $parent->call;
	return ($parent, @radd);
}

# DXSpider routing entries
sub handle_92
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my (@radd, @rdel);

	my $pcall = $pc->[1];
	my $t = $pc->[2];
	my $sort = $pc->[3];
	my $hops = $pc->[-1];

	# this catches loops of A/Ds
#	if (eph_dup($line, $pc9x_dupe_age)) {
#		return;
#	}

	if ($pcall eq $main::mycall) {
		LogDbg('err', "PCPROT: looped back, ignored");
		return;
	}

	if ($pcall eq $main::myalias) {
		LogDbg('err', "PCPROT: looped back to \$myalias ($main::myalias), misconfiguration ignored");
		return;
	}

	if ($pcall eq $self->{call} && $self->{state} eq 'init') {
		if ($self->{isolate}) {
			dbg("DXPROT: PC9x received, but $pcall is isolated, ignored");
			return;
		} elsif (!$self->user->wantpc9x) {
			dbg("DXPROT: PC9x explicitly switched off on $pcall, ignored");
			return;
		} else {
			$self->state('init92');
			$self->{do_pc9x} = 1;
			dbg("DXPROT: Do pc9x set on $pcall");
		}
	}
	unless ($self->{do_pc9x}) {
		dbg("PCPROT: PC9x come in from non-PC9x node, ignored") if isdbg('chanerr');
		return;
	}

	# don't create routing entries for D records that don't already exist
	# this is what causes all those PC92 loops!
	my $parent = check_pc9x_t($pcall, $t, 92, $sort ne 'D') || return;
	my $oparent = $parent;

	$parent->do_pc9x(1);
	$parent->via_pc92(1);

	if ($sort eq 'F' || $sort eq 'R') {

		# this is the route finding section
		# here is where the consequences of the 'find' command
		# are dealt with

		my $from = $pc->[4];
		my $target = $pc->[5];

		if ($sort eq 'F') {
			my $flag;
			my $ref;
			my $dxchan;
			if ($ref = DXChannel::get($target)) {
				$flag = 1;		# we are directly connected
			} else {
				$ref = Route::get($target);
				$dxchan = $ref->dxchan;
				$flag = 2;
			}
			if ($ref && $flag && $dxchan) {
				$self->send(pc92r($from, $target, $flag, int($dxchan->{pingave}*1000)));
				return;
			}
		} elsif ($sort eq 'R') {
			if (my $dxchan = DXChannel::get($from)) {
				handle_pc92_find_reply($dxchan, $pcall, $from, $target, @$pc[6,7]);
			} else {
				my $ref = Route::get($from);
				if ($ref) {
					my @dxchan = grep {$_->do_pc9x} $ref->alldxchan;
					if (@dxchan) {
						$_->send($line) for @dxchan;
					} else {
						dbg("PCPROT: $self->{call} : type R no return route, ignored") if isdbg('chanerr') || isdbg('route');
					}
				} else {
					dbg("PCPROT: $self->{call} : type R no return route, ignored") if isdbg('chanerr') || isdbg('route');
				}
			}
			return;
		}

	} elsif ($sort eq 'K') {
		$pc92Kin += length $line;

		# remember the last channel we arrived on
		$parent->PC92C_dxchan($self->{call}, $hops) unless $self->{call} eq $parent->call;

		my @ent = _decode_pc92_call($pc->[4]);

		if (@ent) {
			my $add;

			($parent, $add) = $self->pc92_handle_first_slot(\@ent, $parent, $t, $hops);
			return unless $parent; # dupe
			
			push @radd, $add if $add;
			$parent->reset_obs;
			my $call = $parent->call;
			my $version = $ent[4] || 0;
			my $build = $ent[5] ||  0;
			my $oldbuild = $parent->build || 0;
			my $oldversion = $parent->version || 0;
			my $user = check_add_user($parent->call, 'S');
			my $oldsort = $user->sort // '';
#			if ($version =~ /^\d+$/  && $oldversion =~ /^\d+$/) {
				if ($oldsort ne 'S' || $oldversion != $version || $build != $oldbuild) {
					dbg("PCProt PC92 K node $call updated version: $version (was $oldversion) build: $build (was $oldbuild) sort: 'S' (was $oldsort)");
					$user->sort('S');
					$user->version($parent->version($version));
					$user->build($parent->build($build));
					$user->put;
				}
#			} else {
#				dbg("DXProt PC92 K version strings new: '$version' old: '$oldversion'");
#			}
			dbg("ROUTE: reset obscount on $parent->{call} now " . $parent->obscount) if isdbg('obscount');
		}
	} elsif ($sort eq 'A' || $sort eq 'D' || $sort eq 'C') {

		$pc92Ain += length $line if $sort eq 'A';
		$pc92Cin += length $line if $sort eq 'C';
		$pc92Din += length $line if $sort eq 'D';

		# remember the last channel we arrived on
		$parent->PC92C_dxchan($self->{call}, $hops) unless $self->{call} eq $parent->call;

		# this is the main route section
		# here is where all the routes are created and destroyed

		# cope with missing duplicate node calls in the first slot
		my $me = $pc->[4] || '';
		$me ||= _encode_pc92_call($parent) unless $me ;

		my @ent = map {my @a = _decode_pc92_call($_); @a ? \@a : ()} grep {$_ && /^[0-7]/} $me, @$pc[5 .. $#$pc];

		if (@ent) {

			# look at the first one which will always be a node of some sort
			# except in the case of 'A' or 'D' in which the $pcall is used
			# otherwise use the node call and update any information
			# that needs to be done.
			my $add;

			($parent, $add) = $self->pc92_handle_first_slot($ent[0], $parent, $t, $hops);
			return unless $parent; # dupe

			shift @ent;
			push @radd, $add if $add;
		}

		# do a pass through removing any references to either mycall
		my @nent;
		for (@ent) {
			my $dxc;
			next unless $_ && @$_;
			if ($_->[0] eq $main::mycall) {
				dbg("PCPROT: $self->{call} : type $sort $_->[0] refers to me, ignored") if isdbg('route');
				next;
			}
			if ($_->[0] eq $main::myalias && $_->[1] || $_->[0] eq $main::mycall && $_->[1] == 0) {
				LogDbg('err',"PCPROT: $self->{call} : type $sort $_->[0] trying to change type to " . $_->[1]?"Node":"User" . ", ignored");
				next;
			}
			
			push @nent, $_;
		}

		if ($sort eq 'A') {
			for (@nent) {
				push @radd, _add_thingy($parent, $_, $self, $hops);
			}
		} elsif ($sort eq 'D') {
			for (@nent) {
				push @rdel, _del_thingy($parent, $_, $self);
			}
		} elsif ($sort eq 'C') {
			my (@nodes, @users);

			# we reset obscounts on config records as well as K records
			$parent->reset_obs;
			dbg("ROUTE: reset obscount on $parent->{call} now " . $parent->obscount) if isdbg('obscount');

			#
			foreach my $r (@nent) {
				#			my ($call, $is_node, $is_extnode, $here, $version, $build) = _decode_pc92_call($_);
				if ($r->[0]) {
					if ($r->[1]) {
						push @nodes, $r->[0];
					} else {
						push @users, $r->[0];
					}
				} else {
					dbg("PCPROT: $self->{call} :  pc92 call entry '$_' not decoded, ignored") if isdbg('chanerr') || isdbg('route');
				}
			}

			my ($dnodes, $dusers, $nnodes, $nusers) = $parent->calc_config_changes(\@nodes, \@users);

			# add users here
			foreach my $r (@nent) {
				my $call = $r->[0];
				if ($call) {
					push @radd,_add_thingy($parent, $r, $self, $hops) if grep $call eq $_, (@$nnodes, @$nusers);
				}
			}
			# del users here
			foreach my $r (@$dnodes) {
				push @rdel,_del_thingy($parent, [$r, 1], $self);
			}
			foreach my $r (@$dusers) {
				push @rdel,_del_thingy($parent, [$r, 0], $self);
			}

			# remember this last PC92C for rebroadcast on demand
			$parent->last_PC92C($line);
		} else {
			dbg("PCPROT: unknown action '$sort', ignored") if isdbg('chanerr');
			return;
		}

		foreach my $r (@rdel) {
			next unless $r;

			$self->route_pc21($pcall, undef, $r) if $r->isa('Route::Node');
			$self->route_pc17($pcall, undef, $parent, $r) if $r->isa('Route::User');
		}
		my @pc19 = grep { $_ && $_->isa('Route::Node') } @radd;
		my @pc16 = grep { $_ && $_->isa('Route::User') } @radd;
		unshift @pc19, $parent if $self->{state} eq 'init92' && $oparent == $parent;
		$self->route_pc19($pcall, undef, @pc19) if @pc19;
		$self->route_pc16($pcall, undef, $parent, @pc16) if @pc16;
	}

	# broadcast it if we get here
	$self->broadcast_route_pc9x($pcall, undef, $line, 0);
}

# get all the routes for a thing, bearing in mind that the thing (e.g. a user)
# might be on two or more nodes at the same time or that there may be more than
# one equal distance neighbour to a node.
#
# What this means that if sh/route g1tlh shows that he is on (say) two nodes, then
# a Route::findroutes is done on each of those two nodes, the best route(s) taken from
# each and then combined to give a set of dxchans to send the PC9x record down
#
sub find_pc9x_routes
{
	my $to = shift;
	my $ref = Route::get($to);
	my @parent;
	my %cand;

	if ($ref->isa('Route::User')) {
		my $dxchan = DXChannel::get($to);
		push @parent, $to if $dxchan;
		push @parent, $ref->parents;
	} else {
		@parent = $to;
	}
	foreach my $p (@parent) {
		my $lasthops;
		my @routes = Route::findroutes($p);
		foreach my $r (@routes) {
			$lasthops = $r->[0] unless defined $lasthops;
			if ($r->[0] == $lasthops) {
				$cand{$r->[1]->call} = $r->[1];
			} else {
				last;
			}
		}
	}
	return values %cand;
}

sub handle_93
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

#	$self->{do_pc9x} ||= 1;

	my $pcall = $pc->[1];			# this is now checked earlier

	# remember that we are converting PC10->PC93 and self will be $main::me if it
	# comes from us
	unless ($self->{do_pc9x}) {
		dbg("PCPROT: PC9x come in from non-PC9x node, ignored") if isdbg('chanerr');
		return;
	}

	my $t = $pc->[2];
	my $parent = check_pc9x_t($pcall, $t, 93, 1) || return;

	my $to = uc $pc->[3];
	my $from = uc $pc->[4];
	my $via = uc $pc->[5];
	my $text = $pc->[6];
	my $onode = uc $pc->[7];
	$onode = $pcall if @$pc <= 8;

	# this is catch loops caused by bad software ...
	if (eph_dup("PC93|$from|$text|$onode", $pc10_dupe_age)) {
		return;
	}

	if (isdbg('progress')) {
		my $vs = $via ne '*' ? " via $via" : ''; 
		my $s = "ANNTALK: $from\@$onode$vs -> $to '$text' route: $origin";
		dbg($s);
	}
	
	# will we allow it at all?
	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($text)) {
			dbg("PCPROT: Bad words: @bad, dropped") if isdbg('chanerr');
			return;
		}
	}

	# if this is a 'bad spotter' user then ignore it
	my $nossid = $from;
	$nossid =~ s/-\d+$//;
	if ($badspotter->in($nossid)) {
		dbg("PCPROT: Bad Spotter, dropped") if isdbg('chanerr');
		return;
	}

	# ignore PC93 coming in from outside this node with a target of local
	if ($to eq 'LOCAL' && $self != $main::me) {
		dbg("PCPROT: incoming LOCAL chat not from local node, ignored") if isdbg('chanerr');
		return;
	}

	# if it is routeable then then treat it like a talk
	my $ref = Route::get($to);
	if ($ref) {
		my $dxchan;

		# convert to PC10 or local talks where appropriate
		# PC93 capable nodes of the same hop count all get a copy
		# if there is a PC10 node then it will get a copy and that
		# will be it. Hopefully such a node will not figure highly
		# in the route list, unless it is local, 'cos it don't issue PC92s!
		# note that both local and PC93s at the same time are possible if the
		# user on more than one node.
		my @routes = find_pc9x_routes($to);
		my $lasthops;
		foreach $dxchan (@routes) {
			if (ref $dxchan && $dxchan->isa('DXChannel')) {
				if ($dxchan->{do_pc9x}) {
					$dxchan->send($line);
				} else {
					$dxchan->talk($from, $to, $via, $text, $onode);
				}
			} else {
				dbg("ERROR: $to -> $dxchan is not a DXChannel! (convert to pc10)");
			}
		}
		return;

	} elsif ($to eq '*' || $to eq 'SYSOP' || $to eq 'WX') {
		# announces
		my $sysop = $to eq 'SYSOP' ? '*' : ' ';
		my $wx = $to eq 'WX' ? '1' : '0';
		my $local = $via eq 'LOCAL' ? '*' : $via;

		$self->send_announce(1, pc12($from, $text, $local, $sysop, $wx, $pcall), $from, $local, $text, $sysop, $pcall, $wx, $via eq 'LOCAL' ? $via : undef);
		return if $via eq 'LOCAL';
	} elsif (!is_callsign($to) && $text =~ /^#\d+ /) {
		# chat messages really only locally connected users
		$self->send_chat(1, $line, $from, '*', $text, $to, $pcall, '0');
	}

	# broadcast this chat sentence everywhere unless it is targetted to 'LOCAL'
	$self->broadcast_route_pc9x($pcall, undef, $line, 0) unless $to eq 'LOCAL' || $via eq 'LOCAL';
}

# if get here then rebroadcast the thing with its Hop count decremented (if
# there is one). If it has a hop count and it decrements to zero then don't
# rebroadcast it.
#
# NOTE - don't arrive here UNLESS YOU WANT this lump of protocol to be
#        REBROADCAST!!!!
#

sub handle_default
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	unless (eph_dup($line)) {
		if ($pcno >= 90) {
			my $pcall = $pc->[1];
			unless (is_callsign($pcall)) {
				dbg("PCPROT: invalid callsign string '$pc->[1]', ignored") if isdbg('chanerr');
				return;
			}
			my $t = $pc->[2];
			my $parent = check_pc9x_t($pcall, $t, $pcno, 1) || return;
			$self->broadcast_route_pc9x($pcall, undef, $line, 0);
		} else {
			unless ($self->{isolate}) {
				DXChannel::broadcast_nodes($line, $self) if $line =~ /\^H\d+\^?~?$/; # send it to everyone but me
			}
		}
	}
}

1;
