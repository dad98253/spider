#
# User routing routines
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
# $Id$
# 

package Route::User;

use DXDebug;
use Route;

use strict;

use vars qw($VERSION $BRANCH);
$VERSION = sprintf( "%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/ );
$BRANCH = sprintf( "%d.%03d", q$Revision$ =~ /\d+\.\d+\.(\d+)\.(\d+)/  || (0,0));
$main::build += $VERSION;
$main::branch += $BRANCH;

use vars qw(%list %valid @ISA $max $filterdef);
@ISA = qw(Route);

%valid = (
		  links => '0,Parent Calls,parray',
);

$filterdef = $Route::filterdef;
%list = ();
$max = 0;

sub count
{
	my $n = scalar(keys %list);
	$max = $n if $n > $max;
	return $n;
}

sub max
{
	count();
	return $max;
}

sub new
{
	my $pkg = shift;
	my $call = uc shift;
	my $ncall = uc shift;
	my $flags = shift;
	confess "already have $call in $pkg" if $list{$call};
	
	my $self = $pkg->SUPER::new($call);
	$self->{links} = [ $ncall ];
	$self->{flags} = $flags;
	$list{$call} = $self;

	return $self;
}

sub get_all
{
	return values %list;
}

sub del
{
	my $self = shift;
	my $pref = shift;
	$self->delparent($pref);
	unless (@{$self->{links}}) {
		delete $list{$self->{call}};
		return $self;
	}
	return undef;
}

sub get
{
	my $call = shift;
	$call = shift if ref $call;
	my $ref = $list{uc $call};
	dbg("Failed to get User $call" ) if !$ref && isdbg('routerr');
	return $ref;
}

sub addparent
{
	goto &Route::_addlink;
}

sub delparent
{
	goto &Route::_dellink;
}

sub parents
{
	my $self = shift;
	return @{$self->{links}};
}

#
# generic AUTOLOAD for accessors
#

sub AUTOLOAD
{
	no strict;
	my ($pkg,$name) = $AUTOLOAD =~ /^(.*)::(\w+)$/;
	return if $name eq 'DESTROY';
  
	confess "Non-existant field '$AUTOLOAD'" unless $valid{$name} || $Route::valid{$name};

	# this clever line of code creates a subroutine which takes over from autoload
	# from OO Perl - Conway
	*$AUTOLOAD = sub {$_[0]->{$name} = $_[1] if @_ > 1; return $_[0]->{$name}};
	goto &$AUTOLOAD;	
#	*{"${pkg}::$name"} = sub {$_[0]->{$name} = $_[1] if @_ > 1; return $_[0]->{$name}};
#	goto &{"${pkg}::$name"};	
}

1;
