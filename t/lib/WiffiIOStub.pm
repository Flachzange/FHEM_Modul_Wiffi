# SPDX-License-Identifier: GPL-2.0-or-later
# Minimal stand-in for FHEM's AssignIoPort/fhem_setIoDev contract.
# The actual FHEM API additionally manages Clients and IODev reading time.
package main;
use strict;
use warnings;
our (%defs, $init_done);

sub AssignIoPort {
  my ($hash, $preferred) = @_;
  $preferred ||= AttrVal($hash->{NAME}, 'IODev', undef);
  $preferred ||= $hash->{READINGS}{IODev}{VAL}
    if !$preferred && $hash->{READINGS};
  if (!$preferred) {
    my @candidates = grep {
      ($defs{$_}{TYPE} // '') eq 'WIFFI_Collector'
        && !defined $defs{$_}{SNAME}
    } keys %defs;
    $preferred = $candidates[-1] if @candidates == 1;
  }
  if ($preferred && $defs{$preferred}) {
    $hash->{IODev} = $defs{$preferred};
    $hash->{READINGS}{IODev}{VAL} = $preferred;
    delete @{$hash}{qw(IODevMissing IODevName)};
  } else {
    $hash->{IODevMissing} = 1 unless $init_done;
    $hash->{IODevName} = $preferred if $preferred && !$init_done;
  }
  return undef;
}

1;
