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
my (@closed, @attr_commands);
my $io_number = 0;
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
    NAME=>$name, TYPE=>'WIFFI_Collector', NR=>++$io_number, FRAMES_OK=>0,
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
  fhem_setIoDev($defs{$name},$value);
  return undef;
}
sub CommandAttr {
  my ($cl,$statement) = @_;
  my ($name,$key,$value) = split /\s+/, $statement, 3;
  if ($key eq 'IODev') {
    push @attr_commands, "$name IODev $value";
    return set_io($name,$value);
  }
  return 'unsupported attribute in test';
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
my $single = device('Single','02:00:00:00:00:0B');
is($single->{IODev},$one,'single available collector is auto-selected');
is($attr{Single}{IODev},'C1',
  'single collector is saved as real IODev attribute during define');
is($single->{DEF},'02:00:00:00:00:0B',
  'single-collector manual DEF remains MAC-only');
is_deeply(\@attr_commands,['Single IODev C1'],
  'manual define stores native FHEM attribute via CommandAttr');

my $two = io('C2');
my $d = device('One','02:00:00:00:00:01');
ok(!exists $d->{COLLECTOR},'new device has no shadow COLLECTOR internal');
ok(!exists $d->{IODev} && !exists $attr{One}{IODev},
  'MAC-only define with multiple collectors does not select an arbitrary IODev');
is(set_io('One','C1'),undef,'explicit IODev assignment accepted after define');
is($d->{IODev},$one,'IODev holds collector hash reference');
is($d->{DEF},'02:00:00:00:00:01','new definition remains MAC-only');
WIFFI_Collector_ProcessFrame($one,packet('02:00:00:00:00:01','1'),'192.0.2.1');
is($d->{READINGS}{w_counter1}{VAL},'1','assigned collector dispatches');
my $io_conflict = JSON::PP::encode_json({
  modultyp=>'PULSECOUNTER',
  vars=>[{homematic_name=>'IODev',value=>'untrusted'}],
  Systeminfo=>{'MAC-Adresse'=>'02:00:00:00:00:01'}
});
my $errors_before = $one->{FRAMES_ERROR};
WIFFI_Collector_ProcessFrame($one,$io_conflict,'192.0.2.1');
is($one->{FRAMES_ERROR},$errors_before+1,
  'untrusted IODev measurement is rejected instead of overwriting FHEM IO binding');
is($d->{READINGS}{IODev}{VAL},'C1',
  'invalid IODev measurement leaves FHEM IODev association reading intact');
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
# A physical IO rename changes the provider name before its RenameFn runs.
$defs{C2Renamed}=delete $defs{C2};
$two->{NAME}='C2Renamed';
WIFFI_Collector_Rename('C2Renamed','C2');
is($d->{IODev},$two,'renamed collector keeps the same IODev reference');
is($attr{One}{IODev},'C2Renamed','rename persists updated IODev attribute');

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
is($legacy->{IODev},$one,'explicit collector is associated during define');
ok(!exists $legacy->{COLLECTOR},'explicit device has no shadow COLLECTOR');
is($legacy->{DEF},'02:00:00:00:00:09',
  'explicit manual define automatically keeps only MAC in DEF');
is($attr{Legacy}{IODev},'C1',
  'explicit manual collector is automatically persisted as IODev attribute');
like(join('|',@attr_commands), qr/Legacy IODev C1/,
  'explicit manual definition used CommandAttr');
is($legacy->{MAC},'02:00:00:00:00:09','migration retains physical MAC');
WIFFI_Collector_ProcessFrame($one,packet('02:00:00:00:00:09','42'),'192.0.2.9');
is($legacy->{READINGS}{w_counter1}{VAL},'42','migrated device receives telemetry');

# A configDB restore may read a legacy logical device before the IO parent.
# Config is already persisted: DefFn must not rewrite it before its attrs load.
$init_done=0;
my $previous_attrs = scalar @attr_commands;
my $deferred=device('Deferred','C3 02:00:00:00:00:0A');
is($deferred->{IODevMissing},1,'startup defers missing collector binding');
is($deferred->{IODevName},'C3','deferred owner is specific, never arbitrary');
is($deferred->{DEF},'C3 02:00:00:00:00:0A',
  'configDB restore does not silently rewrite pre-existing legacy DEF');
is(scalar @attr_commands,$previous_attrs,
  'configDB restore does not create an IODev attribute');
my $late=io('C3');
fhem_setIoDev($deferred,$deferred->{IODevName});
is($deferred->{IODev},$late,'startup can resolve deferred collector by name');
is(set_io('Deferred','C3'),undef,'operator can persist IODev after startup');
$init_done=1;
$deferred->{OLDDEF} = $deferred->{DEF};
$deferred->{DEF} = '02:00:00:00:00:0A';
is(WIFFI_DEVICE_Define($deferred,'Deferred WIFFI_DEVICE 02:00:00:00:00:0A'),
  undef,'manual modify migrates a restored definition');
delete $deferred->{OLDDEF};
is($deferred->{DEF},'02:00:00:00:00:0A',
  'migration preserves MAC-only DEF');
is($deferred->{IODev},$late,'migration keeps prior IODev');
is($attr{Deferred}{IODev},'C3','existing persistent assignment is retained');

# Negative controls: the double must reproduce the actual core behaviors
# that made the previous implementation incorrectly choose another collector.
my $core_probe = {NAME=>'CoreProbe',TYPE=>'WIFFI_DEVICE'};
AssignIoPort($core_probe);
is($core_probe->{IODev},$late,'core double selects the last compatible IO');
$attr{C1}{disable}=1;
$core_probe = {NAME=>'CoreDisabledProbe',TYPE=>'WIFFI_DEVICE'};
AssignIoPort($core_probe,'C1');
is($core_probe->{IODev},$late,'core double falls back from disabled proposed IO');

$init_done=0;
my $attr_count = scalar @attr_commands;
my $unbound = device('RestoredUnbound','02:00:00:00:00:20');
ok(!exists $unbound->{IODev},'startup with multiple IOs stays unbound');
ok(!exists $unbound->{IODevMissing},
  'startup does not invite finish_init to select an arbitrary IO');
$unbound->{READINGS}{IODev}{VAL}='C2Renamed';
$unbound->{OLDDEF}=$unbound->{DEF};
is(WIFFI_DEVICE_Define($unbound,'RestoredUnbound WIFFI_DEVICE 02:00:00:00:00:20'),
  undef,'MAC-only redefinition accepted without configured owner');
ok(!exists $unbound->{IODev},'old IODev reading cannot implicitly select owner');
delete $unbound->{OLDDEF};

my $disabled_owner = device('RestoredDisabled','C1 02:00:00:00:00:21');
is($disabled_owner->{IODev},$one,'legacy startup retains explicit disabled IO');
is($disabled_owner->{READINGS}{IODev}{VAL},'C1','IODev reading matches disabled owner');
is(scalar @attr_commands,$attr_count,'startup does not write persistent attrs');
is(set_io('RestoredUnbound','C1'),undef,'saved attr can bind after MAC-only restore');
is($unbound->{IODev},$one,'saved attr uses its disabled IO without fallback');
$init_done=1;
my $manual_disabled = device('ManualDisabled','C1 02:00:00:00:00:22');
is($manual_disabled->{IODev},$one,'explicit manual define also allows disabled IO');
is($attr{ManualDisabled}{IODev},'C1','manual disabled IO binding is persistent');
delete $attr{C1}{disable};

# No collector at interactive define: no invented persistent IODev.
delete $defs{C1}; delete $defs{C2Renamed}; delete $defs{C3};
my $no_collector = device('NoCollector','02:00:00:00:00:0C');
ok(!exists $attr{NoCollector}{IODev},
  'new definition with no collector leaves IODev unset');

# Explicitly named unknown collector must not write an invalid attribute.
my $invalid = {NAME=>'Invalid',TYPE=>'WIFFI_DEVICE',
  DEF=>'NoSuchCollector 02:00:00:00:00:0D'};
$defs{Invalid}=$invalid;
like(WIFFI_DEVICE_Define($invalid,
   'Invalid WIFFI_DEVICE NoSuchCollector 02:00:00:00:00:0D'),
  qr/not defined/, 'invalid explicit collector is rejected');
ok(!exists $attr{Invalid}{IODev},
  'rejected explicit definition does not persist an IODev attribute');

done_testing();
