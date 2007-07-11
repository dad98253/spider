#
# show a Route::User thingy
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

my ($self, $line) = @_;
my @out;
my @list = split /\s+/, $line;		      # generate a list of callsigns
@list = ($self->call) if !@list;  # my channel if no callsigns
if ($self->priv > 5 && @list && uc $list[0] eq 'ALL') {
	push @out, "User Callsigns in Routing Table";
	@list = sort map {$_->call} Route::User::get_all();
	my $count = @list;
	my $n = int $self->width / 10;
	$n ||= 8;
	while (@list > $n) {
		push @out, join(' ', map {sprintf "%9s",$_ } splice(@list, 0, $n));
	} 
	push @out, join(' ', map {sprintf "%9s",$_ } @list) if @list;
	push @out, "$count Users";
	return (1, @out);
}

my $call;
foreach $call (@list) {
  $call = uc $call;
  my $ref = Route::User::get($call);
  if ($ref) {
    push @out, print_all_fields($self, $ref, "Route::User Information $call");
  } else {
    push @out, "Route::User: $call not found";
  }
  push @out, "" if @list > 1;
}

return (1, @out);
