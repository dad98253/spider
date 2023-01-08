#
# set list of bad dx nodes
#
# Copyright (c) 2021 - Dirk Koopman G1TLH
#
#
#
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;
my @out;
my @added;
my @in = split /\s+/, $line;
return (1, "set/badip: need IP, IP-IP or IP/24") unless @in;
for my $ip (@in) {
	my $r;
	eval{ $r = DXCIDR::find($ip); };
	return (1, "set/badip: $ip $@") if $@;
	if ($r) {
		push @out, "set/badip: $ip exists, not added";
		next;
	}
	DXCIDR::add($ip);
	push @added, $ip;
}
my $count = @added;
my $list = join ' ', @in;
DXCIDR::clean_prep();
DXCIDR::save();
push @out, "set/badip: added $count entries: $list" if $count;
return (1, @out);
