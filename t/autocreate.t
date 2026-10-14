# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use JSON::PP ();

# A narrow FHEM CommandDefine/reading contract double, based on fhem.pl:
# CommandDefine inserts into %defs, calls DefFn, removes rejected definitions
# and emits a synchronous DEFINED notification after successful definition.
# Unlike a live FHEM process this does NOT test the actual event loop,
# database logging, socket lifetime, or other global notify side effects.
our (%defs, %attr, $init_done);
my ($definitions, $on_define, $on_attr, $forced_error);
my @logs;
sub AttrVal {
  my ($name, $key, $fallback) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $fallback;
}
sub Log3 { push @logs, $_[2] }
sub TimeNow { return '2026-10-14 15:00:00' }
sub readingsSingleUpdate {
  my ($hash, $key, $value) = @_;
  $hash->{READINGS}{$key}{VAL} = "$value";
}
sub readingsBeginUpdate { $_[0]{'.updating'} = 1 }
sub readingsBulkUpdate {
  my ($hash, $key, $value) = @_;
  die "not inside readingsBeginUpdate" unless $hash->{'.updating'};
  $hash->{READINGS}{$key}{VAL} = "$value";
}
sub readingsEndUpdate { delete $_[0]{'.updating'} }
sub CommandDefine {
  my ($cl, $def) = @_;
  $definitions++;
  return $forced_error if defined $forced_error;
  my ($name, $type, $collector, $mac) = split /\s+/, $def;
  return 'invalid name' unless $name =~ /\A[A-Za-z0-9._]+\z/;
  return 'already defined' if $defs{$name};
  return 'invalid module' unless $type eq 'WIFFI_DEVICE';
  my $device = {
    NAME => $name, TYPE => $type, DEF => "$collector $mac",
    FUUID => 'synthetic-test-uuid-'.$definitions,
  };
  $defs{$name} = $device;
  my $err = WIFFI_DEVICE_Define($device, $def);
  if ($err) {
    delete $defs{$name};
    return $err;
  }
  $on_define->($name) if $on_define;
  return undef;
}
sub CommandAttr {
  my ($cl, $statement) = @_;
  my ($name, $key, $value) = split /\s+/, $statement, 3;
  return 'missing device' unless $defs{$name};
  my $error = WIFFI_DEVICE_Attr('set', $name, $key, $value)
    if $key eq 'IODev';
  return $error if $error;
  $attr{$name}{$key} = $value;
  AssignIoPort($defs{$name}, $value) if $key eq 'IODev';
  $on_attr->($name, $key) if $on_attr;
  return undef;
}
require './t/lib/WiffiIOStub.pm';
require './FHEM/00_WIFFI_Collector.pm';
require './FHEM/10_WIFFI_DEVICE.pm';

sub start_case {
  %defs = ();
  %attr = ();
  @logs = ();
  ($definitions, $forced_error, $on_define, $on_attr) = (0, undef, undef, undef);
  $defs{Collector} = {
    NAME => 'Collector', TYPE => 'WIFFI_Collector',
    FRAMES_OK => 0, FRAMES_ERROR => 0,
    FRAMES_UNKNOWN => 0, AUTOCREATED => 0
  };
  return $defs{Collector};
}
sub telegram {
  my ($mac, $ip, $value, $type) = @_;
  return JSON::PP::encode_json({
    modultyp => defined($type) ? $type : 'PULSECOUNTER',
    vars => [
      {name => '0', homematic_name => 'w_counterIP', value => $ip},
      {name => '11', homematic_name => 'w_counter1', value => $value},
    ],
    Systeminfo => {
      'MAC-Adresse' => $mac, sec_seit_reset => '120', firmware => 'test'
    }
  });
}

my $server = start_case();
my $raw = telegram('02:00:00:00:00:01', '192.0.2.21', '12.500');
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{FRAMES_UNKNOWN}, 1, 'autocreate disabled by default');
is($definitions, 0, 'unknown sender does not create a device');
ok(!$defs{WIFFI_020000000001}, 'no logical device created');

$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($definitions, 1, 'first valid unknown MAC creates device');
is($server->{AUTOCREATED}, 1, 'creation counter incremented');
is($server->{FRAMES_OK}, 1, 'first telegram delivered');
my $device = $defs{WIFFI_020000000001};
ok($device, 'stable full-MAC FHEM device name');
is($device->{MAC}, '02:00:00:00:00:01', 'device identity recorded');
is($device->{IODev}, $server, 'IODev points to source collector');
is($device->{DEF}, '02:00:00:00:00:01', 'autocreate persists MAC-only DEF');
is($attr{WIFFI_020000000001}{IODev}, 'Collector', 'source collector attribute persisted');
is($device->{READINGS}{w_counter1}{VAL}, '12.500', 'native CCU reading updated');
is($device->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, '120', 'heartbeat is present');
ok($device->{FUUID}, 'FHEM CommandDefine assigned a synthetic identity');
is($attr{WIFFI_020000000001}{room}, 'WIFFI', 'autocreated device has WIFFI room');
is($attr{WIFFI_020000000001}{'event-on-change-reading'}, '.*',
  'non-pump receives change-only events by default');
is($attr{WIFFI_020000000001}{'event-on-update-reading'},
  'Systeminfo_sec_seit_reset', 'heartbeat events remain visible');
is($attr{WIFFI_020000000001}{DbLogExclude},
  '^Systeminfo_sec_seit_reset$', 'heartbeat is excluded from DbLog');
ok(!exists $attr{WIFFI_020000000001}{stateFormat},
  'non-pump autocreate does not impose stateFormat');
ok(!exists $attr{WIFFI_020000000001}{devStateIcon},
  'non-pump autocreate does not impose a device icon');

WIFFI_Collector_ProcessFrame($server,
  telegram('2:0:0:0:0:1', '192.0.2.21', '12.750'), '192.0.2.21');
is($definitions, 1, 'normalized MAC does not cause a duplicate');
WIFFI_Collector_ProcessFrame($server,
  telegram('020000000001', '192.0.2.21', '12.755'), '192.0.2.21');
is($definitions, 1, 'colon-free incoming MAC matches the existing device');
is($device->{READINGS}{w_counter1}{VAL}, '12.755',
  'existing device receives telegram addressed by colon-free MAC');
is($server->{FRAMES_ERROR}, 0, 'colon-free MAC is not treated as an identity conflict');
$attr{WIFFI_020000000001}{room} = 'Energie';
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '12.760'), '192.0.2.21');
is($attr{WIFFI_020000000001}{room}, 'Energie',
  'autocreate does not overwrite existing custom room');

$attr{WIFFI_020000000001}{DbLogExclude} = '^w_counterIP$';
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '12.770'), '192.0.2.21');
is($attr{WIFFI_020000000001}{DbLogExclude}, '^w_counterIP$',
  'explicitly configured DbLog filtering remains untouched');
is($device->{READINGS}{w_counter1}{VAL}, '12.770', 'known device updated');

# A renamed device is resolved by its MAC, not by the old generated name.
delete $defs{WIFFI_020000000001};
$device->{NAME} = 'MyPulseCounter';
$defs{MyPulseCounter} = $device;
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '13'), '192.0.2.21');
is($definitions, 1, 'renamed device reused without autocreate');
is($defs{MyPulseCounter}{READINGS}{w_counter1}{VAL}, '13', 'renamed device gets readings');

$attr{Collector}{autocreate} = 0;
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '14'), '192.0.2.21');
is($device->{READINGS}{w_counter1}{VAL}, '14',
  'turning autocreate off does not disable existing devices');

# Conflicting definitions for one MAC must block all updates, not pick
# arbitrarily from hash iteration order.
my $other = {
  NAME => 'Other', TYPE => 'WIFFI_DEVICE',
  IODev => $server, MAC => '02:00:00:00:00:01',
  READINGS => {}
};
$defs{Other} = $other;
my $previous = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '999'), '192.0.2.21');
is($server->{FRAMES_ERROR}, $previous+1, 'duplicate MAC detected');
is($device->{READINGS}{w_counter1}{VAL}, '14', 'duplicate MAC did not update original');
ok(!exists $other->{READINGS}{w_counter1}, 'duplicate MAC did not update second');
delete $defs{Other};

$previous = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.22', '999'), '192.0.2.22');
is($server->{FRAMES_ERROR}, $previous+1, 'same MAC with different TCP source rejected');
is($device->{PEER}, '192.0.2.21', 'last verified peer not changed');

# An intentional FHEM modify redefines the same logical device and clears
# the observed sender identity. This is the explicit recovery path for DHCP.
$device->{OLDDEF} = $device->{DEF};
my $modify_error = WIFFI_DEVICE_Define($device,
  'MyPulseCounter WIFFI_DEVICE Collector 020000000001');
delete $device->{OLDDEF};
is($modify_error, undef, 'explicit modify accepted');
is($device->{MAC}, '02:00:00:00:00:01',
   'colon-free modify keeps the same canonical MAC and logical device');
ok(!defined $device->{PEER}, 'modify clears previously learned peer');
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.22', '15'), '192.0.2.22');
is($device->{PEER}, '192.0.2.22', 'new peer accepted after explicit modify');
is($device->{READINGS}{w_counter1}{VAL}, '15', 'new peer publishes after modify');

$attr{Collector}{autocreate} = 1;
$previous = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:02', '192.0.2.22', '88'), '192.0.2.22');
is($server->{FRAMES_ERROR}, $previous+1, 'same peer with new MAC rejected');
ok(!$defs{WIFFI_020000000002}, 'conflicting peer creates no new device');

# Existing unrelated names must never be overwritten/adopted.
$server = start_case();
$attr{Collector}{autocreate} = 1;
my $foreign = {NAME => 'WIFFI_020000000001', TYPE => 'dummy'};
$defs{WIFFI_020000000001} = $foreign;
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($definitions, 0, 'existing FHEM name blocks autocreate');
is($defs{WIFFI_020000000001}, $foreign, 'unrelated FHEM device untouched');
is($server->{FRAMES_UNKNOWN}, 1, 'name collision reported as unknown');

# CommandDefine failure is not reported as successful creation.
$server = start_case();
$attr{Collector}{autocreate} = 1;
$forced_error = 'test define failure';
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{AUTOCREATED}, 0, 'failed define not counted');
is($server->{FRAMES_UNKNOWN}, 1, 'failed define does not publish readings');
ok(!$defs{WIFFI_020000000001}, 'failed define leaves no device');

# CommandDefine fires DEFINED; test an event handler removing that device.
$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_define = sub { delete $defs{$_[0]} };
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{AUTOCREATED}, 0, 'deleted-on-defined not counted');
is($server->{FRAMES_UNKNOWN}, 1, 'deleted-on-defined not published');
ok(!$defs{WIFFI_020000000001}, 'reentrantly deleted device not resurrected');

$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_attr = sub { delete $defs{$_[0]} if $_[1] eq 'room' };
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{AUTOCREATED}, 0, 'deleted during ATTR setup not counted');
is($server->{FRAMES_UNKNOWN}, 1, 'deleted during ATTR not published');

# If a DEFINED/ATTR hook drops IODev, do not persist a MAC-only
# definition that can later attach to an unintended collector.
$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_attr = sub { delete $attr{$_[0]}{IODev} if $_[1] eq 'IODev' };
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{AUTOCREATED}, 0,
  'autocreate does not finalize an IODev binding that was not persisted');
is($server->{FRAMES_UNKNOWN}, 1,
  'a device with missing persisted IODev remains unassigned');
is($defs{WIFFI_020000000001}{DEF}, 'Collector 02:00:00:00:00:01',
  'unsafe creation does not silently normalize away the source collector');

# Full MAC prevents aliasing on identical trailing octets.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
WIFFI_Collector_ProcessFrame($server,
  telegram('06:00:00:00:00:01', '192.0.2.22', '22'), '192.0.2.22');
ok($defs{WIFFI_020000000001} && $defs{WIFFI_060000000001},
  'distinct full-MAC names for same trailing bytes');
is($definitions, 2, 'both devices created once');

# Only a newly autocreated WIFFI-pump receives pump display defaults.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:03', '192.0.2.23', '1', 'wiffi-pump'), '192.0.2.23');
my $pump_name = 'WIFFI_020000000003';
is($attr{$pump_name}{room}, 'WIFFI', 'pump assigned to WIFFI room');
is($attr{$pump_name}{stateFormat}, 'wiffi_pump',
  'pump stateFormat reflects real pump reading');
is($attr{$pump_name}{devStateIcon}, 'true:on false:off',
  'pump devStateIcon matches requested on/off symbols');
ok(!exists $attr{$pump_name}{webCmd}, 'webCmd not imposed');
is($attr{$pump_name}{DbLogExclude}, '^Systeminfo_sec_seit_reset$',
  'pump heartbeat excluded from DbLog');
is($attr{$pump_name}{'event-on-change-reading'}, '.*',
  'pump change-only event default');
is($attr{$pump_name}{'event-on-update-reading'},
  'Systeminfo_sec_seit_reset', 'pump heartbeat remains eventful');
is($server->{AUTOCREATED}, 1, 'pump created exactly once');
$attr{$pump_name}{devStateIcon} = 'true:custom_on false:custom_off';
$attr{$pump_name}{stateFormat} = 'online';
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:03', '192.0.2.23', '2', 'wiffi-pump'), '192.0.2.23');
is($attr{$pump_name}{devStateIcon}, 'true:custom_on false:custom_off',
  'later telegrams preserve custom pump icon');
is($attr{$pump_name}{stateFormat}, 'online',
  'later telegrams preserve custom pump state format');
is($server->{AUTOCREATED}, 1, 'repeat pump telegram does not autocreate again');

# A valid type change is adopted and diagnosed; the allowed SetFn commands
# follow the *current* type. No second identity or persistent type is needed.
$server = start_case();
$attr{Collector}{autocreate} = 1;
my $type_mac = '02:00:00:00:00:09';
my $type_name = 'WIFFI_020000000009';
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '1', 'wiffi-pump'), '192.0.2.29');
my $typed = $defs{$type_name};
is($typed->{MODULTYP}, 'wiffi-pump', 'first valid telegram establishes pump type');
like(WIFFI_DEVICE_Set($typed, $type_name, '?'),
  qr/choose one of on off on-for-timer reset httpGet\z/,
  'pump shortcuts offered for pump type');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 0,
  'first observed type does not count as a transition');
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '2', 'wiffi-pump'), '192.0.2.29');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 0,
  'unchanged type does not generate transition logs');
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '3', 'PULSECOUNTER'), '192.0.2.29');
is($typed->{MODULTYP}, 'PULSECOUNTER', 'changed type accepted from same MAC');
is($typed->{READINGS}{w_counter1}{VAL}, '3', 'changed-type telegram updates readings');
is($server->{FRAMES_OK}, 3, 'accepted type switch is a valid frame');
is($server->{FRAMES_ERROR}, 0, 'accepted type switch is not a frame error');
like(WIFFI_DEVICE_Set($typed, $type_name, '?'),
  qr/choose one of counter reset httpGet\z/,
  'after type change PULSECOUNTER setter is advertised');
like(WIFFI_DEVICE_Set($typed, $type_name, 'on'),
  qr/Unknown argument.*counter reset httpGet/,
  'old pump on command is refused after type change');
like(WIFFI_DEVICE_Set($typed, $type_name, 'off'),
  qr/Unknown argument.*counter reset httpGet/,
  'old pump off command is refused after type change');
like(WIFFI_DEVICE_Set($typed, $type_name, 'on-for-timer', 30),
  qr/Unknown argument.*counter reset httpGet/,
  'old timer command is refused after type change');
like(join(' ', @logs), qr/WIFFI modultyp changed: wiffi-pump -> PULSECOUNTER/,
  'type change logged with prior and current type');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 1,
  'transition logged exactly once');
is($attr{$type_name}{stateFormat}, 'wiffi_pump',
  'type transition preserves previously assigned stateFormat');
is($attr{$type_name}{devStateIcon}, 'true:on false:off',
  'type transition preserves previous icon without hidden attr migration');
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '4', 'PULSECOUNTER'), '192.0.2.29');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 1,
  'repeated PULSECOUNTER telegram does not spam transition logs');
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '5', 'wiffi-pump'), '192.0.2.29');
is($typed->{MODULTYP}, 'wiffi-pump', 'later pump type restored');
like(WIFFI_DEVICE_Set($typed, $type_name, '?'),
  qr/choose one of on off on-for-timer reset httpGet\z/,
  'pump shortcuts reappear after a valid pump telegram');
is($server->{FRAMES_OK}, 5, 'all type transitions accepted');
is($server->{FRAMES_ERROR}, 0, 'no parser errors from type transitions');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 2,
  'pump-to-counter and counter-to-pump each logged once');

# A broken telegram claiming a new type must not alter the existing type,
# advertised setters, state or heartbeat.
my $before_heartbeat = $typed->{READINGS}{Systeminfo_sec_seit_reset}{VAL};
my $invalid_type_packet = JSON::PP::encode_json({
  modultyp => 'PULSECOUNTER',
  vars => [
    {homematic_name => 'w_counter1', value => '100'},
    {homematic_name => 'w_counter1', value => '101'}
  ],
  Systeminfo => {'MAC-Adresse' => $type_mac, sec_seit_reset => '999'}
});
WIFFI_Collector_ProcessFrame($server, $invalid_type_packet, '192.0.2.29');
is($typed->{MODULTYP}, 'wiffi-pump',
  'invalid changed-type telegram does not alter current type');
is($typed->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, $before_heartbeat,
  'invalid changed-type telegram does not refresh heartbeat');
like(WIFFI_DEVICE_Set($typed, $type_name, '?'),
  qr/choose one of on off on-for-timer reset httpGet\z/,
  'invalid changed-type telegram cannot remove pump commands');
is($server->{FRAMES_ERROR}, 1, 'real invalid packet counted as malformed');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 2,
  'invalid changed-type packet is not logged as an accepted transition');

$typed->{OLDDEF} = $typed->{DEF};
is(WIFFI_DEVICE_Define($typed,
    "$type_name WIFFI_DEVICE Collector $type_mac"), undef,
  'explicit device modify succeeds after type transitions');
delete $typed->{OLDDEF};
ok(!exists $typed->{MODULTYP}, 'modify clears observed type');
like(WIFFI_DEVICE_Set($typed, $type_name, '?'),
  qr/choose one of httpGet\z/,
  'after modify no stale pump shortcuts before telemetry');
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '6', 'PULSECOUNTER'), '192.0.2.29');
is($typed->{MODULTYP}, 'PULSECOUNTER', 'first post-modify telegram establishes type');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 2,
  'first type after modify is not incorrectly logged as transition');

# A restart-like new definition starts without an old in-memory type.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server,
  telegram($type_mac, '192.0.2.29', '7', 'PULSECOUNTER'), '192.0.2.29');
$typed = $defs{$type_name};
is($typed->{MODULTYP}, 'PULSECOUNTER',
  'fresh device after restart-like reset accepts first advertised type');
like(WIFFI_DEVICE_Set($typed, $type_name, '?'),
  qr/choose one of counter reset httpGet\z/,
  'restart-like PULSECOUNTER telegram exposes counter but no pump shortcuts');
is(scalar(grep {/WIFFI modultyp changed:/} @logs), 0,
  'fresh in-memory type after restart-like reset has no transition log');

# DEFINED handlers can set their own defaults before autocreate applies ours.
$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_define = sub {
  $attr{$_[0]}{stateFormat} = 'custom';
  $attr{$_[0]}{devStateIcon} = 'true:my_on false:my_off';
  $attr{$_[0]}{room} = 'Warmwasser';
  $attr{$_[0]}{DbLogExclude} = '^my_custom$';
  $attr{$_[0]}{'event-on-change-reading'} = 'wiffi_pump';
  $attr{$_[0]}{'event-on-update-reading'} = 'wiffi_ntc';
};
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:04', '192.0.2.24', '3', 'wiffi-pump'), '192.0.2.24');
my $custom_name = 'WIFFI_020000000004';
is($server->{AUTOCREATED}, 1, 'pump created with DEFINED custom attributes');
is($attr{$custom_name}{stateFormat}, 'custom', 'custom stateFormat not overridden');
is($attr{$custom_name}{devStateIcon}, 'true:my_on false:my_off',
  'custom devStateIcon not overridden');
is($attr{$custom_name}{room}, 'Warmwasser', 'custom room not overridden');
is($attr{$custom_name}{DbLogExclude}, '^my_custom$',
  'DEFINED DbLogExclude is not overwritten');
is($attr{$custom_name}{'event-on-change-reading'}, 'wiffi_pump',
  'DEFINED event-on-change-reading is not overwritten');
is($attr{$custom_name}{'event-on-update-reading'}, 'wiffi_ntc',
  'DEFINED event-on-update-reading is not overwritten');

# Reentrant deletion during device-type-specific default ATTR is handled.
$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_attr = sub { delete $defs{$_[0]} if $_[1] eq 'stateFormat' };
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:05', '192.0.2.25', '4', 'wiffi-pump'), '192.0.2.25');
is($server->{AUTOCREATED}, 0, 'pump deleted during stateFormat setup is not counted');
is($server->{FRAMES_UNKNOWN}, 1, 'deleted pump telegram not assigned');

# stripReadingPrefix is opt-in and affects only a leading "w_" on that device.
$server = start_case();
my $weather_name = 'WIFFI_WEATHERMAN';
is(CommandDefine(undef,
    "$weather_name WIFFI_DEVICE Collector 02:00:00:00:00:06"),
  undef, 'explicit WEATHERMAN defined');
my $weather = $defs{$weather_name};
my $weather_raw = JSON::PP::encode_json({
  modultyp => 'weatherman',
  vars => [
    {homematic_name => 'w_temperatur', value => '12.2'},
    {homematic_name => 'w_lux', value => '1747.2'},
    {homematic_name => 'wiffi_pump', value => 'false'},
  ],
  Systeminfo => {'MAC-Adresse' => '02:00:00:00:00:06',
    sec_seit_reset => '123'}
});
WIFFI_Collector_ProcessFrame($server, $weather_raw, '192.0.2.26');
is($weather->{READINGS}{w_temperatur}{VAL}, '12.2',
  'default keeps native w_ reading names');
ok(!exists $weather->{READINGS}{temperatur},
  'no derived reading when opt-in is absent');
is($server->{FRAMES_OK}, 1, 'default-name telegram counted as accepted');

$attr{$weather_name}{stripReadingPrefix} = 1;
WIFFI_Collector_ProcessFrame($server, $weather_raw, '192.0.2.26');
is($weather->{READINGS}{temperatur}{VAL}, '12.2',
  'opt-in strips w_ from temperature');
is($weather->{READINGS}{lux}{VAL}, '1747.2',
  'opt-in strips w_ from brightness');
is($weather->{READINGS}{wiffi_pump}{VAL}, 'false',
  'prefix wiffi_ remains untouched');
is($weather->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, '123',
  'Systeminfo prefix unchanged');
is($server->{FRAMES_OK}, 2, 'mapped telegram counted as accepted');

my $collision_raw = JSON::PP::encode_json({
  modultyp => 'weatherman',
  vars => [
    {homematic_name => 'w_lux', value => '9999'},
    {homematic_name => 'lux', value => '5555'},
  ],
  Systeminfo => {'MAC-Adresse' => '02:00:00:00:00:06',
    sec_seit_reset => '999'}
});
my $previous_error = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server, $collision_raw, '192.0.2.26');
is($server->{FRAMES_ERROR}, $previous_error+1,
  'mapped name collision rejects entire telegram');
is($server->{FRAMES_OK}, 2, 'collision does not count as success');
is($weather->{READINGS}{lux}{VAL}, '1747.2',
  'collision never writes partial weather values');
is($weather->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, '123',
  'collision never updates heartbeat');

my $reserved_raw = JSON::PP::encode_json({
  modultyp => 'weatherman',
  vars => [{homematic_name => 'w_state', value => 'bad'}],
  Systeminfo => {'MAC-Adresse' => '02:00:00:00:00:06'}
});
$previous_error = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server, $reserved_raw, '192.0.2.26');
is($server->{FRAMES_ERROR}, $previous_error+1,
  'mapped state reading cannot overwrite device state');
is($weather->{READINGS}{state}{VAL}, 'online',
  'reserved-name packet leaves device state unchanged');

# Malformed telegrams cannot autocreate.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, '{"modultyp":"PULSECOUNTER"', '192.0.2.21');
is($definitions, 0, 'truncated JSON creates nothing');
is($server->{FRAMES_ERROR}, 1, 'truncated JSON rejected');


# A genuinely malformed vars value after a good one must not publish ANY measurements,
# state, heartbeat, or success counter. This uses the isolated FHEM test double.
$server = start_case();
my $atomic_name = 'WIFFI_Atomic';
is(CommandDefine(undef,
  "$atomic_name WIFFI_DEVICE Collector 02:00:00:00:00:08"),
  undef, 'test target defined');
my $atomic_device = $defs{$atomic_name};
my $atomic_good = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"homematic_name":"w_counter1","value":"12.500"},'
  .'{"homematic_name":"w_counter2","value":"7"}'
  .'],"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:08",'
  .'"sec_seit_reset":"10"}}';
WIFFI_Collector_ProcessFrame($server, $atomic_good, '192.0.2.28');
is($server->{FRAMES_OK}, 1, 'baseline frame succeeds');
my %readings_before = map { $_ => $atomic_device->{READINGS}{$_}{VAL} }
  keys %{$atomic_device->{READINGS}};
my $atomic_bad = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"homematic_name":"w_counter1","value":"999"},'
  .'{"homematic_name":"w_counter2","value":[]}'
  .'],"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:08",'
  .'"sec_seit_reset":"999"}}';
my $errors_before = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server, $atomic_bad, '192.0.2.28');
is($server->{FRAMES_ERROR}, $errors_before + 1, 'bad frame increases FRAMES_ERROR');
is($server->{FRAMES_OK}, 1, 'bad frame does not increase FRAMES_OK');
my %readings_after = map { $_ => $atomic_device->{READINGS}{$_}{VAL} }
  keys %{$atomic_device->{READINGS}};
is_deeply(\%readings_after, \%readings_before,
  'bad frame leaves every reading including state and heartbeat unchanged');
is($atomic_device->{READINGS}{w_counter2}{VAL}, '7',
  'malformed telegram does not change previously known sensor values');
ok(grep(/vars\[1\].*unsupported value type/, @logs),
  'error reports entry index and reason without full payload');
ok(!grep(/999.*999/, @logs), 'error log does not contain full raw telegram');



# A maintainer can opt in to diagnostics containing the actual rejected frame.
# Default stays concise. Every repeated rejection still produces a new log.
$attr{Collector}{logRejectedPayload} = 1;
my $logs_before = scalar @logs;
$errors_before = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server, $atomic_bad, '192.0.2.28');
is($server->{FRAMES_ERROR}, $errors_before + 1,
  'rejection counter increments with payload logging enabled');
is(scalar(@logs), $logs_before + 1, 'one log per rejected parser telegram');
like($logs[-1], qr/\Q$atomic_bad\E/,
  'opted-in log contains complete rejected JSON telegram');
like($logs[-1], qr/vars\[1\]: unsupported value type/,
  'payload log also retains the validation reason');
$logs_before = scalar @logs;
WIFFI_Collector_ProcessFrame($server, $atomic_bad, '192.0.2.28');
is(scalar(@logs), $logs_before + 1,
  'identical recurring error is logged again, not rate-limited');

# Log structure remains a single line even if the invalid raw JSON contains
# actual newlines and control characters; raw data must not forge FHEM entries.
my $newline_bad = "{\"modultyp\":\n\x01}";
$logs_before = scalar @logs;
WIFFI_Collector_ProcessFrame($server, $newline_bad, '192.0.2.28');
is(scalar(@logs), $logs_before + 1, 'invalid JSON produces one log entry');
unlike($logs[-1], qr/[\r\n\x01]/,
  'logged invalid JSON cannot inject newlines or control bytes');
like($logs[-1], qr/\\x0A.*\\x01/,
  'line breaks and control bytes are escaped in the payload');

# Deliberately enormous bad frames are bounded even with logging enabled.
my $large_bad = '{"modultyp":"PULSECOUNTER","vars":[],"extra":"'
   .('X' x 17000).'","Systeminfo":{}}';
WIFFI_Collector_ProcessFrame($server, $large_bad, '192.0.2.28');
like($logs[-1], qr/truncated\): /, 'excessive raw payload is marked truncated');
ok(length($logs[-1]) < 17000,
  'large invalid payload cannot amplify a log record without limit');

# JSON null is a valid "no new value" marker. Publish all other readings;
# neither clear nor refresh old values for the null entries.
my $null_frame = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"homematic_name":"w_counter1","value":"15.200"},'
  .'{"homematic_name":"w_counter2","value":null},'
  .'{"homematic_name":"w_counter3","value":null}'
  .'],"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:08",'
  .'"sec_seit_reset":"11"}}';
$errors_before = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server, $null_frame, '192.0.2.28');
is($server->{FRAMES_ERROR}, $errors_before, 'valid null is not counted as error');
is($server->{FRAMES_OK}, 2, 'valid null frame is counted as delivered');
is($atomic_device->{READINGS}{w_counter1}{VAL}, '15.200',
  'other measurements update despite null entry');
is($atomic_device->{READINGS}{w_counter2}{VAL}, '7',
  'previous measurement is retained on null');
ok(!exists $atomic_device->{READINGS}{w_counter3},
  'null does not create a missing reading');
is($atomic_device->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, '11',
  'valid heartbeat updates despite null sensor');

# The heartbeat itself is optional; even null does not update its value.
my $null_heartbeat = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"homematic_name":"w_counter1","value":"16.500"}'
  .'],"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:08",'
  .'"sec_seit_reset":null}}';
WIFFI_Collector_ProcessFrame($server, $null_heartbeat, '192.0.2.28');
is($server->{FRAMES_OK}, 3, 'null optional heartbeat accepted');
is($atomic_device->{READINGS}{w_counter1}{VAL}, '16.500',
  'data published when optional heartbeat is null');
is($atomic_device->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, '11',
  'null heartbeat does not overwrite previous heartbeat');

# Malformed newly discovered frames must not autocreate a logical device.
$attr{Collector}{autocreate} = 1;
my $unknown_bad = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"homematic_name":"w_counter1","value":[]}'
  .'],"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:09",'
  .'"sec_seit_reset":20}}';
my $definitions_before = $definitions;
my $unknown_errors_before = $server->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($server, $unknown_bad, '192.0.2.29');
is($definitions, $definitions_before, 'bad unknown frame does not autocreate');
is($server->{FRAMES_ERROR}, $unknown_errors_before + 1,
  'bad unknown frame counted as invalid');


# A structurally valid newly discovered device may publish null sensor values.
my $unknown_null = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"homematic_name":"w_counter1","value":null},'
  .'{"homematic_name":"w_power1","value":"0"}'
  .'],"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:09",'
  .'"sec_seit_reset":20}}';
WIFFI_Collector_ProcessFrame($server, $unknown_null, '192.0.2.29');
is($definitions, $definitions_before + 1,
  'valid null sensor does not prevent autocreate');
ok(!exists $defs{WIFFI_020000000009}{READINGS}{w_counter1},
  'autocreated null value does not fabricate a reading');
is($defs{WIFFI_020000000009}{READINGS}{w_power1}{VAL}, '0',
  'other measurements survive valid null');


# Not just decoding errors: identity and mapping failures include the frame.
$server = start_case();
$attr{Collector}{logRejectedPayload} = 1;
my $identity_packet = telegram('02:00:00:00:00:01', '192.0.2.21', '5');
my $identity_second = { NAME => 'Duplicate', TYPE => 'WIFFI_DEVICE',
  IODev => $server, MAC => '02:00:00:00:00:01' };
my $identity_first = { NAME => 'Original', TYPE => 'WIFFI_DEVICE',
  IODev => $server, MAC => '02:00:00:00:00:01' };
$defs{Duplicate} = $identity_second;
$defs{Original} = $identity_first;
WIFFI_Collector_ProcessFrame($server, $identity_packet, '192.0.2.21');
is($server->{FRAMES_ERROR}, 1, 'duplicate identities counted as error');
like($logs[-1], qr/WIFFI identity conflict/,
  'identity problem included in reason');
like($logs[-1], qr/\Q$identity_packet\E/,
  'identity rejection includes opted-in JSON');


# Disabling a logical device suppresses only its telemetry, without causing
# duplicate autocreate or misleading aggregate frame counters.
$server = start_case();
$attr{Collector}{autocreate} = 1;
my $disabled_mac = '02:00:00:00:00:0A';
my $disabled_name = 'WIFFI_02000000000A';
WIFFI_Collector_ProcessFrame($server,
  telegram($disabled_mac,'192.0.2.31','10','wiffi-pump'),'192.0.2.31');
my $disabled_device = $defs{$disabled_name};
is($disabled_device->{READINGS}{w_counter1}{VAL},'10',
  'initial reading published before device is disabled');
my $previous_heartbeat = $disabled_device->{READINGS}{Systeminfo_sec_seit_reset}{VAL};
$attr{$disabled_name}{disable} = 1;
WIFFI_Collector_ProcessFrame($server,
  telegram($disabled_mac,'192.0.2.31','999','PULSECOUNTER'),'192.0.2.31');
is($disabled_device->{READINGS}{w_counter1}{VAL},'10',
  'disabled device ignores later measurement');
is($disabled_device->{READINGS}{Systeminfo_sec_seit_reset}{VAL},$previous_heartbeat,
  'disabled device does not refresh heartbeat');
is($disabled_device->{MODULTYP},'wiffi-pump',
  'disabled device does not update module type');
is($server->{FRAMES_OK},1,'ignored frame is not counted as published');
is($server->{FRAMES_ERROR},0,'ignored frame is not a malformed frame');
is($server->{FRAMES_UNKNOWN},0,'disabled registered MAC is still known');
is($server->{AUTOCREATED},1,'disabled known MAC does not autocreate replacement');
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:0B','192.0.2.32','20'),'192.0.2.32');
is($server->{FRAMES_OK},2,'another device still updates on shared collector');
ok($defs{WIFFI_02000000000B},'another MAC can still be autocreated');
delete $attr{$disabled_name}{disable};
WIFFI_Collector_ProcessFrame($server,
  telegram($disabled_mac,'192.0.2.31','30','wiffi-pump'),'192.0.2.31');
is($disabled_device->{READINGS}{w_counter1}{VAL},'30',
  're-enabled known MAC immediately resumes telemetry');
is($server->{FRAMES_OK},3,'re-enabled frame counted as published');
is($server->{AUTOCREATED},2,'no extra device created on re-enable');

# Autocreate must bind the *receiving* collector even when multiple providers
# advertise the same logical client type (no generic last-defined guessing).
$server = start_case();
$attr{Collector}{autocreate} = 1;
$defs{OtherCollector} = {
  NAME=>'OtherCollector', TYPE=>'WIFFI_Collector',
  FRAMES_OK=>0, FRAMES_ERROR=>0, FRAMES_UNKNOWN=>0
};
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:0F','192.0.2.47','1'),'192.0.2.47');
my $pinned = $defs{WIFFI_02000000000F};
ok($pinned, 'autocreate works with two collectors defined');
is($pinned->{IODev},$server, 'new device IODev is receiving collector');
is($attr{$pinned->{NAME}}{IODev},'Collector','source IODev persisted');
is($pinned->{DEF},'02:00:00:00:00:0F','saved device DEF contains MAC only');

# Interactive autocreate uses the same persistent IODev path as a
# manual definition, before the DEFINED event is sent.
$init_done = 1;
$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_define = sub {
  my ($name) = @_;
  is($attr{$name}{IODev}, 'Collector',
    'IODev is already a real attribute when DEFINED fires');
  is($defs{$name}{DEF}, '02:00:00:00:00:01',
    'interactive autocreate already normalized DEF to MAC-only');
};
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{AUTOCREATED}, 1,
  'runtime autocreate with persisted IODev succeeds');
is($server->{FRAMES_OK}, 1,
  'runtime autocreate publishes first telegram');

# A synchronous ATTR callback can remove an attribute while Define runs:
# the device must not be accepted with an unpersisted IODev.
$server = start_case();
$attr{Collector}{autocreate} = 1;
$on_attr = sub { delete $attr{$_[0]}{IODev} if $_[1] eq 'IODev' };
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
is($server->{AUTOCREATED}, 0,
  'runtime autocreate rejects missing persisted IODev');
ok(!$defs{WIFFI_020000000001},
  'failed runtime define does not leave a half-configured logical device');
$init_done = 0;

done_testing();
