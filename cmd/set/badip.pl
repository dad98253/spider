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
my $suffix = 'local';
if ($in[0] =~ /^[_\d\w]+$/) {
	$suffix = shift @in;
}
return (1, "set/badip: need [suffix (def: local])] IP, IP-IP or IP/24") unless @in;
for my $ip (@in) {
	my $r;
	eval{ $r = DXCIDR::find($ip); };
	return (1, "set/badip: $ip $@") if $@;
	if ($r) {
		push @out, "set/badip: $ip exists, not added";
		next;
	}
	DXCIDR::add($suffix, $ip);
	push @added, $ip;
}
my $count = @added;
my $list = join ' ', @in;
DXCIDR::clean_prep();
#$DB::single = 1;
DXCIDR::append($suffix, @added);
push @out, "set/badip: added $count entries to badip.$suffix : $list" if $count;
return (1, @out);
