# Small FHEM::Meta contract double used by isolated Perl tests.
# Real FHEM may omit x_version for a non-SVN module even when version exists.
package FHEM::Meta;
use strict;
use warnings;
use version ();
sub InitMod { return undef }
sub SetInternals { return 1 }
sub Get {
  return '0.002001' if $_[1] eq 'version'; # normalized v0.2.1 from META.json
  return undef;
}
1;
