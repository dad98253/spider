#
# Copy this file to /spider/local and modify it to your requirements
#
#
# This file specifies which local interfaces and ports you will be
# listening on
#
# You can add as many as you like
#

package main;

use vars qw(@listen);

@listen = (
# remove the '#' character from the next line to enable the listener!
  #		   ["0.0.0.0", 7300],     # IPV4 only
# ^
# |
# 		   
# OR (IF you listen on IPV6 as well) This one!!!!!
  #		   ["::", 7300],     # IPV4 and IPV6
# ^
# |
# This one!!!!!
);

$
1;
