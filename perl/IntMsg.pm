#
# This class is the internal subclass that deals with the internal port 27754
# communications for Msg.pm
#
# $Id$
#
# Copyright (c) 2001 - Dirk Koopman G1TLH
#

package IntMsg;

use strict;

use vars qw($VERSION $BRANCH);
$VERSION = sprintf( "%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/ );
$BRANCH = sprintf( "%d.%03d", q$Revision$ =~ /\d+\.\d+\.(\d+)\.(\d+)/ ) || 0;
$main::build += $VERSION;
$main::branch += $BRANCH;

use Msg;

use vars qw(@ISA);

@ISA = qw(Msg);

sub enqueue
{
	my ($conn, $msg) = @_;
	$msg =~ s/([\%\x00-\x1f\x7f-\xff])/sprintf("%%%02X", ord($1))/eg; 
    push (@{$conn->{outqueue}}, $msg . "\n");
}

sub dequeue
{
	my $conn = shift;

	if ($conn && $conn->{msg} =~ /\cJ/) {
		my @lines =  $conn->{msg} =~ /([^\cM\cJ]*)\cM?\cJ/g;
		if ($conn->{msg} =~ /\cJ$/) {
			delete $conn->{msg};
		} else {
			$conn->{msg} =~ s/([^\cM\cJ]*)\cM?\cJ//g;
		}
		for (@lines) {
			if (defined $_) {
				s/\%([0-9A-F][0-9A-F])/chr(hex($1))/eg;
				s/[\x00-\x08\x0a-\x19\x1b-\x1f\x80-\x9f]/./g;         # immutable CSI sequence + control characters
			} else {
				$_ = '';
			}
			&{$conn->{rproc}}($conn, $_) if exists $conn->{rproc};
		}
	}
}

