# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use IO::Handle;
use Time::HiRes ();
use lib 't/lib';

# FHEM contract double. Unlike the transport-only suite this loads BOTH real
# WIFFI modules and triggers callback actions synchronously from
# readingsEndUpdate, matching the FHEM DoTrigger/NotifyFn call timing.
# Actual FHEM socket/selectlist and configDB integration still need live tests.
our (%defs, %attr, %selectlist, $init_done, $readingFnAttributes);
$init_done = 1;
$readingFnAttributes = '';
my (@accepted, @logs, @timers, @writers, @events,
    $on_update, $on_define, $on_attr);
sub AttrVal {
  my ($name, $key, $default) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $default;
}
sub Log3 { push @logs, $_[2] }
sub readingsSingleUpdate { $_[0]{READINGS}{$_[1]}{VAL} = $_[2] }
sub readingsBeginUpdate { $_[0]{'.in_update'} = 1 }
sub readingsBulkUpdate {
  die "bulk update outside begin" unless $_[0]{'.in_update'};
  $_[0]{READINGS}{$_[1]}{VAL} = $_[2];
}
sub readingsEndUpdate {
  my ($device) = @_;
  delete $device->{'.in_update'};
  push @events, [$device, $device->{READINGS}{w_counter1}{VAL}];
  if ($on_update) {
    my $callback = $on_update;
    undef $on_update; # one-shot: reentrant events must not recurse infinitely
    $callback->($device);
  }
}
sub TcpServer_Open {
  my ($server,$port) = @_;
  $server->{SERVERSOCKET} = { port => $port };
  $server->{FD} = 42; # deliberately reused across reopen
  $server->{PORT} = $port;
  $selectlist{"$server->{NAME}.$port"} = $server;
  return undef;
}
sub TcpServer_Close {
  my ($hash) = @_;
  if ($hash->{CD}) {
    close($hash->{CD});
    delete $hash->{CD};
    delete $selectlist{$hash->{NAME}};
    delete $hash->{FD};
  } elsif ($hash->{SERVERSOCKET}) {
    delete $selectlist{"$hash->{NAME}.$hash->{PORT}"};
    delete $hash->{FD};
  }
  return undef;
}
sub TcpServer_Accept {
  my ($server) = @_;
  my $child = shift @accepted;
  ++$server->{CONNECTS} if $child;
  return $child;
}
sub InternalTimer { push @timers, [@_] }
sub RemoveInternalTimer {
  my ($hash) = @_;
  @timers = grep { $_->[2] != $hash } @timers;
}
sub CommandDelete {
  my ($cl,$name) = @_;
  return "missing $name" unless $defs{$name};
  my $hash = $defs{$name};
  my $err = $hash->{TYPE} eq 'WIFFI_Collector'
    ? WIFFI_Collector_Undef($hash)
    : WIFFI_DEVICE_Undef($hash);
  return $err if $err;
  delete $selectlist{$name};
  delete $defs{$name};
  return undef;
}
sub CommandDefine {
  my ($cl,$def) = @_;
  my ($name,$type)=split /\s+/, $def;
  return "name collision" if $defs{$name};
  my $hash={NAME=>$name,TYPE=>$type,DEF=>(split /\s+/, $def,3)[2]};
  $defs{$name}=$hash;
  my $error = WIFFI_DEVICE_Define($hash,$def);
  if (!$error && $on_define) {
    my $callback=$on_define;
    undef $on_define;
    $callback->($hash);  # core's synchronous DEFINED notification
  }
  return $error;
}
sub CommandAttr {
  my ($cl,$def) = @_;
  my ($name,$key,$value)=split /\s+/, $def,3;
  $attr{$name}{$key}=$value;
  if ($on_attr) {
    my $callback=$on_attr;
    undef $on_attr;
    $callback->($name,$key);  # core's synchronous ATTR notification
  }
  return undef;
}

require './FHEM/00_WIFFI_Collector.pm';
require './FHEM/10_WIFFI_DEVICE.pm';

sub reset_case {
  for my $writer (@writers) { close $writer if defined fileno($writer) }
  %defs=(); %attr=(); %selectlist=();
  @accepted=(); @logs=(); @timers=(); @writers=(); @events=();
  undef $on_update;
  undef $on_define;
  undef $on_attr;
  my $server={NAME=>'Collector',TYPE=>'WIFFI_Collector'};
  $defs{Collector}=$server;
  is(WIFFI_Collector_Define($server,'Collector WIFFI_Collector 9195'),
    undef,'collector defined');
  my $device={NAME=>'Pump',TYPE=>'WIFFI_DEVICE',
    DEF=>'Collector 02:00:00:00:00:01'};
  $defs{Pump}=$device;
  is(WIFFI_DEVICE_Define($device,
    'Pump WIFFI_DEVICE Collector 02:00:00:00:00:01'),
    undef,'logical WIFFI device defined');
  return ($server,$device);
}
sub frame {
  my ($value)=@_;
  return '{"modultyp":"PULSECOUNTER","vars":['
    .'{"homematic_name":"w_counter1","value":'.$value.'}],'
    .'"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:01"}}';
}
sub send_frames {
  my ($server,$suffix,@values)=@_;
  pipe(my $read,my $write) or die "pipe: $!";
  $read->blocking(0);
  my $name=$server->{NAME}."_reentrant_".$suffix;
  my $client={NAME=>$name,TYPE=>'WIFFI_Collector',SNAME=>$server->{NAME},
    CD=>$read,PEER=>'192.0.2.21',BUF=>''};
  $defs{$name}=$client;
  $selectlist{$name}=$client;
  push @accepted,$client;
  push @writers,$write;
  WIFFI_Collector_Read($server); # accept/track client
  my $data=join("\x03",map { frame($_) } @values)."\x04";
  is(syswrite($write,$data),length($data),'write coalesced input');
  WIFFI_Collector_Read($client);
  return $client;
}
sub rename_collector {
  my ($server)=@_;
  $defs{RenamedCollector}=delete $defs{Collector};
  $server->{NAME}='RenamedCollector';
  WIFFI_Collector_Rename('RenamedCollector','Collector');
}
sub rename_device {
  my ($device)=@_;
  $defs{RenamedPump}=delete $defs{Pump};
  $device->{NAME}='RenamedPump';
}

my ($server,$device)=reset_case();
my $client=send_frames($server,'normal',1,2);
is($server->{FRAMES_OK},2,'normal coalesced frames both processed');
is($device->{READINGS}{w_counter1}{VAL},2,'latest frame updates reading');
is($server->{CLIENTS_ACTIVE},1,'normal connection remains open');
is(scalar @events,2,'normal event for each frame');
CommandDelete(undef,$client->{NAME});

($server,$device)=reset_case();
$on_update=sub { is(WIFFI_Collector_Set($server,'Collector','reopen'),
    undef,'reentrant set reopen succeeds') };
$client=send_frames($server,'reopen',11,12);
is($server->{FRAMES_OK},1,'reopen does not process queued second frame');
is($device->{READINGS}{w_counter1}{VAL},11,'first frame stays published');
is(scalar @events,1,'no event for queued second frame after reopen');
ok(!exists $defs{$client->{NAME}},'old accepted client removed on reopen');
is($server->{CLIENTS_ACTIVE},0,'no old client counted after reopen');
is($server->{LISTENER_STATUS},'listening','new listener running after reopen');
is($server->{FRAMES_ERROR},0,'intentional reopen is not JSON error');
like(join(' ',@logs),qr/TCP frame batch stopped.*discarding 1 remaining complete frame/,
  'reentrant stop diagnoses how many queued frames were discarded');
my $other=send_frames($server,'after-reopen',13);
is($server->{FRAMES_OK},2,'fresh client can publish after reopen');
is($device->{READINGS}{w_counter1}{VAL},13,'new connection publishes');
is(scalar @events,2,'new connection triggers its own event');
is($server->{FRAMES_ERROR},0,'fresh client does not create parse failures');
CommandDelete(undef,$other->{NAME});

($server,$device)=reset_case();
$on_update=sub {
  $server->{OLDDEF}='9195';
  is(WIFFI_Collector_Define($server,'Collector WIFFI_Collector 9295'),
    undef,'reentrant modify changes collector port');
  delete $server->{OLDDEF};
};
$client=send_frames($server,'modify',21,22);
ok(!exists $defs{$client->{NAME}},'modify closes old client');
is($device->{READINGS}{w_counter1}{VAL},21,'modify drops second queued frame');
is(scalar @events,1,'modify emits no second reading update');
ok(exists $selectlist{'Collector.9295'},'modified listener remains healthy');

($server,$device)=reset_case();
$on_update=sub { is(CommandDelete(undef,'Collector_reentrant_client-delete'),undef,
    'reentrant client deletion succeeds') };
# Match the deterministic FHEM temporary-client name used by send_frames().
$client=send_frames($server,'client-delete',31,32);
ok(!exists $defs{$client->{NAME}},'deleted TCP client does not reappear');
is($device->{READINGS}{w_counter1}{VAL},31,'client delete drops second frame');
is(scalar @events,1,'client deletion stops queued updates');
is($server->{FRAMES_OK},1,'only delivered frame counted');
is($server->{FRAMES_ERROR},0,'intentional deletion not parser error');

($server,$device)=reset_case();
$on_update=sub { is(CommandDelete(undef,'Collector'),undef,
    'synchronous collector deletion succeeds') };
$client=send_frames($server,'collector-delete',35,36);
ok(!exists $defs{Collector},'collector deleted while processing first frame');
ok(!exists $defs{$client->{NAME}},'collector deletion removes temporary client');
is(scalar @events,1,'only the first frame event fired before collector delete');
is($device->{READINGS}{w_counter1}{VAL},35,'second frame not delivered after delete');
is($server->{FRAMES_OK},0,'deleted collector does not count a stale frame');
is($server->{FRAMES_ERROR},0,'deleted collector is not a parsing failure');

($server,$device)=reset_case();
$on_update=sub { is(CommandDelete(undef,'Pump'),undef,
    'synchronous device delete succeeds') };
$client=send_frames($server,'device-delete',41,42);
ok(!exists $defs{Pump},'target logical device deleted');
ok(!exists $defs{$client->{NAME}},'client closed after target is deleted');
is($device->{READINGS}{w_counter1}{VAL},41,'no second update on old device hash');
is(scalar @events,1,'only first event before device deletion');
is($server->{FRAMES_OK},0,'deleted device is not counted as live publication');
is($server->{FRAMES_ERROR},0,'intentional logical deletion not malformed JSON');

($server,$device)=reset_case();
$on_update=sub {
  $device->{OLDDEF}=$device->{DEF};
  is(WIFFI_DEVICE_Define($device,
    'Pump WIFFI_DEVICE Collector 02:00:00:00:00:01'),undef,
    'reentrant logical modify succeeds');
  delete $device->{OLDDEF};
};
$client=send_frames($server,'device-modify',51,52);
is(scalar @events,1,'device modify interrupts queued updates');
is($device->{READINGS}{w_counter1}{VAL},51,'second frame suppressed on modify');
is($device->{READINGS}{state}{VAL},'waiting','device modify retains waiting state');
ok(!exists $defs{$client->{NAME}},'client closed after target modify');
is($server->{FRAMES_OK},0,'modified logical device not counted as live publication');
is($server->{FRAMES_ERROR},0,'device modify not a malformed frame');

($server,$device)=reset_case();
$on_update=sub { rename_collector($server) };
$client=send_frames($server,'collector-rename',61,62);
is($server->{FRAMES_OK},2,'collector rename retains valid connection');
is($device->{READINGS}{w_counter1}{VAL},62,'second frame processed after collector rename');
is($client->{SNAME},'RenamedCollector','temporary client parent updated on rename');
is($device->{COLLECTOR},'RenamedCollector','logical collector association updated');
is($server->{CLIENTS_ACTIVE},1,'client remains counted after collector rename');
ok(exists $defs{$client->{NAME}},'rename does not close active client');
CommandDelete(undef,$client->{NAME});

($server,$device)=reset_case();
$on_update=sub { rename_device($device) };
$client=send_frames($server,'device-rename',71,72);
is($server->{FRAMES_OK},2,'logical device rename retains connection');
is($device->{READINGS}{w_counter1}{VAL},72,'second frame delivered to renamed device');
ok(exists $defs{RenamedPump} && $defs{RenamedPump} == $device,
  'identity preserved by logical device rename');
is($server->{CLIENTS_ACTIVE},1,'client not disconnected for logical rename');
CommandDelete(undef,$client->{NAME});

($server,$device)=reset_case();
$on_update=sub {
  is(CommandDelete(undef,'Pump'),undef,'delete old device before name reuse');
  my $replacement={NAME=>'Pump',TYPE=>'WIFFI_DEVICE',
    COLLECTOR=>'Collector',MAC=>'02:00:00:00:00:01',
    READINGS=>{}};
  $defs{Pump}=$replacement;
};
$client=send_frames($server,'device-replaced',81,82);
is(scalar @events,1,'new hash at reused name gets no queued frame');
is($device->{READINGS}{w_counter1}{VAL},81,'old device published only initial frame');
ok(!exists $defs{Pump}{READINGS}{w_counter1},
  'replacement device not adopted by stale frame');
ok(!exists $defs{$client->{NAME}},'connection closed after target name reuse');

($server,$device)=reset_case();
$attr{Collector}{autocreate}=1;
delete $defs{Pump};
$on_update=undef;
$client=send_frames($server,'unknown',91,92);
is($server->{FRAMES_OK},2,'autocreated known identity handles two valid frames');
ok($defs{WIFFI_020000000001},'autocreate remains functional');
is($defs{WIFFI_020000000001}{READINGS}{w_counter1}{VAL},92,
  'autocreated device receives second frame');
CommandDelete(undef,$client->{NAME});

# Synchronous DEFINED/ATTR callbacks can also reopen the listener before
# the newly auto-created device has received its first readings.
($server,$device)=reset_case();
$attr{Collector}{autocreate}=1;
delete $defs{Pump};
$on_define=sub {
  is(WIFFI_Collector_Set($server,'Collector','reopen'),undef,
     'DEFINED event may synchronously reopen collector');
};
$client=send_frames($server,'defined-reopen',101,102);
is($server->{FRAMES_OK},0,'DEFINED reopen publishes neither queued frame');
is(scalar @events,0,'no reading updates after DEFINED invalidation');
ok(!$defs{$client->{NAME}},'old connection closed by DEFINED callback');
ok($defs{WIFFI_020000000001},'logical device remains explicitly created');
ok(!exists $defs{WIFFI_020000000001}{READINGS}{w_counter1},
   'no stale reading written after DEFINED reopen');

($server,$device)=reset_case();
$attr{Collector}{autocreate}=1;
delete $defs{Pump};
$on_attr=sub {
  is(WIFFI_Collector_Set($server,'Collector','reopen'),undef,
    'ATTR event may synchronously reopen collector');
};
$client=send_frames($server,'attr-reopen',111,112);
is($server->{FRAMES_OK},0,'ATTR reopen publishes neither queued frame');
is(scalar @events,0,'ATTR event interruption stops data dispatch');
ok(!$defs{$client->{NAME}},'old connection closed by ATTR callback');
ok(!exists $defs{WIFFI_020000000001}{READINGS}{w_counter1},
   'no stale device reading written after ATTR reopen');

done_testing();
