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
our (%defs, %attr);
my ($definitions, $on_define, $on_attr, $forced_error);
my @logs;
sub AttrVal {
  my ($name, $key, $fallback) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $fallback;
}
sub Log3 { push @logs, $_[2] }
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
  $attr{$name}{$key} = $value;
  $on_attr->($name, $key) if $on_attr;
  return undef;
}
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
is($device->{COLLECTOR}, 'Collector', 'association retained');
is($device->{READINGS}{w_counter1}{VAL}, '12.500', 'native CCU reading updated');
is($device->{READINGS}{Systeminfo_sec_seit_reset}{VAL}, '120', 'heartbeat is present');
ok($device->{FUUID}, 'FHEM CommandDefine assigned a synthetic identity');
is($attr{WIFFI_020000000001}{room}, 'WIFFI', 'autocreated device has WIFFI room');
ok(!exists $attr{WIFFI_020000000001}{'event-on-change-reading'},
   'no default event-on-change-reading filter');
ok(!exists $attr{WIFFI_020000000001}{'event-on-update-reading'},
   'no default event-on-update-reading filter');
ok(!exists $attr{WIFFI_020000000001}{DbLogExclude},
   'no default DbLogExclude filter');

WIFFI_Collector_ProcessFrame($server,
  telegram('2:0:0:0:0:1', '192.0.2.21', '12.750'), '192.0.2.21');
is($definitions, 1, 'normalized MAC does not cause a duplicate');
$attr{WIFFI_020000000001}{room} = 'Energie';
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '12.760'), '192.0.2.21');
is($attr{WIFFI_020000000001}{room}, 'Energie',
  'autocreate does not overwrite existing custom room');
$attr{WIFFI_020000000001}{DbLogExclude} = '^w_counterIP
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
  COLLECTOR => 'Collector', MAC => '02:00:00:00:00:01',
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
  'MyPulseCounter WIFFI_DEVICE Collector 02:00:00:00:00:01');
delete $device->{OLDDEF};
is($modify_error, undef, 'explicit modify accepted');
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

# Full MAC prevents aliasing on identical trailing octets.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
WIFFI_Collector_ProcessFrame($server,
  telegram('06:00:00:00:00:01', '192.0.2.22', '22'), '192.0.2.22');
ok($defs{WIFFI_020000000001} && $defs{WIFFI_060000000001},
  'distinct full-MAC names for same trailing bytes');
is($definitions, 2, 'both devices created once');

# Malformed telegrams cannot autocreate.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, '{"modultyp":"PULSECOUNTER"', '192.0.2.21');
is($definitions, 0, 'truncated JSON creates nothing');
is($server->{FRAMES_ERROR}, 1, 'truncated JSON rejected');

done_testing();
;
WIFFI_Collector_ProcessFrame($server,
  telegram('02:00:00:00:00:01', '192.0.2.21', '12.770'), '192.0.2.21');
is($attr{WIFFI_020000000001}{DbLogExclude}, '^w_counterIP
is($device->{READINGS}{w_counter1}{VAL}, '12.760', 'known device updated');

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
  COLLECTOR => 'Collector', MAC => '02:00:00:00:00:01',
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
  'MyPulseCounter WIFFI_DEVICE Collector 02:00:00:00:00:01');
delete $device->{OLDDEF};
is($modify_error, undef, 'explicit modify accepted');
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

# Full MAC prevents aliasing on identical trailing octets.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
WIFFI_Collector_ProcessFrame($server,
  telegram('06:00:00:00:00:01', '192.0.2.22', '22'), '192.0.2.22');
ok($defs{WIFFI_020000000001} && $defs{WIFFI_060000000001},
  'distinct full-MAC names for same trailing bytes');
is($definitions, 2, 'both devices created once');

# Malformed telegrams cannot autocreate.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, '{"modultyp":"PULSECOUNTER"', '192.0.2.21');
is($definitions, 0, 'truncated JSON creates nothing');
is($server->{FRAMES_ERROR}, 1, 'truncated JSON rejected');

done_testing();
,
   'user-configured DbLogExclude is not overwritten by further telegrams');
is($device->{READINGS}{w_counter1}{VAL}, '12.760', 'known device updated');

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
  COLLECTOR => 'Collector', MAC => '02:00:00:00:00:01',
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
  'MyPulseCounter WIFFI_DEVICE Collector 02:00:00:00:00:01');
delete $device->{OLDDEF};
is($modify_error, undef, 'explicit modify accepted');
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

# Full MAC prevents aliasing on identical trailing octets.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, $raw, '192.0.2.21');
WIFFI_Collector_ProcessFrame($server,
  telegram('06:00:00:00:00:01', '192.0.2.22', '22'), '192.0.2.22');
ok($defs{WIFFI_020000000001} && $defs{WIFFI_060000000001},
  'distinct full-MAC names for same trailing bytes');
is($definitions, 2, 'both devices created once');

# Malformed telegrams cannot autocreate.
$server = start_case();
$attr{Collector}{autocreate} = 1;
WIFFI_Collector_ProcessFrame($server, '{"modultyp":"PULSECOUNTER"', '192.0.2.21');
is($definitions, 0, 'truncated JSON creates nothing');
is($server->{FRAMES_ERROR}, 1, 'truncated JSON rejected');

done_testing();
