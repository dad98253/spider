#
#
# These are various values used by the AK1A protocol stack
#
# Copy this file to /spider/local before use!
#
# Change these at your peril (or if you know what you are doing)!
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#

package DXProt;

# the interval between pc50s (in seconds)
$pc50_interval = 60*60;

# the version of DX cluster (tm) software I am masquerading as
$myprot_version = 5300;

# default hopcount to use
$def_hopcount = 30;

# some variable hop counts based on message type
%hopcount = (
  16 => 15,
  17 => 15,
  19 => 15,
  21 => 15,
);

# list of nodes we don't accept dx from
@nodx_node = (

);

# list of nodes we don't accept announces from
@noann_node = (

);

# list of node we don't accept wwvs from
@nowwv_node = (

);

# send out for/opernams for callsigns sending dx spots who haven't got qra locators
$send_opernam = 0;

1;
