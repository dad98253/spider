#
# accept/reject filter commands
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
#
#

my ($self, $line) = @_;
my $type = 'accept';
my $sort  = 'spots';

my ($r, $filter, $fno) = $Spot::filterdef->cmd($self, $sort, $type, $line);
return (1, $r ? $filter : $self->msg('filter1', $fno, $filter->{name})); 
