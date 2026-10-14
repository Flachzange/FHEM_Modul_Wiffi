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
my (%blocked_port, %refused_delete, %refused_after_undef, %silent_delete,
    @logs, @log_levels, @timers, @closed, @opened, @deleted);

sub readingsSingleUpdate {}
sub AttrVal {
  my ($name, $key, $default) = @_;
  return exists $attr{$name}{$key} ? $attr{$name}{$key} : $default;
}
sub Log3 { push @logs, $_[2]; push @log_levels, $_[1] }
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
  delete $hash->{CD} if defined $hash->{CD}; # Real TcpServer_Close closes and clears the socket.
  delete $hash->{FD};
  delete $selectlist{$hash->{NAME}};
  push @closed, $hash->{NAME};
  return undef;
}
# FHEM CommandDelete aborts if UndefFn or DeleteFn returns an error.
sub CommandDelete {
  my ($cl, $name) = @_;
  my $hash = $defs{$name};
  return "not defined: $name" unless $hash;
  return $refused_delete{$name} if $refused_delete{$name};
  return undef if $silent_delete{$name}; # Simulate a buggy/no-op deletion.
  my $error = WIFFI_Collector_Undef($hash);
  return $error if $error;
  # Mimic a DeleteFn error after UndefFn already closed the socket.
  return $refused_after_undef{$name} if $refused_after_undef{$name};
  delete $selectlist{$name};
  delete $defs{$name};
  push @deleted, $name;
  return undef;
}

require './FHEM/00_WIFFI_Collector.pm';

sub reset_case {
  (%defs, %attr, %selectlist, %blocked_port, %refused_delete,
   %refused_after_undef, %silent_delete) = ();
  (@logs, @log_levels, @timers, @closed, @opened, @deleted) = ();
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
is($h->{CLIENTS_TIMEOUT}, 0, 'CLIENTS_TIMEOUT initialized on first define');
ok(!exists $h->{READINGS}{CLIENTS_TIMEOUT},
   'timeout counter is INTERNAL-only');
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
$h->{CLIENTS_TIMEOUT} = 3; # prior closed clients, retained through reopen
is(WIFFI_Collector_Set($h, 'Collector', 'reopen'), undef,
   'manual reopen recovers without restart');
is($h->{CLIENTS_TIMEOUT}, 3, 'manual reopen retains timeout statistics');
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
is($h->{CLIENTS_TIMEOUT}, 3,
   'reopen of listening collector retains historical timeouts');
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
is($h->{CLIENTS_TIMEOUT}, 0,
   'modify/redefinition resets timeout counter with other diagnostics');
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
is($h->{CLIENTS_TIMEOUT}, 0, 'new definition starts with zero timeouts');

# Rejected client deletion must never advertise a successful listener
# recovery or hide still-connected TCP children.
$h = open_collector(9195);
$h->{CLIENTS_TIMEOUT} = 2;
my $stuck = fake_client('client_stuck', 'Collector');
$h->{CLIENTS_ACTIVE} = 1;
$refused_delete{client_stuck} = 'synthetic UndefFn refused deletion';
my $previous_opens = scalar @opened;
my $old_logs = scalar @logs;
my $failure = WIFFI_Collector_Set($h, 'Collector', 'reopen');
like($failure, qr/client_stuck/, 'set reopen returns refused cleanup as an error');
is($h->{LISTENER_STATUS}, 'error', 'failed cleanup leaves listener in error');
like($h->{LISTENER_ERROR}, qr/client_stuck.*synthetic UndefFn refused deletion/,
  'LISTENER_ERROR includes specific refused child and underlying cause');
is($h->{CLIENTS_ACTIVE}, 1, 'live child remains counted after failed deletion');
is($h->{CLIENTS_TIMEOUT}, 2, 'cleanup error preserves timeout history');
ok(exists $defs{client_stuck} && $defs{client_stuck} == $stuck,
  'refused temporary client is retained by FHEM');
ok(exists $selectlist{client_stuck}, 'refused client remains select registered');
ok(!exists $selectlist{'Collector.9195'}, 'old listener socket closed on failure');
ok(!exists $h->{SERVERSOCKET}, 'failed cleanup leaves no listener socket');
is(scalar @opened, $previous_opens, 'failure does not open a replacement listener');
is($log_levels[-2], 1, 'refusal logged at level 1');
like(join(' ', @logs[$old_logs .. $#logs]), qr/client_stuck.*manual reopen.*synthetic UndefFn refused deletion/,
  'log contains client, attempted action and underlying failure');
$old_logs = scalar @logs;
like(WIFFI_Collector_Set($h, 'Collector', 'reopen'), qr/client_stuck/,
  'repeated failure again prevents reopen');
like(join(' ', @logs[$old_logs .. $#logs]), qr/client_stuck.*synthetic UndefFn/,
  'repeated failure logged individually, without rate limiting');
delete $refused_delete{client_stuck};
is(WIFFI_Collector_Set($h, 'Collector', 'reopen'), undef,
  'manual reopen recovers once child becomes deletable');
is($h->{LISTENER_STATUS}, 'listening', 'successful recovery restores listener');
is($h->{LISTENER_ERROR}, '', 'successful recovery clears cleanup error');
is($h->{CLIENTS_ACTIVE}, 0, 'successful retry frees the temporary client');
ok(!exists $defs{client_stuck} && !exists $selectlist{client_stuck},
  'successful recovery eliminates stale client and selection');
ok(exists $selectlist{'Collector.9195'}, 'one listener registered after recovery');

# CommandModify restores DEF on error. Its module callback must not install
# a newly configured port, reset statistics or return false success.
$h = open_collector(9195);
my $during_modify = fake_client('client_modify_failed','Collector');
$h->{CLIENTS_ACTIVE} = 1;
$h->{CLIENTS_TIMEOUT} = 4;
$h->{FRAMES_OK} = 7;
$refused_delete{client_modify_failed} = 'synthetic temporary client refusal';
$h->{OLDDEF} = '9195';
$failure = WIFFI_Collector_Define($h, 'Collector WIFFI_Collector 9295');
delete $h->{OLDDEF};
like($failure, qr/client_modify_failed/, 'modify aborts on client cleanup failure');
is($h->{TCP_PORT}, 9195, 'failed modify keeps original configured TCP port');
is($h->{FRAMES_OK}, 7, 'failed modify does not reset frame counters');
is($h->{CLIENTS_TIMEOUT}, 4, 'failed modify preserves timeout diagnostics');
is($h->{CLIENTS_ACTIVE}, 1, 'failed modify shows remaining connected child');
is($h->{LISTENER_STATUS}, 'error', 'failed modify exposes listener error');
ok(!exists $selectlist{'Collector.9195'} &&
   !exists $selectlist{'Collector.9295'}, 'failed modify leaves listener stopped');
delete $refused_delete{client_modify_failed};
is(WIFFI_Collector_Set($h, 'Collector', 'reopen'),undef,
  'recover failed modify manually at old configured port');
ok(exists $selectlist{'Collector.9195'} && !exists $selectlist{'Collector.9295'},
  'failed modify never silently activates the new port');
is($h->{CLIENTS_ACTIVE}, 0, 'manual recovery releases failed-modify client');

# CommandDelete normally keeps the Collector defined if UndefFn reports an
# error; a retry after the refusal is removed must finish removing it.
$h = open_collector(9195);
my $during_undef = fake_client('client_undef_failed','Collector');
$h->{CLIENTS_ACTIVE} = 1;
$refused_delete{client_undef_failed} = 'synthetic refusal during undef';
$failure = CommandDelete(undef, 'Collector');
like($failure, qr/client_undef_failed/, 'server undef propagates cleanup error');
ok($defs{Collector} && $defs{Collector} == $h,
  'FHEM retains collector definition after failed undef');
ok(exists $defs{client_undef_failed}, 'failed child persists until retried');
is($h->{CLIENTS_ACTIVE}, 1, 'server failed undef retains accurate child count');
is($h->{LISTENER_STATUS}, 'error', 'failed undef reports listener error');
ok(!exists $selectlist{'Collector.9195'}, 'failed undef shuts down old listener');
delete $refused_delete{client_undef_failed};
is(CommandDelete(undef,'Collector'), undef,
  'retrying delete removes collector and previously stuck client');
ok(!exists $defs{Collector} && !exists $defs{client_undef_failed},
  'collector and child are absent following successful retry');
ok(!exists $selectlist{client_undef_failed},
  'retry deletes last stale child selection');
is($h->{CLIENTS_ACTIVE}, 0, 'successful undef retry clears active count');

# A child UndefFn can already close its socket before its DeleteFn refuses
# deletion. Retain error state without falsely counting a live socket.
$h = open_collector(9195);
my $ghost = fake_client('client_partial_cleanup','Collector');
$h->{CLIENTS_ACTIVE} = 1;
$refused_after_undef{client_partial_cleanup} = 'synthetic DeleteFn refused deletion';
$failure = WIFFI_Collector_Set($h,'Collector','reopen');
like($failure, qr/client_partial_cleanup/, 'post-Undef DeleteFn error blocks reopen');
ok(exists $defs{client_partial_cleanup}, 'partially deleted child remains in defs');
ok(!defined $ghost->{CD}, 'FHEM UndefFn has already closed child socket');
is($h->{CLIENTS_ACTIVE}, 0, 'closed orphan is not counted as a live connection');
is($h->{LISTENER_STATUS}, 'error', 'orphaned child still blocks listener reopen');
ok(!exists $selectlist{'Collector.9195'}, 'no new listener with orphaned child');
delete $refused_after_undef{client_partial_cleanup};
is(WIFFI_Collector_Set($h,'Collector','reopen'), undef,
  'manual retry cleans ghost device and reopens listener');
ok(!exists $defs{client_partial_cleanup}, 'ghost child removed on retry');
ok(exists $selectlist{'Collector.9195'}, 'single listener available after retry');

# Deleting other children must continue when one child refuses cleanup.
$h = open_collector(9195);
my $good_child = fake_client('client_good','Collector');
my $bad_child = fake_client('client_bad','Collector');
$h->{CLIENTS_ACTIVE} = 2;
$refused_delete{client_bad} = 'synthetic bad child refusal';
$failure = WIFFI_Collector_Set($h,'Collector','reopen');
like($failure,qr/client_bad.*synthetic bad child refusal/,
  'mixed cleanup returns the failed child and its cause');
ok(!exists $defs{client_good}, 'healthy child removed despite another refusal');
ok(exists $defs{client_bad}, 'refused child remains defined');
is($h->{CLIENTS_ACTIVE},1, 'exactly one surviving client socket counted');
is($h->{LISTENER_STATUS},'error', 'mixed cleanup does not rebind the listener');
ok(!exists $selectlist{'Collector.9195'}, 'listener stopped after mixed cleanup');
delete $refused_delete{client_bad};
is(WIFFI_Collector_Set($h,'Collector','reopen'),undef,
  'manual retry removes remaining client without altering working devices');
is($h->{CLIENTS_ACTIVE},0, 'mixed cleanup retry releases final client');
ok(!exists $defs{client_bad} && exists $selectlist{'Collector.9195'},
  'no old children or orphaned listener remain after retry');

# Even if CommandDelete returns success, the original FHEM child must
# actually disappear. Check hash identity rather than trusting the return.
$h = open_collector(9195);
my $unremoved = fake_client('client_silent_noop','Collector');
$h->{CLIENTS_ACTIVE} = 1;
$silent_delete{client_silent_noop} = 1;
$failure = WIFFI_Collector_Set($h,'Collector','reopen');
like($failure,qr/client_silent_noop.*temporary client still defined/,
  'silent no-op delete is detected despite empty CommandDelete result');
is($h->{CLIENTS_ACTIVE},1,'undeleted socket remains counted');
is($h->{LISTENER_STATUS},'error','silent no-op does not reopen listener');
ok(!exists $selectlist{'Collector.9195'},
  'listener is closed on silent child deletion failure');
delete $silent_delete{client_silent_noop};
is(WIFFI_Collector_Set($h,'Collector','reopen'),undef,
  'retry removes the original child after silent no-op is fixed');
ok(!exists $defs{client_silent_noop} && !exists $selectlist{client_silent_noop},
  'recovery cleans original child and selection');

done_testing();
