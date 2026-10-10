# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use lib 'FHEM';
use WIFFI::Parser;

is(WIFFI::Parser::normalize_mac('b4:e6:2d:17:db:7'),
   'B4:E6:2D:17:DB:07', 'short MAC octet is padded');
is(WIFFI::Parser::normalize_mac('DE:AD:BE:EF:FE:01'),
   'DE:AD:BE:EF:FE:01', 'PULSECOUNTER MAC accepted');
ok(!defined WIFFI::Parser::normalize_mac('deadbeef'), 'invalid MAC rejected');

my $raw = '{"modultyp":"PULSECOUNTER","vars":['
  .'{"name":"0","homematic_name":"w_counterIP","value":"192.168.5.28"},'
  .'{"name":"11","homematic_name":"w_counter1","type":"number","value":689323.62},'
  .'{"name":"12","homematic_name":"w_power1","value":0},'
  .'{"name":"15","homematic_name":"w_counter3","value":720575983170204.2}'
  .'],"Systeminfo":{"MAC-Adresse":"DE:AD:BE:EF:FE:01","sec_seit_reset":"69","firmware":"counter_LAN41"}}';
my $p = WIFFI::Parser::decode($raw);
is($p->{mac}, 'DE:AD:BE:EF:FE:01', 'identification');
is($p->{modultyp}, 'PULSECOUNTER', 'module type');
is($p->{reported_ip}, '192.168.5.28', 'IP');
is($p->{readings}{w_counter1}, '689323.62', 'native CCU reading');
is($p->{readings}{Systeminfo_sec_seit_reset}, '69', 'heartbeat reading');
is($p->{readings}{w_counter3}, '720575983170204.2',
   'large number preserved as decimal');

my $buf = '{"a":1}'."\x03".'{"b":2}'."\x04".'{"unfinished":';
my @frames = WIFFI::Parser::extract_frames(\$buf);
is_deeply(\@frames, ['{"a":1}', '{"b":2}'], 'multiple TCP frames');
is($buf, '{"unfinished":', 'incomplete suffix retained');
$buf .= 'true}'."\x03";
@frames = WIFFI::Parser::extract_frames(\$buf);
is_deeply(\@frames, ['{"unfinished":true}'], 'split frames reassembled');

my $duplicate = '{"modultyp":"wiffi-pump","vars":['
  .'{"homematic_name":"wiffi_pump","value":"false"},'
  .'{"homematic_name":"wiffi_pump","value":"true"}'
  .'],"Systeminfo":{"MAC-Adresse":"b4:e6:2d:17:db:7"}}';
eval { WIFFI::Parser::decode($duplicate) };
like($@, qr/duplicate CCU name/, 'duplicate names rejected');

done_testing();
