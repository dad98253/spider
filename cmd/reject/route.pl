#
# accept/reject filter commands
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
#
#

my ($self, $line) = @_;
my $type = 'reject';
my $sort  = 'route';

my ($r, $filter, $fno) = $Route::filterdef->cmd($self, $sort, $type, $line);
my $ok = $r ? 0 : 1;
return ($ok, $r ? $filter : $self->msg('filter1', $fno, $filter->{name})); 
