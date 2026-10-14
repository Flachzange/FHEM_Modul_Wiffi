# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use lib 't/lib';

# Scoped to the loader dependency and local data flow. These stubs are NOT
# substitutes for FHEM integration tests of callbacks, events or lifecycle.
my $load_calls = 0;
sub LoadModule {
  my ($module) = @_;
  is($module, 'WIFFI_Collector', 'logical device requests collector module');
  $load_calls++;
  require './FHEM/00_WIFFI_Collector.pm';
  return $module;
}
sub readingsSingleUpdate {
  my ($hash, $key, $value, $trigger) = @_;
  $hash->{READINGS}{$key}{VAL} = $value;
}

require './FHEM/10_WIFFI_DEVICE.pm';
ok(!defined &WIFFI_Collector_NormalizeMac, 'collector helper not loaded initially');

my %device;
my $error = WIFFI_DEVICE_Define(\%device,
    'WIFFI_Test WIFFI_DEVICE WIFFI_TestCollector b4:e6:2d:17:db:7');
is($error, undef, 'device can be defined before collector exists');
is($load_calls, 1, 'collector code loaded exactly once');
is($device{COLLECTOR}, 'WIFFI_TestCollector', 'configured collector retained');
is($device{MAC}, 'B4:E6:2D:17:DB:07', 'shared MAC parser normalized value');
is($device{READINGS}{state}{VAL}, 'waiting', 'device waiting for messages');

my %second;
$error = WIFFI_DEVICE_Define(\%second,
    'WIFFI_Second WIFFI_DEVICE WIFFI_TestCollector DE:AD:BE:EF:FE:01');
is($error, undef, 'second device defines normally');
is($load_calls, 1, 'no redundant module load');

my %bad;
$error = WIFFI_DEVICE_Define(\%bad,
    'WIFFI_Bad WIFFI_DEVICE WIFFI_TestCollector badmac');
is($error, 'Invalid WIFFI MAC address', 'invalid MAC rejected');

my %extra;
$error = WIFFI_DEVICE_Define(\%extra,
  'WIFFI_Extra WIFFI_DEVICE WIFFI_TestCollector B4:E6:2D:17:DB:07 ignored');
is($error,
  'Usage: define <name> WIFFI_DEVICE <collector-name> <mac-address>',
  'device refuses surplus definition parameters');
ok(!exists $extra{MAC},'invalid surplus definition does not initialize identity');

done_testing();
