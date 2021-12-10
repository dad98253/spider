#
# print out the general log file
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#

sub handle
{
	my $self = shift;

	my $cmdline = shift;
	my @f = split /\s+/, $cmdline;
	my $f;
	my @out;
	my ($from, $to, $who, $hint); 
	
	$from = 0;
	while ($f = shift @f) {                 # next field
		#  print "f: $f list: ", join(',', @list), "\n";
		unless ($from || $to) {
			($from, $to) = $f =~ /^(\d+)-(\d+)$/o;         # is it a from -> to count?
			next if $from && $to > $from;
		}
		unless ($to) {
			($to) = $f =~ /^(\d+)$/ if !$to;              # is it a to count?
			next if $to;
		}
		unless ($f =~ /^\d+/) {
			$who = $f; 
			next if $who;
		}
	}

	$to = 20 unless $to;
	$from = 0 unless $from;
	
	if ($self->priv < 6) {
		return (1, $self->msg('e5')) if defined $who && $who ne $self->call;
		$who = $self->call;
	}

	return (1, DXLog::print($from, $to, $main::systime, undef, $who)) if $self->{_nospawn};
	return (1, $self->spawn_cmd("show/log $cmdline", \&DXLog::print, args => [$from, $to, $main::systime, undef, $who]));
}
