#
# restart an agw connection
#
# $Id$
#
my $self = shift;
return (1, $self->msg('e5')) if $self->priv < 5;
main::AGWrestart();
return (1, $self->msg('done'));
