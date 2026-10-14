# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use lib 't/lib';
require './FHEM/00_WIFFI_Collector.pm';

is(WIFFI_Collector_NormalizeMac('b4:e6:2d:17:db:7'),
   'B4:E6:2D:17:DB:07', 'short MAC octet is padded');
is(WIFFI_Collector_NormalizeMac('DE:AD:BE:EF:FE:01'),
   'DE:AD:BE:EF:FE:01', 'PULSECOUNTER MAC accepted');
ok(!defined WIFFI_Collector_NormalizeMac('deadbeef'), 'invalid MAC rejected');

my $raw = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"name":"0","homematic_name":"w_counterIP","value":"192.168.5.28"},'
  .'{"name":"11","homematic_name":"w_counter1","type":"number","value":689323.62},'
  .'{"name":"12","homematic_name":"w_power1","value":0},'
  .'{"name":"15","homematic_name":"w_counter3","value":720575983170204.2}'
  .'],"Systeminfo":{"MAC-Adresse":"DE:AD:BE:EF:FE:01","sec_seit_reset":"69","firmware":"counter_LAN41"}}';
my $p = WIFFI_Collector_Decode($raw);
is($p->{mac}, 'DE:AD:BE:EF:FE:01', 'identification');
is($p->{modultyp}, 'PULSECOUNTER', 'module type');
is($p->{reported_ip}, '192.168.5.28', 'IP');
is($p->{readings}{w_counter1}, '689323.62', 'native CCU reading');
is($p->{readings}{Systeminfo_sec_seit_reset}, '69', 'heartbeat reading');
is($p->{readings}{w_counter3}, '720575983170204.2',
   'large number preserved as decimal');

my $buf = '{"a":1}'."\x03".'{"b":2}'."\x04".'{"unfinished":';
my @frames = WIFFI_Collector_ExtractFrames(\$buf);
is_deeply(\@frames, ['{"a":1}', '{"b":2}'], 'multiple TCP frames');
is($buf, '{"unfinished":', 'incomplete suffix retained');
$buf .= 'true}'."\x03";
@frames = WIFFI_Collector_ExtractFrames(\$buf);
is_deeply(\@frames, ['{"unfinished":true}'], 'split frames reassembled');

my $duplicate = '{"modultyp":"wiffi-pump","vars":['
  .'{"homematic_name":"wiffi_pump","value":"false"},'
  .'{"homematic_name":"wiffi_pump","value":"true"}'
  .'],"Systeminfo":{"MAC-Adresse":"b4:e6:2d:17:db:7"}}';
eval { WIFFI_Collector_Decode($duplicate) };
like($@, qr/duplicate CCU name/, 'duplicate names rejected');


# Absent or JSON-null optional measurements do not publish new readings.
# Present non-null values and the overall structure must still be valid.
my $weather = '{"modultyp":"weatherman","vars":['
  .'{"homematic_name":"w_temperatur","value":"12.3","type":"number"}'
  .'],"Systeminfo":{"MAC-Adresse":"e8:db:84:98:c6:d3","sec_seit_reset":77}}';

my $weather_zero = '{"modultyp":"weatherman","vars":['
  .'{"homematic_name":"w_lux","type":"number","value":0},'
  .'{"homematic_name":"w_temperatur","value":"12.3"}'
  .'],"Systeminfo":{"MAC-Adresse":"e8:db:84:98:c6:d3","sec_seit_reset":78}}';
my $weather_zero_packet = WIFFI_Collector_Decode($weather_zero);
is($weather_zero_packet->{readings}{w_lux}, '0',
   'WEATHERMAN zero brightness is a legitimate measurement, not null');
is($weather_zero_packet->{readings}{Systeminfo_sec_seit_reset}, '78',
   'valid zero brightness still updates heartbeat');
ok(!exists $weather_zero_packet->{readings}{'Systeminfo_MAC-Adresse'},
   'hyphenated MAC identity is not published as a reading');

# A null sample is a valid "no new value"; zero and empty strings remain data.
my $weather_null = '{"modultyp":"weatherman","vars":['
  .'{"homematic_name":"w_lux","value":null,"type":"number"},'
  .'{"homematic_name":"w_temperatur","value":"0"},'
  .'{"homematic_name":"w_text","value":""},'
  .'{"homematic_name":"w_optional","name":null,"type":null,"value":1}'
  .'],"Systeminfo":{"MAC-Adresse":"e8:db:84:98:c6:d3",'
  .'"sec_seit_reset":null,"firmware":"test"}}';
my $weather_null_packet = WIFFI_Collector_Decode($weather_null);
ok(!exists $weather_null_packet->{readings}{w_lux},
  'null brightness generates no reading');
ok(!exists $weather_null_packet->{readings}{Systeminfo_sec_seit_reset},
  'null optional heartbeat generates no reading');
is($weather_null_packet->{readings}{w_temperatur}, '0',
  'string zero remains data alongside null');
is($weather_null_packet->{readings}{w_text}, '',
  'empty string remains data alongside null');
is($weather_null_packet->{readings}{w_optional}, '1',
  'null optional metadata does not reject non-null value');
is($weather_null_packet->{readings}{Systeminfo_firmware}, 'test',
  'other Systeminfo values survive null entries');

my $weather_packet = WIFFI_Collector_Decode($weather);
is($weather_packet->{readings}{w_temperatur}, '12.3',
  'hypothetically omitted optional brightness accepted');
ok(!exists $weather_packet->{readings}{w_lux},
  'no invented brightness reading');

my $pump = '{"modultyp":"wiffi-pump","vars":['
  .'{"homematic_name":"wiffi_pump","type":"boolean","value":false},'
  .'{"homematic_name":"wiffi_ntc","type":"boolean","value":"true"}'
  .'],"Systeminfo":{"MAC-Adresse":"b4:e6:2d:17:db:07","sec_seit_reset":1,'
  .'"restart":false}}';
my $pump_packet = WIFFI_Collector_Decode($pump);
is($pump_packet->{readings}{wiffi_pump}, 'false', 'JSON boolean preserved');
is($pump_packet->{readings}{wiffi_ntc}, 'true', 'string boolean preserved');
is($pump_packet->{readings}{Systeminfo_restart}, 'false',
   'valid Systeminfo boolean not silently discarded');

my $prefix = '{"modultyp":"weatherman","vars":';
my $system = ',"Systeminfo":{"MAC-Adresse":"e8:db:84:98:c6:d3","sec_seit_reset":1}}';
my @bad_entries = (
  ['non-object entry', '[{"homematic_name":"w_ok","value":1},null]',
     qr/vars\[1\]: expected JSON object/],
  ['missing name', '[{"value":1}]', qr/invalid homematic_name/],
  ['null name', '[{"homematic_name":null,"value":1}]', qr/invalid homematic_name/],
  ['object name', '[{"homematic_name":{},"value":1}]', qr/invalid homematic_name/],
  ['invalid name', '[{"homematic_name":"bad name","value":1}]',
     qr/invalid homematic_name/],
  ['missing value', '[{"homematic_name":"w_test"}]', qr/missing value/],
  ['duplicate after null', '[{"homematic_name":"w_test","value":null},'
    .'{"homematic_name":"w_test","value":1}]', qr/duplicate CCU name/],
  ['array value', '[{"homematic_name":"w_test","value":[1]}]',
     qr/unsupported value type/],
  ['object value', '[{"homematic_name":"w_test","value":{}}]',
     qr/unsupported value type/],
  ['invalid optional identifier', '[{"name":[],"homematic_name":"w_test","value":1}]',
     qr/invalid name/],
  ['invalid optional type', '[{"type":{},"homematic_name":"w_test","value":1}]',
     qr/invalid type/],
  ['duplicate name', '[{"homematic_name":"w_test","value":1},'
    .'{"homematic_name":"w_test","value":2}]', qr/duplicate CCU name/],
  ['reserved state', '[{"homematic_name":"state","value":1}]',
     qr/reserved state/],
  ['Systeminfo collision', '[{"homematic_name":"Systeminfo_sec_seit_reset","value":1}]',
     qr/reading name collision/],
  ['Systeminfo collision despite null', '[{"homematic_name":"Systeminfo_sec_seit_reset","value":null}]',
     qr/reading name collision/],
);
for my $case (@bad_entries) {
  my ($label, $vars, $expected) = @$case;
  my $result = eval { WIFFI_Collector_Decode($prefix.$vars.$system) };
  ok(!defined($result) && $@ =~ $expected, "$label rejected");
}

my @bad_system = (
  ['missing Systeminfo', '{"modultyp":"weatherman","vars":[]}', qr/missing Systeminfo/],
  ['missing MAC', '{"modultyp":"weatherman","vars":[],"Systeminfo":{"sec_seit_reset":1}}',
     qr/invalid MAC-Adresse/],
  ['invalid MAC type', '{"modultyp":"weatherman","vars":[],"Systeminfo":{"MAC-Adresse":[]}}',
     qr/invalid MAC-Adresse/],
  ['null MAC', '{"modultyp":"weatherman","vars":[],"Systeminfo":{"MAC-Adresse":null}}',
     qr/invalid MAC-Adresse/],
  ['object Systeminfo value', '{"modultyp":"weatherman","vars":[],"Systeminfo":{'
     .'"MAC-Adresse":"e8:db:84:98:c6:d3","other":{}}}',
     qr/Systeminfo: unsupported value type/],
  ['invalid Systeminfo key', '{"modultyp":"weatherman","vars":[],"Systeminfo":{'
     .'"MAC-Adresse":"e8:db:84:98:c6:d3","bad field":"x"}}',
     qr/Systeminfo: invalid field name/],
  ['invalid module type', '{"modultyp":{},"vars":[],"Systeminfo":{'
     .'"MAC-Adresse":"e8:db:84:98:c6:d3"}}',
     qr/invalid modultyp/],
);
for my $case (@bad_system) {
  my ($label, $telegram, $expected) = @$case;
  my $result = eval { WIFFI_Collector_Decode($telegram) };
  ok(!defined($result) && $@ =~ $expected, "$label rejected");
}

done_testing();
