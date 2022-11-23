#
# show list of bad dx callsigns
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;
my @out;
my @l;
my $count = 0;

if ($line =~ /^\s*full/i) {
	foreach my $w (BadWords::list_regex(1)) {
		++$count;
		push @out, $w; 
	}
}
else {
	foreach my $w (BadWords::list_regex()) {
		++$count;
		if (@l >= 5) {
			push @out, sprintf "%-12s %-12s %-12s %-12s %-12s", @l;
			@l = ();
		}
		push @l, $w;
	}
	push @l, "" while @l < 5;
	push @out, sprintf "%-12s %-12s %-12s %-12s %-12s", @l;
}

push @out, "$count BadWords";
	
return (1, @out);

