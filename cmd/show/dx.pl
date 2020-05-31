#
# show dx (normal)
#
#
#

require 5.10.1;

sub handle
{
	my ($self, $line) = @_;
	my @list = split /\s+/, $line; # split the line up

	my @out;
	my $f;
	my $call = $self->call;
	my $usesql = $main::dbh && $Spot::use_db_for_search;
	my ($from, $to);
	my ($fromday, $today);
	my $exact;
	my $real;
	my $user;
	my $expr;
	my $dofilter;
	my $pre;
	my $dxcc;

	my @flist;

	while ($f = shift @list) {	# next field
		dbg "sh/dx arg: $f list: " . join(',', @list) if isdbg('sh/dx');
		if (!$from && !$to) {
			($from, $to) = $f =~ m|^(\d+)[-/](\d+)$|; # is it a from -> to count?
			dbg("sh/dx from: $from to: $to") if isdbg('sh/dx');
			next if $from && $to > $from;
		}
		if (!$to) {
			($to) = $f =~ /^(\d+)$/o if !$to; # is it a to count?
			dbg("sh/dx to: $to") if isdbg('sh/dx');
			next if $to;
		}
		if (lc $f eq 'day' && $list[0]) {
			($fromday, $today) = split m|[-/]|, shift(@list);
			dbg "sh/dx got day $fromday/$today" if isdbg('sh/dx');
			next;
		}
		if (lc $f eq 'exact') {
			dbg("sh/dx exact") if isdbg('sh/dx');
			$exact = 1;
			next;
		}
		if (lc $f eq 'rt' || $f =~ /^real/i) {
			dbg("sh/dx real") if isdbg('sh/dx');
			$real = 1;
			next;
		}
		if (lc $f =~ /^filt/) {
			dbg("sh/dx run spotfilter") if isdbg('sh/dx');
			$dofilter = 1 if $self && $self->spotsfilter;
			next;
		}
		if (lc $f eq 'qsl') {
			dbg("sh/dx qsl") if isdbg('sh/dx');
			push @flist, "info {QSL|VIA}";
			next;
		}
		if (lc $f eq 'iota') {
			my $doiota;
			if (@list && $list[0] && (($a, $b) = $list[0] =~ /(AF|AN|NA|SA|EU|AS|OC)-?(\d?\d\d)/oi)) {
				$a = uc $a;
				$doiota = "\\b$a\[\-\ \]\?$b\\b";
				shift @list;
			}
			$doiota = '\b(IOTA|(AF|AN|NA|SA|EU|AS|OC)[- ]?\d?\d\d)\b' unless $doiota;
			push @flist, "info {$doiota}";
			dbg("sh/dx iota") if isdbg('sh/dx');
			next;
		}
		if (lc $f eq 'qra') {
			my $doqra = uc shift @list if @list && $list[0] =~ /[A-Z][A-Z]\d\d/oi;
			$doqra = '\b([A-Z][A-Z]\d\d|[A-Z][A-Z]\d\d[A-Z][A-Z])\b' unless $doqra;
			push @flist, "info {$doqra}";
			dbg("sh/dx qra") if isdbg('sh/dx');
			next;
		}
		if (grep {lc $f eq $_} qw(zone byzone by_zone itu byitu by_itu state bystate by_state info on spotter by) ) {
			$f =~ s/^by(\w)/by_$1/;
			push @flist, $f;
			push @flist, shift @list if @list;
			next;
		}
		unless ($pre) {
			$pre = $f;
			next;
		}
		push @flist, $f;
	}

	
	if ($pre) {
		$pre .= '*' unless $pre =~ /[\*\?\[]$/o;
		$pre = shellregex($pre);
		if ($usesql) {
			$pre =~ s/\.\*/%/g;
		} else {
			$pre =~ s/\.\*\$$//;
		}
		$pre .= '$' if $exact;
		$pre =~ s/\^//;
		
		push @flist, 'call', $pre;
	}
	
    my $newline = join(' ', @flist);
	dbg("sh/dx newline: $newline") if isdbg('sh/dx');
	my ($r, $filter, $fno, $user, $expr) = $Spot::filterdef->parse($self, 'spots', $newline, 1);

	return (0, "sh/dx parse error '$r' " . $filter) if $r;
	
	dbg "sh/dx user: $user expr: $expr from: $from to: $to fromday: $fromday today: $today" if isdbg('sh/dx');
  
	# now do the search

	if ($self->{_nospawn}) {
		my @res = Spot::search($expr, $fromday, $today, $from, $to, $user, $dofilter ? $self : undef);
		my $ref;
		my @dx;
		foreach $ref (@res) {
			if ($self && $self->ve7cc) {
				push @out, VE7CC::dx_spot($self, @$ref);
			}
			else {
				if ($self && $real) {
					push @out, DXCommandmode::format_dx_spot($self, @$ref);
				}
				else {
					push @out, Spot::formatl(@$ref);
				}
			}
		}
	}
	else {
		push @out, $self->spawn_cmd("sh/dx $line", \&Spot::search, 
									args => [$expr, $fromday, $today, $from, $to, $filter, $dofilter ? $self : undef],
									cb => sub {
										my ($dxchan, @res) = @_; 
										my $ref;
										my @out;

										foreach $ref (@res) {
											if ($self->ve7cc) {
												push @out, VE7CC::dx_spot($self, @$ref);
											}
											else {
												if ($real) {
													push @out, DXCommandmode::format_dx_spot($self, @$ref);
												}
												else {
													push @out, Spot::formatl(@$ref);
												}
											}
										}
										push @out, $self->msg('e3', "sh/dx", "'$line'") unless @out;
										return @out;
									});
	}


	return (1, @out);
}


