#
# set the want PC90 flag
#
# Copyright (c) 2002 - Dirk Koopman
#
# $Id$
#

my ($self, $line) = @_;
my @args = split /\s+/, uc $line;
my $call;
my @out;

return (1, $self->msg('e5')) if $self->priv < 9;

foreach $call (@args) {
	return (1, $self->msg('e12')) unless is_callsign($call);

	my $user = DXUser->get_current($call);
	if ($user) {
		$user->wantpc90(1);
		$user->put;
		push @out, $self->msg('wpc90s', $call);
	} else {
		push @out, $self->msg('e3', "set/wantpc90", $call);
	}
}
return (1, @out);