#
# set user type to 'S' for Spider node
#
# Please note that this is only effective if the user is not on-line
#
# Copyright (c) 1998 - Dirk Koopman
#
# $Id$
#

my ($self, $line) = @_;
my @args = split /\s+/, $line;
my $call;
my @out;
my $user;
my $create;

return (1, $self->msg('e5')) if $self->priv < 5;

foreach $call (@args) {
	$call = uc $call;
	my $chan = DXChannel->get($call);
	if ($chan) {
		push @out, $self->msg('nodee1', $call);
	} else {
		$user = DXUser->get($call);
		$create = !$user;
		$user = DXUser->new($call) if $create;
		if ($user) {
			$user->sort('S');
			$user->homenode($call);
			$user->priv(1) unless $user->priv;
			$user->close();
			push @out, $self->msg($create ? 'nodesc' : 'nodes', $call);
		} else {
			push @out, $self->msg('e3', "Set Spider", $call);
		}
	}
}
return (1, @out);










