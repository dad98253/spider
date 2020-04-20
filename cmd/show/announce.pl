#
# print out the general log file for announces only
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#
my $self = shift;

# this appears to be a reasonable thing for users to do (thank you JE1SGH)
# return (1, $self->msg('e5')) if $self->priv < 9;

my $cmdline = shift;
my @f = split /\s+/, $cmdline;
my $f;
my @out;
my ($from, $to, $who); 

$from = 0;
while ($f = shift @f) {                 # next field
	#  print "f: $f list: ", join(',', @list), "\n";
	if (!$from && !$to) {
		($from, $to) = $f =~ /^(\d+)-(\d+)$/o;         # is it a from -> to count?
		next if $from && $to > $from;
	}
	if (!$to) {
		($to) = $f =~ /^(\d+)$/o if !$to;              # is it a to count?
		next if $to;
	}
	next if $who;
	#($who) = $f =~ /^(\w+)/o;
}

$to = 20 unless $to;
$from = 0 unless $from;

return (1, DXLog::print($from, $to, $main::systime, 'ann', $who)) if $self->{_nospawn};;
return (1, $self->spawn_cmd("show/announce $cmdline", \&DXLog::print, args => [$from, $to, $main::systime, 'ann', $who]));
	
return (1, @out);
