#!/usr/bin/perl
#
# A thing that implements dxcluster 'protocol'
#
# This is a perl module/program that sits on the end of a dxcluster
# 'protocol' connection and deals with anything that might come along.
#
# this program is called by ax25d and gets raw ax25 text on its input
#
# Copyright (c) 1998 Dirk Koopman G1TLH
#
# $Id$
# 

use Msg;
use DXVars;
use DXUtil;
use DXChannel;
use DXUser;
use DXM;
use DXCommandmode;
use DXProt;

package main;

@inqueue = ();                # the main input queue, an array of hashes
$systime = 0;                 # the time now (in seconds)

# handle disconnections
sub disconnect
{
  my $dxchan = shift;
  return if !defined $dxchan;
  my $user = $dxchan->{user};
  my $conn = $dxchan->{conn};
  if ($user->{sort} eq 'A') {           # and here (when I find out how to write it!)
    $dxchan->pc_finish();  
  } else {
    $dxchan->user_finish();
  }
  $user->close() if defined $user;
  $conn->disconnect() if defined $conn;
  $dxchan->del();
}

# handle incoming messages
sub rec
{
  my ($conn, $msg, $err) = @_;
  my $dxchan = DXChannel->get_by_cnum($conn);      # get the dxconnnect object for this message
  
  if (defined $err && $err) {
    disconnect($dxchan) if defined $dxchan;
	return;
  }
  
  # set up the basic channel info - this needs a bit more thought - there is duplication here
  if (!defined $dxchan) {
     my ($sort, $call, $line) = $msg =~ /^(\w)(\S+)\|(.*)$/;
     my $user = DXUser->get($call);
	 $user = DXUser->new($call) if !defined $user;
     $dxchan = DXChannel->new($call, $conn, $user);  
  }
  
  # queue the message and the channel object for later processing
  if (defined $msg) {
    my $self = bless {}, "inqueue";
    $self->{dxchan} = $dxchan;
    $self->{data} = $msg;
	push @inqueue, $self;
  }
}

sub login
{
  return \&rec;
}

# cease running this program, close down all the connections nicely
sub cease
{
  my $dxchan;
  foreach $dxchan (DXChannel->get_all()) {
    disconnect($dxchan);
  }
  exit(0);
}

# this is where the input queue is dealt with and things are dispatched off to other parts of
# the cluster
sub process_inqueue
{
  my $self = shift @inqueue;
  return if !$self;
  
  my $data = $self->{data};
  my $dxchan = $self->{dxchan};
  my ($sort, $call, $line) = $data =~ /^(\w)(\S+)\|(.*)$/;
  
  # do the really sexy console interface bit! (Who is going to do the TK interface then?)
  print DEBUG atime, " < $sort $call $line\n" if defined DEBUG;
  print "< $sort $call $line\n";
  
  # handle A records
  my $user = $dxchan->{user};
  if ($sort eq 'A') {
	$user->{sort} = 'U' if !defined $user->{sort};
    if ($user->{sort} eq 'A') {
	  $dxchan->pc_start($line);  
	} else {
	  $dxchan->user_start($line);
	}
  } elsif ($sort eq 'D') {
    die "\$user not defined for $call" if !defined $user;
    if ($user->{sort} eq 'A') {           # we will have a symbolic ref to a proc here
	  $dxchan->pc_normal($line);  
	} else {
	  $dxchan->user_normal($line);
	}
  } elsif ($sort eq 'Z') {
    disconnect($dxchan);
  } else {
    print STDERR atime, " Unknown command letter ($sort) received from $call\n";
  }
}

#############################################################
#
# The start of the main line of code 
#
#############################################################

# open the debug file, set various FHs to be unbuffered
open(DEBUG, ">>$debugfn") or die "can't open $debugfn($!)";
select DEBUG; $| = 1;
select STDOUT; $| = 1;

# initialise User file system
DXUser->init($userfn);

# start listening for incoming messages/connects
Msg->new_server("$clusteraddr", $clusterport, \&login);

# prime some signals
$SIG{'INT'} = \&cease;
$SIG{'TERM'} = \&cease;
$SIG{'HUP'} = 'IGNORE';

# this, such as it is, is the main loop!
for (;;) {
  my $timenow;
  Msg->event_loop(1, 0.001);
  $timenow = time;
  if ($timenow != $systime) {
    $systime = $timenow;
	$cldate = &cldate();
	$ztime = &ztime();
  }
  process_inqueue();                 # read in lines from the input queue and despatch them
  DXCommandmode::user_process();     # process ongoing command mode stuff
  DXProt::pc_process();              # process ongoing ak1a pcxx stuff
}

