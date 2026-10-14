# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 't/lib';

# Focused FHEM IODev contract double. Real FHEM IODev state/readings and
# configDB persistence require a separate short installation smoke check.
our (%defs, %attr, $init_done, $readingFnAttributes);
$init_done = 1;
$readingFnAttributes = '';
my @closed;
sub AttrVal {
  my ($name,$key,$default) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $default;
}
sub Log3 {}
sub TimeNow { return '2026-10-14 16:00:00' }
sub HttpUtils_Close { push @closed, $_[0] }
sub readingsSingleUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
sub readingsBeginUpdate {}
sub readingsBulkUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
sub readingsEndUpdate {}
require './t/lib/WiffiIOStub.pm';
require './FHEM/00_WIFFI_Collector.pm';
require './FHEM/10_WIFFI_DEVICE.pm';

sub io {
  my ($name) = @_;
  $defs{$name} = {
    NAME=>$name, TYPE=>'WIFFI_Collector', FRAMES_OK=>0,
    FRAMES_ERROR=>0, FRAMES_UNKNOWN=>0, AUTOCREATED=>0
  };
  return $defs{$name};
}
sub device {
  my ($name,$definition) = @_;
  my $hash = {
    NAME=>$name, TYPE=>'WIFFI_DEVICE', DEF=>$definition
  };
  $defs{$name}=$hash;
  my $error = WIFFI_DEVICE_Define($hash,"$name WIFFI_DEVICE $definition");
  is($error,undef,"$name definition succeeds");
  return $hash;
}
sub set_io {
  my ($name,$value) = @_;
  my $error = WIFFI_DEVICE_Attr('set',$name,'IODev',$value);
  return $error if $error;
  $attr{$name}{IODev} = $value;
  AssignIoPort($defs{$name},$value);
  return undef;
}
sub packet {
  my ($mac,$value) = @_;
  return JSON::PP::encode_json({
    modultyp=>'PULSECOUNTER',
    vars=>[{homematic_name=>'w_counter1',value=>$value}],
    Systeminfo=>{'MAC-Adresse'=>$mac}
  });
}

my %module;
WIFFI_Collector_Initialize(\%module);
is($module{Clients}, ':WIFFI_DEVICE:',
   'collector advertises logical WIFFI devices for core AssignIoPort');
my $one = io('C1');
my $two = io('C2');
my $d = device('One','02:00:00:00:00:01');
ok(!exists $d->{COLLECTOR},'new device has no shadow COLLECTOR internal');
is(set_io('One','C1'),undef,'explicit IODev assignment accepted');
is($d->{IODev},$one,'IODev holds collector hash reference');
is($d->{DEF},'02:00:00:00:00:01','new definition remains MAC-only');
WIFFI_Collector_ProcessFrame($one,packet('02:00:00:00:00:01','1'),'192.0.2.1');
is($d->{READINGS}{w_counter1}{VAL},'1','assigned collector dispatches');
WIFFI_Collector_ProcessFrame($two,packet('02:00:00:00:00:01','99'),'192.0.2.2');
is($two->{FRAMES_UNKNOWN},1,'unassigned second collector ignores the device MAC');
is($d->{READINGS}{w_counter1}{VAL},'1','wrong collector does not modify readings');

my $pending={ request=>'old' };
$d->{'.WIFFI_HTTP'} = $pending;
is(set_io('One','C2'),undef,'manual IODev reassignment accepted');
is($d->{IODev},$two,'new collector becomes routing owner');
is($closed[-1],$pending,'switch cancels pending HTTP request');
ok(!exists $d->{PEER} && !exists $d->{MODULTYP},
   'reassignment invalidates learned peer and module type');
WIFFI_Collector_ProcessFrame($one,packet('02:00:00:00:00:01','3'),'192.0.2.1');
is($d->{READINGS}{w_counter1}{VAL},'1','former collector no longer routes');
WIFFI_Collector_ProcessFrame($two,packet('02:00:00:00:00:01','4'),'192.0.2.2');
is($d->{READINGS}{w_counter1}{VAL},'4','new collector routes and learns peer');
like(WIFFI_DEVICE_Attr('set','One','IODev','NoSuchDevice'),
  qr/IODev must be/, 'nonexistent IO device rejected while FHEM is running');
$defs{Dummy} = {NAME=>'Dummy',TYPE=>'dummy'};
like(WIFFI_DEVICE_Attr('set','One','IODev','Dummy'),
  qr/IODev must be/, 'foreign module cannot hijack IODev');
is($d->{IODev},$two,'invalid IODev request does not mutate mapping');

is(WIFFI_DEVICE_Attr('del','One','IODev'),undef,
  'deleteattr callback is accepted');
delete $attr{One}{IODev};
ok(!exists $d->{IODev},'deleteattr clears routing pointer');
ok(!exists $d->{READINGS}{IODev},'deleteattr removes stale IODev reading');
ok(!exists $d->{PEER},'deleteattr invalidates learned HTTP destination');
WIFFI_Collector_ProcessFrame($two,packet('02:00:00:00:00:01','8'),'192.0.2.2');
is($d->{READINGS}{w_counter1}{VAL},'4',
  'unbound device never receives telegrams accidentally');

my $legacy = device('Legacy','C1 02:00:00:00:00:09');
is($legacy->{IODev},$one,'legacy collector name is an IODev hint');
ok(!exists $legacy->{COLLECTOR},'legacy device also has no shadow COLLECTOR');
is($legacy->{DEF},'C1 02:00:00:00:00:09',
  'legacy syntax is preserved pending explicit migration');
is(set_io('Legacy','C1'),undef,'legacy owner explicitly saved as IODev attribute');
$legacy->{OLDDEF}=$legacy->{DEF};
$legacy->{DEF}='02:00:00:00:00:09';
is(WIFFI_DEVICE_Define($legacy,'Legacy WIFFI_DEVICE 02:00:00:00:00:09'),
  undef,'legacy device can be modified in-place to new MAC-only syntax');
delete $legacy->{OLDDEF};
is($legacy->{IODev},$one,'migration retains assigned collector');
is($legacy->{DEF},'02:00:00:00:00:09',
  'migration keeps name, device hash and clean DEF');
is($legacy->{MAC},'02:00:00:00:00:09','migration retains physical MAC');
WIFFI_Collector_ProcessFrame($one,packet('02:00:00:00:00:09','42'),'192.0.2.9');
is($legacy->{READINGS}{w_counter1}{VAL},'42','migrated device receives telemetry');

# A configDB restore may read a legacy logical device before the IO parent.
$init_done=0;
my $deferred=device('Deferred','C3 02:00:00:00:00:0A');
is($deferred->{IODevMissing},1,'startup defers missing collector binding');
is($deferred->{IODevName},'C3','deferred owner is specific, never arbitrary');
my $late=io('C3');
AssignIoPort($deferred,$deferred->{IODevName});
is($deferred->{IODev},$late,'startup can resolve deferred collector by name');
$init_done=1;

done_testing();
