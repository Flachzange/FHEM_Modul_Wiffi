# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use lib 't/lib';
our (%defs, @calls, @closed, @logs, $throw_http);
sub HttpUtils_NonblockingGet {
  my ($param) = @_;
  die "synthetic HTTP initiation failure" if $throw_http;
  push @calls, $param;
}
sub HttpUtils_Close { push @closed, $_[0] }
sub Log3 { push @logs, $_[2] }
sub readingsSingleUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
require './FHEM/00_WIFFI_Collector.pm';
require './FHEM/10_WIFFI_DEVICE.pm';

sub init {
  %defs = ();
  @calls = ();
  @closed = ();
  @logs = ();
  $throw_http = 0;
  $defs{Collector} = { NAME=>'Collector', TYPE=>'WIFFI_Collector' };
  my $d = {
    NAME => 'Pump',
    TYPE => 'WIFFI_DEVICE',
    COLLECTOR => 'Collector',
    MAC => '02:00:00:00:00:01',
    MODULTYP => 'wiffi-pump',
    PEER => '192.0.2.21',
    READINGS => { wiffi_pump => { VAL => 'false' } },
  };
  $defs{Pump} = $d;
  return $d;
}
my %module;
WIFFI_DEVICE_Initialize(\%module);
is($module{SetFn}, 'WIFFI_DEVICE_Set', 'SetFn registered on logical devices');

my $device = init();
my $err = WIFFI_DEVICE_Set($device, 'Pump', 'on');
is($err, undef, 'on dispatched asynchronously');
is(scalar @calls, 1, 'single nonblocking HTTP request');
is($calls[0]{url}, 'http://192.0.2.21/?trigger:on:', 'on uses documented WIFFI command');
is($calls[0]{method}, 'GET', 'uses HTTP GET');
is($calls[0]{timeout}, 5, 'HTTP request bounded by timeout');
is($device->{READINGS}{wiffi_pump}{VAL}, 'false',
   'set does not optimistically change the reported pump state');
like(WIFFI_DEVICE_Set($device,'Pump','off'), qr/pending/, 'reject concurrent commands');
is(scalar @calls, 1, 'busy request does not enqueue another command');

$calls[0]{code} = 200;
$calls[0]{callback}->($calls[0], '', 'ok');
ok(!exists $device->{'.WIFFI_HTTP'}, 'callback clears inflight state');
is($device->{READINGS}{wiffi_pump}{VAL}, 'false',
   'HTTP 200 is not interpreted as pump state confirmation');

$err = WIFFI_DEVICE_Set($device, 'Pump', 'off');
is($err, undef, 'off accepted');
is($calls[1]{url}, 'http://192.0.2.21/?trigger:off:', 'off uses documented command');
$calls[1]{code} = 404;
$calls[1]{callback}->($calls[1], '', '');
like(join(' ',@logs), qr/HTTP status 404/, 'HTTP response failure logged');
ok(!exists $device->{'.WIFFI_HTTP'}, 'failed HTTP response releases busy state');

$err = WIFFI_DEVICE_Set($device, 'Pump', 'on-for-timer', 300);
is($err, undef, 'timed pump command accepted');
is($calls[2]{url}, 'http://192.0.2.21/?trigger:300:', 'timed manufacturer command');
$calls[2]{callback}->($calls[2], 'timeout', '');
like(join(' ',@logs), qr/timeout/, 'transport errors logged');
ok(!exists $device->{'.WIFFI_HTTP'}, 'timeout releases busy state');

for my $bad ('0','3601','-1','1.5','oops','10;shutdown','001','999999') {
  like(WIFFI_DEVICE_Set($device,'Pump','on-for-timer',$bad),qr/Usage/,
    "reject invalid duration $bad");
}
is(scalar @calls, 3, 'invalid duration never causes HTTP call');
like(WIFFI_DEVICE_Set($device,'Pump','on-for-timer'),qr/Usage/,
  'missing duration is rejected');
like(WIFFI_DEVICE_Set($device,'Pump','on','extra'),qr/Usage/,
  'extra arguments rejected');
like(WIFFI_DEVICE_Set($device,'Pump','reset'),qr/Unknown argument/,
  'undocumented command unavailable');

$device->{PEER} = 'http://192.0.2.21:3000/';
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/No valid WIFFI TCP peer/,
  'HTTP URL input injection rejected');
$device->{PEER} = '127.0.0.1';
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/No valid WIFFI TCP peer/,
  'loopback cannot be used as an actuator target');
$device->{PEER} = '192.0.2.21';
delete $device->{PEER};
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/fresh telegram/,
  'no command before fresh TCP sender identification');
$device->{PEER} = '192.0.2.21';

delete $defs{Collector};
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/collector is not defined/,
  'no command with missing associated collector');
$defs{Collector} = { NAME=>'Collector', TYPE=>'WIFFI_Collector' };
$device->{MODULTYP} = 'WEATHERMAN';
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/No set commands/,
  'no pump commands on other WIFFI types');
$device->{MODULTYP} = 'wiffi-pump';

$throw_http = 1;
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/Failed to send/,
  'synchronous HTTP initiation failure handled');
ok(!exists $device->{'.WIFFI_HTTP'}, 'failed send leaves no busy state');
$throw_http = 0;

$err = WIFFI_DEVICE_Set($device,'Pump','on');
my $old = $calls[-1];
WIFFI_DEVICE_Undef($device);
is($closed[-1], $old, 'undef closes outstanding control request');
ok(!exists $device->{'.WIFFI_HTTP'}, 'undef releases request state');
my $previous_logs=scalar @logs;
$old->{callback}->($old, 'connection reset', '');
is(scalar @logs, $previous_logs, 'late callback after undef ignored');

$err = WIFFI_DEVICE_Set($device,'Pump','off');
my $old2 = $calls[-1];
$device->{OLDDEF} = $device->{DEF} // '';
$err = WIFFI_DEVICE_Define($device,
  'Pump WIFFI_DEVICE Collector 02:00:00:00:00:01');
delete $device->{OLDDEF};
is($err, undef, 'redefinition accepted');
is($closed[-1], $old2, 'modify closes pending request');
ok(!exists $device->{PEER}, 'modify requires fresh sender identification');
ok(!exists $device->{'.WIFFI_HTTP'}, 'modify clears inflight command');

# A device renamed during the callback remains the same reference.
$device->{PEER} = '192.0.2.21';
$device->{MODULTYP} = 'wiffi-pump';
WIFFI_DEVICE_Set($device,'Pump','off');
my $pending = $calls[-1];
delete $defs{Pump};
$device->{NAME}='RenamedPump';
$defs{RenamedPump}=$device;
$pending->{code}=200;
$pending->{callback}->($pending,'','');
ok(!exists $device->{'.WIFFI_HTTP'}, 'renamed device callback handled');

done_testing();
