#
# show the distance and bearing to a  QRA locator
#
# you can enter two qra locators and it will calc the distance between them
#
# $Id$
#

my ($self, $line) = @_;
my @list = split /\s+/, $line;		      # generate a list of callsigns

my @out;
my $fll;
my $tll;
my $lat = $self->user->lat;
my $long = $self->user->long;
if (!$long && !$lat) {
	push @out, $self->msg('heade1');
	$lat = $main::mylatitude;
	$long = $main::mylongitude;
}

my $fqra = DXBearing::is_qra($list[0]);
my $sqra = $list[0] =~ /^[A-Za-z][A-Za-z]\d\d$/;
my $ll = $line =~ /^\d+\s+\d+\s*[NSns]\s+\d+\s+\d+\s*[EWew]/;
return (1, $self->msg('qrashe1')) unless @list > 0;
return (1, $self->msg('qrae2', $list[0])) unless $fqra || $sqra || $ll;

if ($ll) {
	my ($llat, $llong) = DXBearing::stoll($line);
	return (1, "QRA $line = " . DXBearing::lltoqra($llat, $llong)); 
}

#print "$lat $long\n";

my $l = uc $list[0];
my $f;

if (@list > 1) {
	$f = $l;
	$f .= 'MM' if $f =~ /^[A-Z][A-Z]\d\d$/;
	($lat, $long) = DXBearing::qratoll($f);
	$fll = DXBearing::lltos($lat, $long);
    #print "$lat $long\n";
	
	return (1, $self->msg('qrae2', $list[1])) unless (DXBearing::is_qra($list[1]) || $list[1] =~ /^[A-Za-z][A-Za-z]\d\d$/);
	$l = uc $list[1];
}

$l .= 'MM' if $l =~ /^[A-Z][A-Z]\d\d$/;
		
my ($qlat, $qlong) = DXBearing::qratoll($l);
#print "$qlat $qlong\n";
$fll = DXBearing::lltos($lat, $long);
$fll =~ s/\s+([NSEW])/$1/g;
$tll = DXBearing::lltos($qlat, $qlong);
$tll =~ s/\s+([NSEW])/$1/g;

my ($b, $dx) = DXBearing::bdist($lat, $long, $qlat, $qlong);
my ($r, $rdx) = DXBearing::bdist($qlat, $qlong, $lat, $long);
my $to = '';

$to = "->\U$list[1]($tll)" if $f;
my $from = "\U$list[0]($fll)" ;

push @out, sprintf "$from$to To: %.0f Fr: %.0f Dst: %.0fMi %.0fKm", $b, $r, $dx * 0.62133785, $dx;

return (1, @out);
