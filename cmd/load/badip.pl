#
# load list of bad dx nodes
#
# Copyright (c) 2023 - Dirk Koopman G1TLH
#
#
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;

my @out;

my $count = 0;
eval{ $count += DXCIDR::reload(); };
return (1, "load/badip: $_ $@") if $@;

push @out, "load/badip: added $count entries";
return (1, @out);
