#
# catchup some or all of the non-private messages for a node.
#
# in other words mark all messages as being already received
# by this node.
#
# $Id$
#
# Copyright (c) 1999 Dirk Koopman G1TLH
#

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->priv < 9;

my @f = split /\s+/, $line;
return (1, "usage: catchup <node call> all|[<msgno ...]") unless @f >= 2;

my $call = uc shift @f;
my $user = DXUser->get_current($call);
return (1, "$call not a node") unless $user && $user->sort ne 'U';

my @out;
my $ref;
my @ref;

# get a more or less valid set of messages
foreach my $msgno (@f) {
	if ($msgno =~ /^al/oi) {
		@ref = DXMsg::get_all();
		last;
	}
	$ref = DXMsg::get($msgno);
	unless ($ref) {
		push @out, $self->msg('m13', $msgno);
		next;
	}
	push @ref, $ref;
}

foreach $ref (@ref) {
	next if $ref->{private};
	if (grep {$_ eq $call} @{$ref->{gotit}}) {
		$ref->{gotit} = [ grep {$_ ne $call} @{$ref->{gotit}} ]; # mark this up as NOT being received
		$ref->store( [ $ref->read_msg_body() ] );	# re- store the file
		push @out, $self->msg('m15', $ref->{msgno}, $call);
	}
}

return (1, @out);
		
