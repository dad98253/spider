#
# set/hops commands
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
# $Id$
#
my ($self, $line) = @_;
return (0, $self->msg('e5')) if $self->priv < 8;

my @f = split /\s+/, $line;
my @out;
my $call;

if (is_callsign(uc $f[0])) {
	$call = uc shift @f;
} elsif ($f[0] eq 'node_default' || $f[0] eq 'user_default') {
	$call = shift @f;
}

my $sort = lc shift @f if $f[0] =~ /^ann|spots|wwv|wcy$/i;
my $hops = shift @f if $f[0] =~ /^\d+$/;

return (0, $self->msg('sethop1')) unless $call && $sort && $hops;

my $ref = Filter::read_in($sort, $call, 0);
$ref = Filter->new($sort, $call, 0) if !$ref || $ref->isa('Filter::Old');
return (0, $self->msg('filter5', '', $sort, $call)) unless $ref;

delete $ref->{hops};
$ref->{hops} = $hops if $hops;
$ref->write;
$ref->install;

return (0, $self->msg('sethop2', $hops, '', $sort, $call));
