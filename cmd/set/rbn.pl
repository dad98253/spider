#
# set user type to 'S' for Spider node
#
# Please note that this is only effective if the user is not on-line
#
# Copyright (c) 1998 - Dirk Koopman
#
#
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
	if ($call eq $main::myalias) {
		push @out, $self->msg('e11', $call);
		next;
	}
	if ($call eq $main::myalias) {
		push @out, $self->msg('e11', $call);
		next;
	}
	my $chan = DXChannel::get($call);
	if ($chan) {
		push @out, $self->msg('nodee1', $call);
	} else {
		$user = DXUser::get($call);
		$create = !$user;
		$user = DXUser->new($call) if $create;
		if ($user) {
			$user->sort('N');
			$user->homenode($main::mycall);
			$user->lockout(0);
			$user->priv(0) unless $user->priv;
			$user->close();
			push @out, $self->msg($create ? 'nodenc' : 'noden', $call);
		} else {
			push @out, $self->msg('e3', "Set RBN", $call);
		}
	}
}
return (1, @out);










