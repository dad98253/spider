#!/usr/bin/perl -w
#
# Database Handler module for DXSpider
#
# Copyright (c) 1999 Dirk Koopman G1TLH
#

package DXDb;

use strict;
use DXVars;
use DXLog;
use DXUtil;
use DB_File;

use Carp;

use vars qw($opentime $dbbase %avail %valid $lastprocesstime $nextstream %stream);

$opentime = 5*60;				# length of time a database stays open after last access
$dbbase = "$main::root/db";		# where all the databases are kept;
%avail = ();					# The hash contains a list of all the databases
%valid = (
		  accesst => '9,Last Access Time,atime',
		  createt => '9,Create Time,atime',
		  lastt => '9,Last Update Time,atime',
		  name => '0,Name',
		  db => '9,DB Tied hash',
		  remote => '0,Remote Database',
		 );

$lastprocesstime = time;
$nextstream = 0;
%stream = ();

# allocate a new stream for this request
sub newstream
{
	my $call = uc shift;
	my $n = ++$nextstream;
	$stream{$n} = { n=>$n, call=>$call, t=>$main::systime };
	return $n;
}

# delete a stream
sub delstream
{
	my $n = shift;
	delete $stream{$n};
}

# get a stream
sub getstream
{
	my $n = shift;
	return $stream{$n};
}

# load all the database descriptors
sub load
{
	my $s = readfilestr($dbbase, "dbs", "pl");
	if ($s) {
		my $a = { eval $s } ;
		confess $@ if $@;
		%avail = %{$a} if $a
	}
}

# save all the database descriptors
sub save
{
	my $date = cldatetime($main::systime);
	
	writefilestr($dbbase, "dbs", "pl", \%avail, "#\n# database descriptor file\n# Don't alter this by hand unless you know what you are doing\n# last modified $date\n#\n");
}

# get the descriptor of the database you want.
sub getdesc
{
	return undef unless %avail;
	
	my $name = lc shift;
	my $r = $avail{$name};

	# search for a partial if not found direct
	unless ($r) {
		for (values %avail) {
			if ($_->{name} =~ /^$name/) {
				$r = $_;
				last;
			}
		}
	}
	return $r;
}

# open it
sub open
{
	my $self = shift;
	$self->{accesst} = $main::systime;
	return $self->{db} if $self->{db};
	my %hash;
	$self->{db} = tie %hash, 'DB_File', "$dbbase/$self->{name}";
#	untie %hash;
	return $self->{db};
}

# close it
sub close
{
	my $self = shift;
	if ($self->{db}) {
		untie $self->{db};
	}
}

# close all
sub closeall
{
	if (%avail) {
		for (values %avail) {
			$_->close();
		}
	}
}

# get a value from the database
sub getkey
{
	my $self = shift;
	my $key = uc shift;
	my $value;

	# make sure we are open
	$self->open;
	if ($self->{db}) {
		my $s = $self->{db}->get($key, $value);
		return $s ? undef : $value;
	}
	return undef;
}

# put a value to the database
sub putkey
{
	my $self = shift;
	my $key = uc shift;
	my $value = shift;

	# make sure we are open
	$self->open;
	if ($self->{db}) {
		my $s = $self->{db}->put($key, $value);
		return $s ? undef : 1;
	}
	return undef;
}

# create a new database params: <name> [<remote node call>]
sub new
{
	my $self = bless {};
	my $name = shift;
	my $remote = shift;
	$self->{name} = lc $name;
	$self->{remote} = uc $remote if $remote;
	$self->{accesst} = $self->{createt} = $self->{lastt} = $main::systime;
	$avail{$self->{name}} = $self;
	mkdir $dbbase, 02775 unless -e $dbbase;
	save();
}

# delete a database
sub delete
{
	my $self = shift;
	$self->close;
	unlink "$dbbase/$self->{name}";
	delete $avail{$self->{name}};
	save();
}

#
# process intermediate lines for an update
# NOTE THAT THIS WILL BE CALLED FROM DXCommandmode and the
# object will be a DXChannel (actually DXCommandmode)
#
sub normal
{
	
}

#
# periodic maintenance
#
# just close any things that haven't been accessed for the default
# time 
#
#
sub process
{
	my ($dxchan, $line) = @_;

	# this is periodic processing
	if (!$dxchan || !$line) {
		if ($main::systime - $lastprocesstime >= 60) {
			if (%avail) {
				for (values %avail) {
					if ($main::systime - $_->{accesst} > $opentime) {
						$_->close;
					}
				}
			}
			$lastprocesstime = $main::systime;
		}
		return;
	}

	my @f = split /\^/, $line;
	my ($pcno) = $f[0] =~ /^PC(\d\d)/; # just get the number

	# route out ones that are not for us
	if ($f[1] eq $main::mycall) {
		;
	} else {
		$dxchan->route($f[1], $line);
		return;
	}

 SWITCH: {
		if ($pcno == 37) {		# probably obsolete
			last SWITCH;
		}

		if ($pcno == 44) {		# incoming DB Request
			my $db = getdesc($f[4]);
			if ($db) {
				if ($db->{remote}) {
					sendremote($dxchan, $f[2], $f[3], $dxchan->msg('dx1', $db->{remote}));
				} else {
					my $value = $db->getkey($f[5]);
					if ($value) {
						my @out = split /\n/, $value;
						sendremote($dxchan, $f[2], $f[3], @out);
					} else {
						sendremote($dxchan, $f[2], $f[3], $dxchan->msg('dx2', $f[5], $db->{name}));
					}
				}
			} else {
				sendremote($dxchan, $f[2], $f[3], $dxchan->msg('dx3', $f[4]));
			}
			last SWITCH;
		}

		if ($pcno == 45) {		# incoming DB Information
			my $n = getstream($f[3]);
			if ($n) {
				my $mchan = DXChannel->get($n->{call});
				$mchan->send($f[2] . ":$f[4]") if $mchan;
			}
			last SWITCH;
		}

		if ($pcno == 46) {		# incoming DB Complete
			delstream($f[3]);
			last SWITCH;
		}

		if ($pcno == 47) {		# incoming DB Update request
			last SWITCH;
		}

		if ($pcno == 48) {		# incoming DB Update request 
			last SWITCH;
		}
	}	
}

# send back a trache of data to the remote
# remember $dxchan is a dxchannel
sub sendremote
{
	my $dxchan = shift;
	my $tonode = shift;
	my $stream = shift;

	for (@_) {
		$dxchan->send(DXProt::pc45($main::mycall, $tonode, $stream, $_));
	}
	$dxchan->send(DXProt::pc46($main::mycall, $tonode, $stream));
}

# various access routines

#
# return a list of valid elements 
# 

sub fields
{
	return keys(%valid);
}

#
# return a prompt for a field
#

sub field_prompt
{ 
	my ($self, $ele) = @_;
	return $valid{$ele};
}

no strict;
sub AUTOLOAD
{
	my $self = shift;
	my $name = $AUTOLOAD;
	return if $name =~ /::DESTROY$/;
	$name =~ s/.*:://o;
  
	confess "Non-existant field '$AUTOLOAD'" if !$valid{$name};
	@_ ? $self->{$name} = shift : $self->{$name} ;
}

1;
