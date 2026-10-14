# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use lib 't/lib';
our (%defs, %attr, @calls, @closed, @logs, $throw_http);
sub HttpUtils_NonblockingGet {
  my ($param) = @_;
  die "synthetic HTTP initiation failure" if $throw_http;
  push @calls, $param;
}
sub HttpUtils_Close { push @closed, $_[0] }
sub Log3 { push @logs, $_[2] }
sub AttrVal {
  my ($name, $key, $default) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $default;
}
sub readingsSingleUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
require './FHEM/00_WIFFI_Collector.pm';
require './FHEM/10_WIFFI_DEVICE.pm';

sub init {
  %defs = ();
  %attr = ();
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
is($module{AttrFn}, 'WIFFI_DEVICE_Attr', 'AttrFn registered on logical devices');
is($module{FW_detailFn}, 'WIFFI_DEVICE_FwDetail', 'FHEMWEB detail hook registered');
is($module{FW_deviceOverview}, 1, 'standard FHEM device overview is preserved');
ok(!defined $module{FW_addDetailToSummary},
  'FHEMWEB does not add a separate link row in room overview');
like($module{AttrList}, qr/disable:0,1/, 'device offers disable attribute');

my $device = init();
is(WIFFI_DEVICE_FwDetail(undef,'Pump',undef,undef),
  '<a href="http://192.0.2.21/" target="_blank" rel="noopener noreferrer">WIFFI Webinterface</a><br>',
  'device detail link has one extra line break before FHEMWEB set controls');
delete $device->{PEER};
ok(!defined WIFFI_DEVICE_FwDetail(undef,'Pump',undef,undef),
  'no webinterface link before a peer is learned');
$device->{PEER} = 'http://192.0.2.21/';
ok(!defined WIFFI_DEVICE_FwDetail(undef,'Pump',undef,undef),
  'unsafe peer string never becomes an external link');
$device->{PEER} = '192.0.2.21';

my $err = WIFFI_DEVICE_Set($device, 'Pump', 'on');
is($err, undef, 'on dispatched asynchronously');
is(scalar @calls, 1, 'single nonblocking HTTP request');
is($calls[0]{url}, 'http://192.0.2.21/?trigger:on:', 'on uses documented WIFFI command');
is($calls[0]{method}, 'GET', 'uses HTTP GET');
is($calls[0]{timeout}, 5, 'HTTP request bounded by timeout');
is($calls[0]{ignoreredirects}, 1, 'HTTP redirect following disabled even for shortcuts');
is($device->{READINGS}{wiffi_pump}{VAL}, 'false',
   'set does not optimistically change the reported pump state');
like(WIFFI_DEVICE_Set($device,'Pump','off'), qr/pending/, 'reject concurrent commands');
is(scalar @calls, 1, 'busy request does not enqueue another command');

$calls[0]{code} = 200;
$calls[0]{callback}->($calls[0], '', 'ok');
ok(!exists $device->{'.WIFFI_HTTP'}, 'callback clears inflight state');
is($device->{READINGS}{wiffi_pump}{VAL}, 'false',
   'HTTP 200 is not interpreted as pump state confirmation');

my $before_reset_uptime = '1234';
$device->{READINGS}{Systeminfo_sec_seit_reset}{VAL} = $before_reset_uptime;
$err = WIFFI_DEVICE_Set($device, 'Pump', 'reset');
is($err, undef, 'documented reset command accepted for pump');
is($calls[1]{url}, 'http://192.0.2.21/?reset:', 'reset uses documented WIFFI restart path');
is($device->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, $before_reset_uptime,
  'reset command does not optimistically reset heartbeat uptime');
$calls[1]{code} = 200;
$calls[1]{callback}->($calls[1], '', 'ok');
is($device->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, $before_reset_uptime,
  'HTTP 200 is not treated as restart confirmation');
like(WIFFI_DEVICE_Set($device,'Pump','reset','extra'),qr/Usage/,
  'reset rejects surplus arguments');

$err = WIFFI_DEVICE_Set($device, 'Pump', 'off');
is($err, undef, 'off accepted');
is($calls[2]{url}, 'http://192.0.2.21/?trigger:off:', 'off uses documented command');
$calls[2]{code} = 404;
$calls[2]{callback}->($calls[2], '', '');
like(join(' ',@logs), qr/HTTP status 404/, 'HTTP response failure logged');
ok(!exists $device->{'.WIFFI_HTTP'}, 'failed HTTP response releases busy state');

$err = WIFFI_DEVICE_Set($device, 'Pump', 'on-for-timer', 300);
is($err, undef, 'timed pump command accepted');
is($calls[3]{url}, 'http://192.0.2.21/?trigger:300:', 'timed manufacturer command');
$calls[3]{callback}->($calls[3], 'timeout', '');
like(join(' ',@logs), qr/timeout/, 'transport errors logged');
ok(!exists $device->{'.WIFFI_HTTP'}, 'timeout releases busy state');

for my $bad ('0','3601','-1','1.5','oops','10;shutdown','001','999999') {
  like(WIFFI_DEVICE_Set($device,'Pump','on-for-timer',$bad),qr/Usage/,
    "reject invalid duration $bad");
}
is(scalar @calls, 4, 'invalid duration never causes HTTP call');
like(WIFFI_DEVICE_Set($device,'Pump','on-for-timer'),qr/Usage/,
  'missing duration is rejected');
like(WIFFI_DEVICE_Set($device,'Pump','on','extra'),qr/Usage/,
  'extra arguments rejected');
like(WIFFI_DEVICE_Set($device,'Pump','factory'),qr/Unknown argument/,
  'destructive undocumented convenience command remains unavailable');

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
$device->{MODULTYP} = 'weatherman';
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/Unknown argument.*reset httpGet/,
  'weatherman offers reset but no pump shortcuts');
my $weather_reset = WIFFI_DEVICE_Set($device,'Pump','reset');
is($weather_reset, undef, 'weatherman exposes documented reset command');
my $weather_reset_request = $calls[-1];
is($weather_reset_request->{url}, 'http://192.0.2.21/?reset:',
  'weatherman reset uses common restart path');
$weather_reset_request->{code}=200;
$weather_reset_request->{callback}->($weather_reset_request,'','');
my $generic = WIFFI_DEVICE_Set($device,'Pump','httpGet','/?param:0:240:');
is($generic, undef, 'generic GET accepted on WEATHERMAN');
my $get = $calls[-1];
is($get->{url}, 'http://192.0.2.21/?param:0:240:',
  'generic GET uses only learned TCP peer and supplied relative path');
is($get->{ignoreredirects}, 1, 'generic GET cannot follow a redirect off-device');
is($get->{method}, 'GET', 'generic setter is GET-only');
$get->{code} = 200;
$get->{callback}->($get, '', 'ok');
ok(!exists $device->{'.WIFFI_HTTP'}, 'generic callback releases pending command');

my $calls_before_invalid_http_get = scalar @calls;
for my $bad (
  'https://example.com/?reset:',
  '//evil.example/?reset:',
  'http://192.0.2.3/',
  'reset:',
  '/ok#fragment',
  "/foo\ninjection",
  '/bad%escape',
  '/bad%0',
  '/back\\slash',
  ' ',
  '/' . ('a' x 2049)
) {
  like(WIFFI_DEVICE_Set($device,'Pump','httpGet',$bad),qr/Usage/,
    "generic GET rejects unsafe path");
}
like(WIFFI_DEVICE_Set($device,'Pump','httpGet'),qr/Usage/,
  'generic GET requires exactly one path');
like(WIFFI_DEVICE_Set($device,'Pump','httpGet','/ok','/extra'),qr/Usage/,
  'generic GET rejects multiple path arguments');
is(scalar @calls, $calls_before_invalid_http_get,
  'invalid generic GET arguments never initiate HTTP');

$device->{MODULTYP} = 'PULSECOUNTER';
like(WIFFI_DEVICE_Set($device,'Pump','on'), qr/Unknown argument.*counter reset httpGet/,
  'PULSECOUNTER offers counter/reset but no pump shortcuts');
my $pulse_reset = WIFFI_DEVICE_Set($device,'Pump','reset');
is($pulse_reset, undef, 'PULSECOUNTER exposes documented reset command');
my $pulse_reset_request = $calls[-1];
is($pulse_reset_request->{url}, 'http://192.0.2.21/?reset:',
  'PULSECOUNTER reset uses common restart path');
$pulse_reset_request->{code}=200;
$pulse_reset_request->{callback}->($pulse_reset_request,'','');
$device->{READINGS}{w_counter2}{VAL} = '143.540';
my $counter_calls = scalar @calls;
my $counter = WIFFI_DEVICE_Set($device,'Pump','counter','2','143.550');
is($counter, undef, 'PULSECOUNTER counter command accepted');
my $counter_request = $calls[-1];
is($counter_request->{url}, 'http://192.0.2.21/?counter:2:143.550:',
  'counter setter uses documented manufacturer path without rewriting precision');
is($device->{READINGS}{w_counter2}{VAL}, '143.540',
  'counter setter does not optimistically change telemetry');
$counter_request->{code} = 200;
$counter_request->{callback}->($counter_request, '', 'ok');
is($device->{READINGS}{w_counter2}{VAL}, '143.540',
  'HTTP 200 is not treated as counter readback');

for my $case (
  ['0','143.550'], ['5','143.550'], ['2','-1'], ['2','1,5'],
  ['2','001'], ['2','1000000'], ['2','1e3'], ['2','1.'],
  ['2','.5'], ['2','1' . ('.' . ('1' x 31))]
) {
  like(WIFFI_DEVICE_Set($device,'Pump','counter',@$case), qr/Usage/,
    "reject invalid PULSECOUNTER value/channel @$case");
}
like(WIFFI_DEVICE_Set($device,'Pump','counter','2'), qr/Usage/,
  'counter setter requires channel and value');
like(WIFFI_DEVICE_Set($device,'Pump','counter','2','1','extra'), qr/Usage/,
  'counter setter rejects surplus arguments');
is(scalar @calls, $counter_calls + 1,
  'invalid counter commands never initiate HTTP');
$device->{MODULTYP} = 'WEATHERMAN';
like(WIFFI_DEVICE_Set($device,'Pump','counter','2','143.550'),
  qr/Unknown argument.*httpGet/,
  'counter setter is unavailable on WEATHERMAN');

$generic = WIFFI_DEVICE_Set($device,'Pump','httpGet','/status?key=a%20b&v=1');
is($generic, undef, 'encoded query GET accepted');
$get = $calls[-1];
is($get->{url}, 'http://192.0.2.21/status?key=a%20b&v=1',
  'allowed query remains byte-for-byte unchanged');
like(WIFFI_DEVICE_Set($device,'Pump','httpGet','/'),qr/pending/,
  'generic GET shares the single in-flight request slot with shortcuts');
$get->{code} = 302;
$get->{callback}->($get,'','');
like(join(' ', @logs), qr/HTTP status 302/,
  'HTTP redirects are reported, not followed or treated as success');
$device->{MODULTYP} = 'wiffi-pump';

my $pumpGet = WIFFI_DEVICE_Set($device,'Pump','httpGet','/?trigger:120:');
is($pumpGet, undef, 'generic GET also works with pump devices');
my $pumpRequest = $calls[-1];
is($pumpRequest->{url}, 'http://192.0.2.21/?trigger:120:',
  'pump generic GET uses exact supplied command');
$pumpRequest->{code} = 200;
$pumpRequest->{callback}->($pumpRequest, '', '');

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


# Disabled device must not send an HTTP command, cancel an in-flight request
# and must ignore its late callback without updating state.
$device = init();
my $initial_calls = scalar @calls;
like(WIFFI_DEVICE_Attr('set','Pump','disable','invalid'),qr/disable 0\|1/,
  'reject invalid disable value');
is(WIFFI_DEVICE_Set($device,'Pump','on'),undef,'fresh pump request queued');
my $during_disable = $calls[-1];
is(WIFFI_DEVICE_Attr('set','Pump','disable','1'),undef,
  'device disable attribute transition succeeds');
$attr{Pump}{disable}=1;
is($closed[-1],$during_disable,'disable closes pending HTTP request');
ok(!exists $device->{'.WIFFI_HTTP'},'disable clears pending command');
like(WIFFI_DEVICE_Set($device,'Pump','on'),qr/disabled/,
  'on rejected while device disabled');
like(WIFFI_DEVICE_Set($device,'Pump','off'),qr/disabled/,
  'off rejected while device disabled');
like(WIFFI_DEVICE_Set($device,'Pump','on-for-timer',30),qr/disabled/,
  'timer rejected while device disabled');
like(WIFFI_DEVICE_Set($device,'Pump','reset'),qr/disabled/,
  'reset rejected while device disabled');
like(WIFFI_DEVICE_Set($device,'Pump','httpGet','/'),qr/disabled/,
  'generic httpGet rejected while disabled');
$device->{MODULTYP} = 'PULSECOUNTER';
like(WIFFI_DEVICE_Set($device,'Pump','counter','2','143.550'),qr/disabled/,
  'counter setter rejected while PULSECOUNTER device disabled');
$device->{MODULTYP} = 'wiffi-pump';
is(scalar @calls,$initial_calls+1,'disabled commands send no HTTP requests');
my $prior_logs = scalar @logs;
$during_disable->{callback}->($during_disable,'closed','');
is(scalar @logs,$prior_logs,'late disabled HTTP callback is ignored');
is(WIFFI_DEVICE_Attr('set','Pump','disable','0'),undef,
  'explicit device enable accepted');
$attr{Pump}{disable}=0;
is(WIFFI_DEVICE_Set($device,'Pump','on'),undef,
  'enabled device can dispatch HTTP again');
my $after_enable = $calls[-1];
$after_enable->{code}=200;
$after_enable->{callback}->($after_enable,'','');
is(WIFFI_DEVICE_Attr('set','Pump','disable','1'),undef,
  'disable device second time');
$attr{Pump}{disable}=1;
is(WIFFI_DEVICE_Attr('del','Pump','disable'),undef,
  'deleteattr disable accepted');
delete $attr{Pump}{disable};
is(WIFFI_DEVICE_Set($device,'Pump','off'),undef,
  'device works again after deleting disable attr');
my $after_deleteattr = $calls[-1];
$after_deleteattr->{code}=200;
$after_deleteattr->{callback}->($after_deleteattr,'','');

# FHEM's DoSet calls SetFn in list context. Returning a true second value
# suppresses DoSet's automatic command event; telemetry alone reports state.
$device = init();
my ($accepted, $skip_trigger) = WIFFI_DEVICE_Set($device,'Pump','on');
is($accepted,undef,'HTTP dispatch returns no FHEM error in list context');
is($skip_trigger,1,'accepted asynchronous command suppresses synthetic on event');
ok(!exists $device->{READINGS}{state},
  'HTTP dispatch does not create an extra state reading');
my $quiet_on = $calls[-1];
$quiet_on->{callback}->($quiet_on,'','');
($accepted, $skip_trigger) = WIFFI_DEVICE_Set($device,'Pump','httpGet','/status');
is($accepted,undef,'generic command returns success in list context');
is($skip_trigger,1,'generic HTTP command suppresses synthetic set event');
my $quiet_get = $calls[-1];
$quiet_get->{callback}->($quiet_get,'','');
$device->{MODULTYP} = 'PULSECOUNTER';
$device->{READINGS}{w_counter2}{VAL} = '143.540';
($accepted, $skip_trigger) = WIFFI_DEVICE_Set($device,'Pump','counter','2','143.550');
is($accepted,undef,'counter dispatch returns success in list context');
is($skip_trigger,1,'counter command suppresses synthetic FHEM set event');
is($device->{READINGS}{w_counter2}{VAL},'143.540',
  'counter dispatch leaves readback to telemetry');
my $quiet_counter = $calls[-1];
$quiet_counter->{callback}->($quiet_counter,'','');
$device->{MODULTYP} = 'wiffi-pump';
($accepted, $skip_trigger) = WIFFI_DEVICE_Set($device,'Pump','noSuchSet');
like($accepted,qr/Unknown argument/,'invalid set still reports an error');
ok(!defined $skip_trigger,'invalid set does not claim successful dispatch');
$throw_http=1;
($accepted,$skip_trigger)=WIFFI_DEVICE_Set($device,'Pump','off');
like($accepted,qr/Failed to send/,'failed HTTP initiation reports an error in list context');
ok(!defined $skip_trigger,'failed initiation does not claim successful dispatch');
$throw_http=0;

done_testing();
