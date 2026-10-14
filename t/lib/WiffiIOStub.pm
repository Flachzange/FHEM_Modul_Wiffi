# SPDX-License-Identifier: GPL-2.0-or-later
# Scoped WIFFI double of fhem.pl fhem_setIoDev/AssignIoPort, inspected
# 2026-10-14 (blob 4430a7967aa318c310535082852f77d4ca3482f8).
# Models binding, IODev value/time, disabled-provider fallback and deferred
# startup. Does not model global client-array dispatch or configDB storage.
package main;
use strict;
use warnings;
our (%defs, $init_done);

sub fhem_setIoDev {
  my ($hash, $name) = @_;
  if (!$name || !$defs{$name}) {
    if (!$init_done) {
      $hash->{IODevMissing} = 1;
      $hash->{IODevName} = $name;
    }
    return "unknown IODev " . ($name // '') . " specified";
  }
  my $configured = AttrVal($hash->{NAME}, 'IODev', '');
  return "$hash->{NAME}: not setting IODev to $name, as different attr exists"
    if $configured && $configured ne $name;
  $hash->{IODev} = $defs{$name};
  $hash->{READINGS}{IODev} = {VAL => $name, TIME => TimeNow()};
  delete $defs{$name}{'.clientArray'};
  delete @{$hash}{qw(IODevMissing IODevName)};
  return undef;
}

sub AssignIoPort {
  my ($hash, $preferred) = @_;
  $preferred ||= AttrVal($hash->{NAME}, 'IODev', undef);
  $preferred ||= $hash->{READINGS}{IODev}{VAL}
    if !$preferred && $hash->{READINGS};
  if ($preferred && $defs{$preferred}
      && AttrVal($preferred, 'disable', 0) ne '1') {
    fhem_setIoDev($hash, $preferred);
  } else {
    # Real FHEM selects the LAST defined compatible provider, even if an
    # explicitly proposed provider exists but is disabled.
    for my $name (sort { ($defs{$b}{NR} // 0) <=> ($defs{$a}{NR} // 0) } keys %defs) {
      next unless ($defs{$name}{TYPE} // '') eq 'WIFFI_Collector';
      next if $defs{$name}{TEMPORARY} || defined $defs{$name}{SNAME};
      next if AttrVal($name, 'disable', 0) eq '1';
      fhem_setIoDev($hash, $name);
      last;
    }
  }
  $hash->{IODevMissing} = 1 if !$hash->{IODev} && !$init_done;
  return undef;
}

1;
