# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 't/lib';

# Synchronous FHEM reading/event double; no live TCP or real FHEM involved.
our (%defs, %attr, $readingFnAttributes);
$readingFnAttributes = '';
my $now = '2026-10-14 15:00:01';
my @published;
sub TimeNow { return $now }
sub AttrVal {
  my ($name, $key, $fallback) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $fallback;
}
sub Log3 {}
sub readingsSingleUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
sub readingsBeginUpdate {}
sub readingsBulkUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
sub readingsEndUpdate {
  my ($hash) = @_;
  push @published, [$defs{Collector}{LAST_TELEGRAM}, $hash->{LAST_TELEGRAM}];
}
require './FHEM/00_WIFFI_Collector.pm';
require './FHEM/10_WIFFI_DEVICE.pm';

my $collector = {NAME=>'Collector', TYPE=>'WIFFI_Collector', FRAMES_ERROR=>0,
  FRAMES_OK=>0, FRAMES_UNKNOWN=>0};
$defs{Collector} = $collector;
my $one = {NAME=>'One',TYPE=>'WIFFI_DEVICE',COLLECTOR=>'Collector',
  MAC=>'02:00:00:00:00:01'};
my $two = {NAME=>'Two',TYPE=>'WIFFI_DEVICE',COLLECTOR=>'Collector',
  MAC=>'02:00:00:00:00:02'};
$defs{One} = $one;
$defs{Two} = $two;
sub telegram {
  my ($mac, $value) = @_;
  return JSON::PP::encode_json({
    modultyp=>'PULSECOUNTER',
    vars=>[{homematic_name=>'w_counter1',value=>$value}],
    Systeminfo=>{'MAC-Adresse'=>$mac}
  });
}
my $msg_one = telegram('02:00:00:00:00:01', '1.000');
my $msg_two = telegram('02:00:00:00:00:02', '2.000');
ok(!exists $collector->{LAST_TELEGRAM} && !exists $one->{LAST_TELEGRAM},
  'before first telegram, no last-telegram timestamp exists');
WIFFI_Collector_ProcessFrame($collector, $msg_one, '192.0.2.1');
is($collector->{LAST_TELEGRAM}, $now, 'collector records first valid telegram');
is($one->{LAST_TELEGRAM}, $now, 'device records assigned valid telegram');
ok(!exists $two->{LAST_TELEGRAM}, 'unseen device has no invented timestamp');
is_deeply($published[0], [$now,$now],
  'timestamps are set before synchronous reading/event publication');

$now = '2026-10-14 15:00:02';
WIFFI_Collector_ProcessFrame($collector, $msg_one, '192.0.2.1');
is($one->{LAST_TELEGRAM}, $now, 'identical sensor value still updates last telegram');
is($one->{READINGS}{w_counter1}{VAL}, '1.000', 'sensor value remains unchanged');

$now = '2026-10-14 15:00:03';
WIFFI_Collector_ProcessFrame($collector, $msg_two, '192.0.2.2');
is($two->{LAST_TELEGRAM}, $now, 'second device has its own receive time');
is($one->{LAST_TELEGRAM}, '2026-10-14 15:00:02',
  'second device telegram does not update first device');

$now = '2026-10-14 15:00:04';
WIFFI_Collector_ProcessFrame($collector, telegram('02:00:00:00:00:03','3'), '192.0.2.3');
is($collector->{LAST_TELEGRAM}, $now, 'valid unknown MAC still advances collector');
ok(!exists $two->{READINGS}{LAST_TELEGRAM} && !exists $one->{READINGS}{LAST_TELEGRAM},
  'timestamps are INTERNALS, not readings');

$now = '2026-10-14 15:00:05';
WIFFI_Collector_ProcessFrame($collector, '{not json', '192.0.2.1');
is($collector->{LAST_TELEGRAM}, '2026-10-14 15:00:04',
  'malformed JSON does not update collector time');
is($one->{LAST_TELEGRAM}, '2026-10-14 15:00:02',
  'malformed JSON does not update device time');

WIFFI_Collector_ProcessFrame($collector, $msg_one, '192.0.2.9');
is($collector->{LAST_TELEGRAM}, '2026-10-14 15:00:04',
  'identity mismatch is rejected without moving collector time');

$attr{One}{disable} = 1;
WIFFI_Collector_ProcessFrame($collector, $msg_one, '192.0.2.1');
is($collector->{LAST_TELEGRAM}, $now,
  'collector still receives valid telegram from a disabled logical device');
is($one->{LAST_TELEGRAM}, '2026-10-14 15:00:02',
  'disabled device does not update its timestamp');
is($collector->{FRAMES_OK}, 3,
  'only three published known-device frames counted as FRAMES_OK');

done_testing();
