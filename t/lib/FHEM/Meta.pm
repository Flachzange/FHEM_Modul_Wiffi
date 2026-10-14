# Minimal contract double for isolated Perl tests. This deliberately does
# not emulate real FHEM metadata parsing or the FVERSION lifecycle.
package FHEM::Meta;
use strict;
use warnings;
sub InitMod { return undef }
sub SetInternals { return 1 }
1;
