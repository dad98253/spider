#!/usr/bin/perl -w
#
# this is the operators console.
#
# Calling syntax is:-
#
# console.pl [callsign] 
#
# if the callsign isn't given then the sysop callsign in DXVars.pm is assumed
#
# Copyright (c) 1999 Dirk Koopman G1TLH
#
# $Id$
# 

require 5.004;

# search local then perl directories
BEGIN {
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
	
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
}

use Msg;
use DXVars;
use DXDebug;
use IO::File;
use Curses;

use Carp qw{cluck};

use Console;

#
# initialisation
#

$call = "";                     # the callsign being used
$conn = 0;                      # the connection object for the cluster
$lasttime = time;               # lasttime something happened on the interface

$connsort = "local";
@khistory = ();
@shistory = ();
$khistpos = 0;
$spos = $pos = $lth = 0;
$inbuf = "";

# cease communications
sub cease
{
	my $sendz = shift;
	if ($conn && $sendz) {
		$conn->send_now("Z$call|bye...\n");
	}
	endwin();
	dbgclose();
	print @_ if @_;
	exit(0);	
}

# terminate program from signal
sub sig_term
{
	cease(1, @_);
}

# determine the colour of the line
sub setattr
{
	if ($has_colors) {
		foreach my $ref (@colors) {
			if ($_[0] =~ m{$$ref[0]}) {
				$top->attrset($$ref[1]);
				last;
			}
		}
	}
}

# display the top screen
sub show_screen
{
	if ($spos == @shistory - 1) {

		# if we really are scrolling thru at the end of the history
		my $line = $shistory[-1];
		$top->addstr("\n") if $spos > 0;
		setattr($line);
		$top->addstr($line);
		$top->attrset(COLOR_PAIR(0)) if $has_colors;
		$spos = @shistory;
		
	} else {
		
		# anywhere else
		my $p = $spos - $pages;
		my $i;
		$p = 0 if $p < 0;
		
		$top->move(0, 0);
		$top->attrset(COLOR_PAIR(0)) if $has_colors;
		$top->clrtobot();
		for ($i = 0; $i < $pages && $p < @shistory; $i++, $p++) {
			my $line = $shistory[$p];
			$line = substr($line, 0, COLS()) if length $line > COLS();
			$top->move($i, 0);
			setattr($line);
			$top->addstr($line);
			$top->attrset(COLOR_PAIR(0)) if $has_colors;
		}
		$spos = $p;
	}
	$top->refresh();
}

# add a line to the end of the top screen
sub addtotop
{
	my $inbuf = shift;
	push @shistory, $inbuf;
	shift @shistory if @shistory > $maxshist;
	show_screen();
}

# handle incoming messages
sub rec_socket
{
	my ($con, $msg, $err) = @_;
	if (defined $err && $err) {
		cease(1);
	}
	if (defined $msg) {
		my ($sort, $call, $line) = $msg =~ /^(\w)(\S+)\|(.*)$/;
		
		if ($sort eq 'D') {
			addtotop($line);
		} elsif ($sort eq 'Z') { # end, disconnect, go, away .....
			cease(0);
		}	  
	}
	$top->refresh();
	$lasttime = time; 
}

sub rec_stdin
{
	my ($fh) = @_;

	$r = $bot->getch();
	
	#  my $prbuf;
	#  $prbuf = $buf;
	#  $prbuf =~ s/\r/\\r/;
	#  $prbuf =~ s/\n/\\n/;
	#  print "sys: $r ($prbuf)\n";
	if (defined $r) {
		if ($r eq KEY_ENTER || $r eq "\n" || $r eq "\r") {
			
			# save the lines
			if ($inbuf) {
				push @khistory, $inbuf if $inbuf;
				shift @khistory if @khistory > $maxkhist;
				$khistpos = @khistory;
				$bot->move(0,0);
				$bot->clrtoeol();
				$bot->addstr(substr($inbuf, 0, COLS));
			}

			# add it to the monitor window
			addtotop($inbuf) if $inbuf;
		
			# send it to the cluster
			$inbuf = " " unless $inbuf;
			$conn->send_later("I$call|$inbuf");
			$inbuf = "";
			$pos = $lth = 0;
		} elsif ($r eq KEY_UP || $r eq "\020") {
			if ($khistpos > 0) {
				--$khistpos;
				$inbuf = $khistory[$khistpos];
				$pos = $lth = length $inbuf;
			} else {
				beep();
			}
		} elsif ($r eq KEY_DOWN || $r eq "\016") {
			if ($khistpos < @khistory - 1) {
				++$khistpos;
				$inbuf = $khistory[$khistpos];
				$pos = $lth = length $inbuf;
			} else {
				beep();
			}
		} elsif ($r eq KEY_PPAGE || $r eq "\032") {
			if ($spos > 0) {
				$spos -= $pages;
				$spos = 0 if $spos < 0;
				show_screen();
			} else {
				beep();
			}
		} elsif ($r eq KEY_NPAGE || $r eq "\026") {
			if ($spos < @shistory - 1) {
				$spos += $pages;
				$spos = @shistory if $spos > @shistory;
				show_screen();
			} else {
				beep();
			}
		} elsif ($r eq KEY_LEFT || $r eq "\002") {
			if ($pos > 0) {
				--$pos;
			} else {
				beep();
			}
		} elsif ($r eq KEY_RIGHT || $r eq "\006") {
			if ($pos < $lth) {
				++$pos;
			} else {
				beep();
			}
		} elsif ($r eq KEY_HOME || $r eq "\001") {
			$pos = 0;
		} elsif ($r eq KEY_END || $r eq "\005") {
			$pos = $lth;
		} elsif ($r eq KEY_BACKSPACE || $r eq "\010") {
			if ($pos > 0) {
				my $a = substr($inbuf, 0, $pos-1);
				my $b = substr($inbuf, $pos) if $pos < $lth;
				$b = "" unless $b;
				
				$inbuf = $a . $b;
				--$lth;
				--$pos;
			} else {
				beep();
			}
		} elsif ($r eq KEY_DC || $r eq "\004") {
			if ($pos < $lth) {
				my $a = substr($inbuf, 0, $pos);
				my $b = substr($inbuf, $pos+1) if $pos < $lth;
				$b = "" unless $b;
				
				$inbuf = $a . $b;
				--$lth;
			} else {
				beep();
			}
		} elsif ($r ge ' ' && $r le '~') {
			if ($pos < $lth) {
				my $a = substr($inbuf, 0, $pos);
				my $b = substr($inbuf, $pos);
				$inbuf = $a . $r . $b;
			} else {
				$inbuf .= $r;
			}
			$pos++;
			$lth++;
		} elsif ($r eq "\014" || $r eq "\022") {
#			curscr()->refresh();
			return;
		} elsif ($r eq "\013") {
			$inbuf = substr($inbuf, 0, $pos);
			$lth = length $inbuf;
		} else {
			beep();
		}
		$bot->move(1, 0);
		$bot->clrtobot();
		$bot->addstr($inbuf);
	} 
	$bot->move(1, $pos);
	$bot->refresh();
}


#
# deal with args
#

$call = uc shift @ARGV if @ARGV;
$call = uc $myalias if !$call;

if ($call eq $mycall) {
	print "You cannot connect as your cluster callsign ($mycall)\n";
	exit(0);
}

$conn = Msg->connect("$clusteraddr", $clusterport, \&rec_socket);
if (! $conn) {
	if (-r "$data/offline") {
		open IN, "$data/offline" or die;
		while (<IN>) {
			print $_;
		}
		close IN;
	} else {
		print "Sorry, the cluster $mycall is currently off-line\n";
	}
	exit(0);
}


$SIG{'INT'} = \&sig_term;
$SIG{'TERM'} = \&sig_term;
$SIG{'HUP'} = 'IGNORE';

$scr = new Curses;
raw();
noecho();
$has_colors = has_colors();

if ($has_colors) {
	start_color();
	init_pair(0, $foreground, $background);
	init_pair(1, COLOR_RED, $background);
	init_pair(2, COLOR_YELLOW, $background);
	init_pair(3, COLOR_GREEN, $background);
	init_pair(4, COLOR_CYAN, $background);
	init_pair(5, COLOR_BLUE, $background);
	init_pair(6, COLOR_MAGENTA, $background);
}

$top = $scr->subwin(LINES()-4, COLS, 0, 0);
$top->intrflush(0);
$top->scrollok(1);
$scr->addstr(LINES()-4, 0, '-' x COLS);
$bot = $scr->subwin(3, COLS, LINES()-3, 0);
$bot->intrflush(0);
$bot->scrollok(1);
$bot->keypad(1);
$bot->move(1,0);
$scr->refresh();

$SIG{__DIE__} = \&sig_term;

$pages = LINES()-4;

$conn->send_now("A$call|$connsort");
$conn->send_now("I$call|set/page $maxshist");
$conn->send_now("I$call|set/nobeep");

Msg->set_event_handler(\*STDIN, "read" => \&rec_stdin);

for (;;) {
	my $t;
	Msg->event_loop(1, 0.010);
	$top->refresh() if $top->is_wintouched;
	$bot->refresh();
	$t = time;
	if ($t > $lasttime) {
		$lasttime = $t;
	}
}

exit(0);
