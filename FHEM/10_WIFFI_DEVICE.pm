# SPDX-License-Identifier: GPL-2.0-or-later
# Logical FHEM device for one WIFFI sensor
package main;
use strict;
use warnings;
use vars qw($readingFnAttributes);

sub WIFFI_DEVICE_Initialize {
  my ($hash) = @_;
  $hash->{DefFn} = 'WIFFI_DEVICE_Define';
  $hash->{UndefFn} = 'WIFFI_DEVICE_Undef';
  $hash->{AttrList} = $readingFnAttributes;
}

sub WIFFI_DEVICE_Define {
  my ($hash, $def) = @_;
  my ($name, $type, $collector, $mac) = split /\s+/, $def;
  return 'Usage: define <name> WIFFI_DEVICE <collector-name> <mac-address>'
    unless defined $collector && defined $mac;
  # A WIFFI_DEVICE may be restored before the collector. Load its shared
  # parser without creating a listener or requiring a defined collector.
  if (!defined &WIFFI_Collector_NormalizeMac) {
    my $loaded = LoadModule('WIFFI_Collector');
    return 'Cannot load WIFFI_Collector'
      if !defined $loaded || $loaded eq 'UNDEFINED'
        || !defined &WIFFI_Collector_NormalizeMac;
  }
  my $normalized = WIFFI_Collector_NormalizeMac($mac);
  return 'Invalid WIFFI MAC address' unless $normalized;
  $hash->{COLLECTOR} = $collector;
  $hash->{MAC} = $normalized;
  readingsSingleUpdate($hash, 'state', 'waiting', 0);
  return undef;
}

sub WIFFI_DEVICE_Undef { return undef; }

sub WIFFI_DEVICE_Process {
  my ($hash, $data, $peer) = @_;
  $hash->{PEER} = $peer;
  $hash->{MODULTYP} = $data->{modultyp};
  readingsBeginUpdate($hash);
  for my $reading (sort keys %{$data->{readings}}) {
    readingsBulkUpdate($hash, $reading, $data->{readings}{$reading});
  }
  readingsBulkUpdate($hash, 'state', 'online');
  readingsEndUpdate($hash, 1);
}
1;
