# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use lib 't/lib';

# An isolated FHEM/TcpServerUtils contract double; the real FHEM socket and
# select-list lifecycle must still be verified in the running installation.
our (%defs, %attr, %selectlist, $init_done, $readingFnAttributes);
$init_done = 1;
$readingFnAttributes = '';
my (%blocked_port, @logs, @timers, @closed, @opened, @deleted);

sub readingsSingleUpdate {}
sub AttrVal {
  my ($name, $key, $default) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $default;
}
sub Log3 { push @logs, $_[2] }
sub InternalTimer {
  my ($at, $fn, $hash, $repeat) = @_;
  push @timers, [$at, $fn, $hash];
}
sub RemoveInternalTimer {
  my ($hash) = @_;
  @timers = grep { refaddr($_->[2]) != refaddr($hash) } @timers;
}
sub TcpServer_Open {
  my ($hash, $port, $scope) = @_;
  push @opened, "$hash->{NAME}:$port";
  # Replicate core: state initialized before attempting bind.
  $hash->{READINGS}{state}{VAL} = 'Initialized';
  if ($blocked_port{$port}) {
    $hash->{SERVERSOCKET} = undef;
    return "$hash->{NAME}: Can't open server port at $port: Address already in use";
  }
  $hash->{SERVERSOCKET} = { sock => $port };
  $hash->{PORT} = $port;
  $hash->{FD} = 42;
  $selectlist{"$hash->{NAME}.$port"} = $hash;
  return undef;
}
sub TcpServer_Close {
  my ($hash) = @_;
  if (defined $hash->{SERVERSOCKET}) {
    delete $selectlist{"$hash->{NAME}.$hash->{PORT}"};
    push @closed, "$hash->{NAME}:$hash->{PORT}";
    # FHEM's TcpServer_Close leaves SERVERSOCKET in the hash.
    return undef;
  }
  delete $selectlist{$hash->{NAME}};
  push @closed, $hash->{NAME};
  return undef;
}
sub CommandDelete {
  my ($cl, $name) = @_;
  my $hash = $defs{$name};
  return "not defined: $name" unless $hash;
  WIFFI_Collector_Undef($hash);
  delete $defs{$name};
  push @deleted, $name;
  return undef;
}

require './FHEM/00_WIFFI_Collector.pm';

sub reset_case {
  (%defs, %attr, %selectlist, %blocked_port) = ();
  (@logs, @timers, @closed, @opened, @deleted) = ();
  $init_done = 1;
  my $hash = { NAME => 'Collector', TYPE => 'WIFFI_Collector' };
  $defs{Collector} = $hash;
  return $hash;
}
sub open_collector {
  my ($port) = @_;
  my $hash = reset_case();
  is(WIFFI_Collector_Define($hash, "Collector WIFFI_Collector $port"),
    undef, "define $port returns success");
  return $hash;
}
sub fake_client {
  my ($name, $sname) = @_;
  my $h = {NAME => $name, SNAME => $sname,
           TYPE => 'WIFFI_Collector', '.WIFFI_COUNTED' => 1,
           CD => 1};
  $defs{$name} = $h;
  $selectlist{$name} = $h;
  return $h;
}

my $h = open_collector(9195);
my $initialized_module = {};
WIFFI_Collector_Initialize($initialized_module);
is($initialized_module->{SetFn}, 'WIFFI_Collector_Set',
   'standard SetFn callback registered');
is($initialized_module->{RenameFn}, 'WIFFI_Collector_Rename',
   'standard RenameFn callback registered');
is($h->{LISTENER_STATUS}, 'listening', 'listener status INTERNAL set on success');
is($h->{LISTENER_ERROR}, '', 'listener error INTERNAL cleared on success');
ok(exists $selectlist{'Collector.9195'}, 'listening socket registered');
ok(!exists $h->{READINGS}{LISTENER_STATUS} &&
   !exists $h->{READINGS}{LISTENER_ERROR},
   'status diagnostics do not create any Readings');

is(WIFFI_Collector_Set($h, 'Collector', '?'),
   'Unknown argument ?, choose one of reopen', 'set advertises reopen');
is(WIFFI_Collector_Set($h, 'Collector', 'reopen', 'extra'),
   'Usage: set <collector> reopen', 'reopen rejects extra arguments');
ok(exists $selectlist{'Collector.9195'}, 'invalid set preserves listener');

# Failed initial binding must not prevent manual recovery or hide its reason.
$h = reset_case();
$blocked_port{9195} = 1;
is(WIFFI_Collector_Define($h, 'Collector WIFFI_Collector 9195'), undef,
   'failed bind leaves a defined device for manual recovery');
is($h->{LISTENER_STATUS}, 'error', 'failed bind status is error');
like($h->{LISTENER_ERROR}, qr/Address already in use/,
   'underlying TCP error available as INTERNAL');
ok(!exists $h->{SERVERSOCKET} && !exists $h->{PORT} &&
   !exists $h->{FD}, 'failed bind removes stale listener fields');
ok(!exists $selectlist{'Collector.9195'},
   'failed bind does not leave a selectlist entry');
like($logs[-1], qr/could not bind TCP port 9195.*Address already in use.*set Collector reopen/,
   'port, cause and manual recovery command logged');
my $prior = scalar @logs;
my $err = WIFFI_Collector_Set($h, 'Collector', 'reopen');
like($err, qr/Address already in use/, 'manual reopen returns bind error');
is(scalar @logs, $prior + 1, 'repeated bind failures are each logged');
$blocked_port{9195} = 0;
is(WIFFI_Collector_Set($h, 'Collector', 'reopen'), undef,
   'manual reopen recovers without restart');
is($h->{LISTENER_STATUS}, 'listening', 'recovery sets listener status');
is($h->{LISTENER_ERROR}, '', 'recovery clears the previous bind error');
ok(exists $selectlist{'Collector.9195'}, 'manual recovery registers one socket');
like($logs[-1], qr/listener listening on TCP port 9195/,
   'successful listener opening is logged');
is(scalar(grep { $_ eq 'Collector.9195' } keys %selectlist), 1,
   'no duplicate listener after recovery');

# Reopen closes accepted clients; the old listener is closed before the new
# listener is opened on the same port.
my $before = scalar @closed;
$h->{CLIENTS_ACTIVE} = 2;
my $child1 = fake_client('client_1', 'Collector');
my $child2 = fake_client('client_2', 'Collector');
is(WIFFI_Collector_Set($h, 'Collector', 'reopen'), undef,
   'reopen cleans and recreates a running listener');
ok(!exists $defs{client_1} && !exists $defs{client_2},
   'reopen deletes active temporary children');
ok(!exists $selectlist{client_1} && !exists $selectlist{client_2},
   'reopen frees child selectlist entries');
is($h->{CLIENTS_ACTIVE}, 0, 'active client INTERNAL drops to zero');
is(scalar @closed, $before + 3, 'two clients and old listener closed');
ok(exists $selectlist{'Collector.9195'}, 'new listener is registered');
ok(!exists $h->{READINGS}{LISTENER_STATUS},
   'reopen does not publish listener-status events');

# Modify must check syntax before interrupting a healthy listener.
is(WIFFI_Collector_Define($h, 'Collector WIFFI_Collector invalid'),
   'Usage: define <name> WIFFI_Collector <tcp-port>',
   'invalid modify arguments are rejected');
ok(exists $selectlist{'Collector.9195'},
   'invalid modify does not close a valid listener');

# Successful modify closes the previous listener and clients, then rebinds.
$h->{OLDDEF} = '9195';
$h->{CLIENTS_ACTIVE} = 1;
fake_client('client_during_modify', 'Collector');
is(WIFFI_Collector_Define($h, 'Collector WIFFI_Collector 9295'),
   undef, 'modify port returns success');
delete $h->{OLDDEF};
ok(!exists $selectlist{'Collector.9195'},
   'old port deregistered during modify');
ok(exists $selectlist{'Collector.9295'},
   'new port registered during modify');
ok(!exists $defs{client_during_modify},
   'modify releases child clients');
is($h->{PORT}, 9295, 'actual TCP port changed');
is($h->{LISTENER_STATUS}, 'listening', 'modified listener reports listening');
is($h->{CLIENTS_ACTIVE}, 0, 'client count reset on modify');
is($h->{TCP_PORT}, 9295, 'configured port INTERNAL updated');
ok((grep { /listener closed \(modify\)/ } @logs),
   'listener close during modify is logged');

# A failed modify leaves a defined, stopped collector and allows manual retry.
$h->{OLDDEF} = '9295';
$blocked_port{9395} = 1;
is(WIFFI_Collector_Define($h, 'Collector WIFFI_Collector 9395'),
   undef, 'port conflict during modify does not delete collector');
delete $h->{OLDDEF};
is($h->{LISTENER_STATUS}, 'error', 'failed modified listener reports error');
ok(!exists $selectlist{'Collector.9295'} &&
   !exists $selectlist{'Collector.9395'},
   'neither old nor failed port remains bound');
is($h->{TCP_PORT}, 9395, 'desired new port retained for manual retry');
$blocked_port{9395} = 0;
is(WIFFI_Collector_Set($h, 'Collector', 'reopen'), undef,
   'reopen recovers after modify bind failure');
ok(exists $selectlist{'Collector.9395'}, 'recovered new port is bound');

# Real FHEM performs rename in %defs first, then invokes RenameFn(new,old).
# Correct the listener selectlist key, temporary SNAME and the device DEF.
my $logical = {
  NAME => 'WIFFI_PUMP2', TYPE => 'WIFFI_DEVICE',
  COLLECTOR => 'Collector',
  MAC => '02:00:00:00:00:01',
  DEF => 'Collector 02:00:00:00:00:01',
  READINGS => {wiffi_pump=>{VAL=>'true'}}
};
$defs{WIFFI_PUMP2} = $logical;
$h->{CLIENTS_ACTIVE} = 1;
my $open_client = fake_client('client_rename', 'Collector');
$defs{CollectorRenamed} = delete $defs{Collector};
$h->{NAME} = 'CollectorRenamed';
WIFFI_Collector_Rename('CollectorRenamed','Collector');
ok(!exists $selectlist{'Collector.9395'},
   'rename removes obsolete selectlist key');
ok(exists $selectlist{'CollectorRenamed.9395'},
   'rename migrates listener selectlist entry');
is($open_client->{SNAME}, 'CollectorRenamed',
   'rename updates parent reference for temporary client');
is($logical->{COLLECTOR}, 'CollectorRenamed',
   'logical device references new collector');
is($logical->{DEF}, 'CollectorRenamed 02:00:00:00:00:01',
   'logical definition persists renamed collector dependency');
is($logical->{READINGS}{wiffi_pump}{VAL}, 'true',
   'rename does not alter existing sensor reading');
CommandDelete(undef, 'client_rename');
is($h->{CLIENTS_ACTIVE}, 0, 'renamed temporary client closes cleanly');
is(WIFFI_Collector_Set($h, 'CollectorRenamed','reopen'), undef,
   'reopen still works after renaming collector');
ok(exists $selectlist{'CollectorRenamed.9395'},
   'renamed listener still opens on existing port');
ok(!exists $selectlist{'Collector.9395'}, 'old selectlist not resurrected');

# If the rename happens before an initial timer fires, use the current name.
$h = reset_case();
$init_done = 0;
is(WIFFI_Collector_Define($h, 'Collector WIFFI_Collector 9195'),
   undef, 'define during early startup schedules opening');
is($h->{LISTENER_STATUS}, 'stopped',
   'startup status is stopped until open');
is(scalar @timers, 1, 'startup bind uses one deferred timer');
my $deferred = $timers[0][1];
$defs{CollectorRenamed} = delete $defs{Collector};
$h->{NAME} = 'CollectorRenamed';
WIFFI_Collector_Rename('CollectorRenamed','Collector');
$deferred->($h);
is($h->{LISTENER_STATUS}, 'listening',
   'deferred bind follows the collector rename');
ok(exists $selectlist{'CollectorRenamed.9195'},
   'startup after rename uses the new name');

# Undef/redefinition (rereadcfg-style) cleans old listener and children,
# leaving no stale selectlist entries/timers or automatic reopen loops.
$h->{CLIENTS_ACTIVE} = 1;
fake_client('client_shutdown', 'CollectorRenamed');
WIFFI_Collector_Undef($h);
ok(!exists $selectlist{'CollectorRenamed.9195'} &&
   !exists $selectlist{client_shutdown},
   'undef closes listener and accepted clients');
is($h->{LISTENER_STATUS}, 'stopped', 'undef reports stopped');
is($h->{CLIENTS_ACTIVE}, 0, 'undef frees client count');
is(scalar @timers, 0, 'undef removes pending timers');
delete $defs{CollectorRenamed};
$h = open_collector(9195);
ok(exists $selectlist{'Collector.9195'},
   'fresh definition recreates a clean listener after shutdown');

done_testing();
