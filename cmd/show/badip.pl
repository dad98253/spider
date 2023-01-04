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
my $maxlth = 0;

#$DB::single = 1;


my @list = map {my $s = $_; $s =~ s|/32$||; $maxlth = length $s if length $s > $maxlth; $s =~ /^1$/?undef:$s} DXCIDR::list();
my @l;
$maxlth //= 20;
my $n = int (80/($maxlth+1));
my $format = "\%-${maxlth}s " x $n;
chop $format;

foreach my $list (@list) {
	if (@in) {
		for (@in) {
			if ($list =~ /$_/i) {
				push @out, $list;
				last;
			}
		}
	} else {
		if (@l > $n) {
			push @out, sprintf $format, @l;
			@l = ();
		}
		push @l, $list;
	}
}	
unless (@in) {
	push @l, "" while @l < $n;
	push @out, sprintf $format, @l;
}

push @out, "show/badip: " . scalar @list . " records found";
return (1, @out);
