#
# set the qra locator field
#
# Copyright (c) 1998 - Dirk Koopman
#
# $Id$
#

my ($self, $line) = @_;
my $call = $self->call;
my $user;

# remove leading and trailing spaces
$line =~ s/^\s+//;
$line =~ s/\s+$//;

return (1, $self->msg('qrae1')) if !$line;
return (1, $self->msg('qrae2', $line)) unless DXBearing::is_qra($line);

$user = DXUser->get_current($call);
if ($user) {
	$line = uc $line;
	$user->qra($line);
	if (!$user->lat && !$user->long) {
		my ($lat, $long) = DXBearing::qratoll($line);
		$user->lat($lat);
		$user->long($long);
		my $s = DXBearing::lltos($lat, $long);
		my $l = DXProt::pc41($call, 3, $s);
		DXProt::eph_dup($l);
		DXProt::broadcast_all_ak1a($l, $DXProt::me) ;
	}
	
	$user->put();
	return (1, $self->msg('qra', $line));
} else {
	return (1, $self->msg('namee2', $call));
}

