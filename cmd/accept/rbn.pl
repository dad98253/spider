#
# accept/reject filter commands
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
#
#

my ($self, $line) = @_;
my $type = 'accept';
my $sort  = 'rbn';

my ($r, $filter, $fno) = $RBN::filterdef->cmd($self, $sort, $type, $line);
my $ok = $r ? 0 : 1;
return ($ok, $r ? $filter : $self->msg('filter1', $fno, $filter->{name})); 
