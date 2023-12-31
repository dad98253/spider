#
# A module to allow a user to create and (eventually) edit arrays of
# text and attributes
#
# This is used for creating mail messages and user script files
#
# It may be sub-classed
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

package Editable;

use strict;

use DXChannel;
use DXDebug;
use BadWords;

sub new
{
	my $pkg = shift;
	my $class = ref $pkg || $pkg;
	
	return {@_}, $class; 
}

sub copy
{
	my $self = shift;
	return $self->new(%$self);
}

sub addline
{
	my $self = shift;
	my $dxchan = shift;
	my $line = shift;
	
	if (my @ans = BadWords::check($line)) {
		return ($dxchan->msg('e17', @ans));
	}
	push @{$self->{lines}}, $line;
	return ();
}

sub modline
{
	my $self = shift;
	my $dxchan = shift;
	my $no = shift;
	my $line = shift;

	if (my @ans = BadWords::check($line)) {
		return ($dxchan->msg('e17', @ans));
	}
    ${$self->{lines}}[$no] = $line;
	return ();
}

sub lines
{
	my $self = shift;
	return exists $self->{lines} ? (@{$self->{lines}}) : ();
}

sub nolines
{
	my $self = shift;
	return exists $self->{lines} ? scalar @{$self->{lines}} : 0;
}

1;
