#
# accept/reject filter commands
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
# $Id$
#

my ($self, $line) = @_;
my $type = 'accept';
my $sort  = 'route';

my ($r, $filter, $fno) = $Route::filterdef->cmd($self, $sort, $type, $line);
return (1, $r ? $filter : $self->msg('filter1', $fno, $filter->{name})); 
