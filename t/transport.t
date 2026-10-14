# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use IO::Handle;
use Time::HiRes ();
use lib 't/lib';

# Isolated TcpServerUtils/FHEM contract double. This does NOT verify FHEM's
# real selectlist, socket lifecycle or configDB startup behavior.
our (%defs, %attr, $init_done);
$init_done = 1;
my (@accepted, @logs, @log_levels, @timers, @writers, @deleted);
sub AttrVal {
  my ($name, $key, $default) = @_;
  return exists($attr{$name}{$key}) ? $attr{$name}{$key} : $default;
}
sub Log3 { push @logs, $_[2]; push @log_levels, $_[1] }
sub TimeNow { return '2026-10-14 15:00:00' }
sub readingsSingleUpdate {}
sub TcpServer_Open { $_[0]{SERVERSOCKET} = 1; return undef }
sub TcpServer_Close {
  my ($hash) = @_;
  close($hash->{CD}) if $hash->{CD};
  delete $hash->{CD};
  delete $hash->{SERVERSOCKET};
  return undef;
}
sub TcpServer_Accept {
  my ($server, $type) = @_;
  my $client = shift @accepted;
  ++$server->{CONNECTS} if $client;
  return $client;
}
sub InternalTimer {
  my ($at, $fn, $hash, $repeat) = @_;
  push @timers, [$at, $fn, $hash];
}
sub RemoveInternalTimer {
  my ($hash) = @_;
  @timers = grep { $_->[2] != $hash } @timers;
}
sub CommandDelete {
  my ($cl, $name) = @_;
  my $hash = $defs{$name};
  return 'unknown client' unless $hash;
  push @deleted, $name;
  WIFFI_Collector_Undef($hash);
  delete $defs{$name};
  return undef;
}
sub WIFFI_DEVICE_Process {
  my ($device, $packet, $peer) = @_;
  $device->{PEER} = $peer;
  for my $name (keys %{$packet->{readings}}) {
    $device->{READINGS}{$name}{VAL} = $packet->{readings}{$name};
  }
  $device->{READINGS}{state}{VAL} = 'online';
  return 1;
}

require './FHEM/00_WIFFI_Collector.pm';

sub new_server {
  %defs = ();
  %attr = ();
  @logs = ();
  @log_levels = ();
  @accepted = ();
  @timers = ();
  @deleted = ();
  my $server = { NAME => 'Collector', TYPE => 'WIFFI_Collector' };
  $defs{Collector} = $server;
  my $err = WIFFI_Collector_Define($server, 'Collector WIFFI_Collector 9195');
  is($err, undef, 'collector define succeeds');
  $server->{CONNECTS} = 0; # Normally maintained by TcpServerUtils.
  return $server;
}
sub make_client {
  my ($suffix, $peer) = @_;
  pipe(my $reader, my $writer) or die "pipe: $!";
  $reader->blocking(0);
  my $name = "Collector_$suffix";
  my $client = {
    NAME => $name, TYPE => 'WIFFI_Collector', SNAME => 'Collector',
    PEER => $peer, CD => $reader, BUF => '',
  };
  $defs{$name} = $client; # TcpServer_Accept normally does this.
  push @accepted, $client;
  push @writers, $writer;
  return ($client, $writer);
}
sub accept_client {
  my ($server, $client) = @_;
  WIFFI_Collector_Read($server);
  return exists $defs{$client->{NAME}};
}
sub telegram {
  my $value = shift;
  return '{"modultyp":"PULSECOUNTER","vars":['
    .'{"homematic_name":"w_counter1","value":'.$value.'}],'
    .'"Systeminfo":{"MAC-Adresse":"02:00:00:00:00:01"}}';
}

my $server = new_server();
is($server->{CLIENTS_ACTIVE}, 0, 'active client INTERNAL initialized');
is($server->{CLIENTS_PEAK}, 0, 'peak client INTERNAL initialized');
is($server->{CLIENTS_REJECTED}, 0, 'rejected client INTERNAL initialized');
is($server->{CLIENTS_TIMEOUT}, 0, 'timeout client INTERNAL initialized');
is($server->{MAX_CLIENTS}, 16, 'default client limit is 16');
is($server->{CLIENT_IDLE_TIMEOUT}, 60, 'idle timeout is 60 seconds');
is($server->{CLIENT_MAX_LIFETIME}, 180, 'absolute client lifetime is bounded');
my $device = { NAME => 'Pulse', TYPE => 'WIFFI_DEVICE',
               IODev => $server, MAC => '02:00:00:00:00:01',
               READINGS => {} };
$defs{Pulse} = $device;

# Connection internals are counters, not readings.
$server->{MAX_CLIENTS} = 2;
my ($first, $write1) = make_client('A', '192.0.2.21');
ok(accept_client($server, $first), 'first client accepted');
is($server->{CLIENTS_ACTIVE}, 1, 'first accept increments active count');
is($server->{CLIENTS_PEAK}, 1, 'peak count initialized on first accept');
ok(@timers == 1, 'first client has exactly one expiration timer');

my ($second, $write2) = make_client('B', '192.0.2.22');
ok(accept_client($server, $second), 'second client accepted');
is($server->{CLIENTS_ACTIVE}, 2, 'second client counted');
is($server->{CLIENTS_PEAK}, 2, 'peak records concurrent active count');

my ($third, $write3) = make_client('C', '192.0.2.23');
ok(!accept_client($server, $third), 'third connection refused at client limit');
is($server->{CLIENTS_ACTIVE}, 2, 'limit refusal does not alter active count');
is($server->{CLIENTS_REJECTED}, 1, 'limit refusal counted once');
is($server->{FRAMES_ERROR}, 0, 'client limit refusal is not a frame parse error');
like($logs[-1], qr/client limit reached/, 'client limit is logged');

CommandDelete(undef, $first->{NAME});
is($server->{CLIENTS_ACTIVE}, 1, 'normal deletion decrements active count');
is($server->{CLIENTS_PEAK}, 2, 'peak persists after disconnect');
is(scalar(@timers), 1, 'closing client removes its expiration timer');

my ($fourth, $write4) = make_client('D', '192.0.2.24');
ok(accept_client($server, $fourth), 'slot is reusable after disconnect');
is($server->{CLIENTS_ACTIVE}, 2, 'reused slot counted');
WIFFI_Collector_Undef($fourth);
is($server->{CLIENTS_ACTIVE}, 1, 'direct Undef decrements only once');
WIFFI_Collector_Undef($fourth);
is($server->{CLIENTS_ACTIVE}, 1, 'repeated Undef does not underflow');
delete $defs{$fourth->{NAME}};
CommandDelete(undef, $second->{NAME});
is($server->{CLIENTS_ACTIVE}, 0, 'all active clients released');
is($server->{CLIENTS_PEAK}, 2, 'historical peak is retained');
ok(!exists $server->{READINGS}, 'internals do not create readings');

# Frame size is imposed PER complete frame, not on aggregate TCP bytes.
$server->{MAX_FRAME} = length(telegram('12.500'));
my ($frames_client, $write_frames) = make_client('frames', '192.0.2.25');
accept_client($server, $frames_client);
my $frame_a = telegram('12.500');
my $frame_b = telegram('22.500');
is(length($frame_a), $server->{MAX_FRAME}, 'test frame matches exact limit');
is(length($frame_b), $server->{MAX_FRAME}, 'second test frame matches exact limit');
my $combined = $frame_a."\x03".$frame_b."\x04";
ok(length($combined) > $server->{MAX_FRAME}, 'combined length exceeds single frame bound');
syswrite($write_frames, $combined) == length($combined)
  or die "unable to write coalesced frames";
WIFFI_Collector_Read($frames_client);
is($server->{FRAMES_OK}, 2, 'both coalesced complete frames are accepted');
is($device->{READINGS}{w_counter1}{VAL}, '22.5', 'JSON numeric value from second frame updates reading');
is($server->{FRAMES_ERROR}, 0, 'coalescing introduces no parse error');
is($server->{CLIENTS_ACTIVE}, 1, 'connection retained after complete frames');

# Over-limit COMPLETE frame gets one error; a subsequent independent frame
# on the same connection remains valid.
my $oversized = $frame_a." ";
my $mixed = $oversized."\x03".$frame_b."\x03";
syswrite($write_frames, $mixed) == length($mixed)
  or die "unable to write oversized frame";
WIFFI_Collector_Read($frames_client);
is($server->{FRAMES_ERROR}, 1, 'oversized complete frame rejected');
is($server->{FRAMES_OK}, 3, 'valid frame after oversized frame still processed');
is($device->{READINGS}{w_counter1}{VAL}, '22.5', 'valid JSON numeric frame remains visible');

# A buffer with no delimiter must not grow past the frame limit.
my $unfinished = 'X' x ($server->{MAX_FRAME} + 1);
syswrite($write_frames, $unfinished) == length($unfinished)
  or die "unable to write unfinished data";
WIFFI_Collector_Read($frames_client);
ok(!exists $defs{$frames_client->{NAME}}, 'oversize unfinished client closed');
is($server->{FRAMES_ERROR}, 2, 'unfinished frame counted once');
is($server->{CLIENTS_ACTIVE}, 0, 'oversize cleanup releases active slot');

# EOF is an allowed framing boundary for a valid, fully formed JSON telegram.
my ($eof_client, $eof_writer) = make_client('eof', '192.0.2.25');
accept_client($server, $eof_client);
$server->{MAX_FRAME} = 262144;
my $eof_data = telegram('33.333');
syswrite($eof_writer, $eof_data) == length($eof_data)
  or die "unable to write EOF telegram";
close($eof_writer);
WIFFI_Collector_Read($eof_client);
is($server->{FRAMES_OK}, 3, 'unterminated tail held until EOF');
WIFFI_Collector_Read($eof_client);
is($server->{FRAMES_OK}, 4, 'complete EOF tail accepted');
ok(!exists $defs{$eof_client->{NAME}}, 'EOF closes temporary client');
is($server->{CLIENTS_ACTIVE}, 0, 'EOF releases client count');

# Partial EOF tail is an error, never a published reading.
my ($partial_client, $partial_writer) = make_client('partial', '192.0.2.27');
accept_client($server, $partial_client);
print {$partial_writer} '{"modultyp":';
close($partial_writer);
WIFFI_Collector_Read($partial_client);
WIFFI_Collector_Read($partial_client);
is($server->{FRAMES_ERROR}, 3, 'truncated EOF tail rejected');
ok(!exists $defs{$partial_client->{NAME}}, 'partial EOF closes client');
is($server->{CLIENTS_ACTIVE}, 0, 'partial EOF frees active slot');

# A silent connection is a transport timeout, not a malformed telegram.
# Each timeout is logged, even when there is no unfinished frame.
my ($idle_client, $idle_writer) = make_client('idle', '192.0.2.28');
accept_client($server, $idle_client);
$idle_client->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time() - 61;
WIFFI_Collector_ClientTimeout($idle_client);
ok(!exists $defs{$idle_client->{NAME}}, 'idle client gets deleted on timeout');
is($server->{CLIENTS_ACTIVE}, 0, 'idle cleanup decrements active count');
is($server->{CLIENTS_TIMEOUT}, 1, 'idle timeout counted once');
is($server->{FRAMES_ERROR}, 3, 'empty idle connection is not a bad frame');
is($log_levels[-1], 3, 'empty-buffer timeout is logged at level 3');
like($logs[-1], qr/TCP client idle timeout.*no incomplete frame/,
  'timeout reason and absence of discarded frame logged');

# A complete valid frame can leave an open connection with an empty buffer.
my ($complete_client, $complete_writer) =
  make_client('idle-after-valid', '192.0.2.25');
accept_client($server, $complete_client);
my $valid_completed = telegram('44.444')."\x03";
is(syswrite($complete_writer, $valid_completed), length($valid_completed),
  'valid delimited frame sent before idle timeout');
WIFFI_Collector_Read($complete_client);
is($complete_client->{BUF}, '', 'valid frame removed from receive buffer');
is($server->{FRAMES_OK}, 5, 'frame accepted before subsequent timeout');
$complete_client->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time() - 61;
WIFFI_Collector_ClientTimeout($complete_client);
ok(!exists $defs{$complete_client->{NAME}},
  'previously valid client is closed on inactivity');
is($server->{CLIENTS_TIMEOUT}, 2, 'post-frame idle timeout counted');
is($server->{FRAMES_ERROR}, 3,
  'post-frame idle timeout does not invalidate successful frame');

# A real unfinished payload does count as a rejected frame. Its content is
# logged only on explicit opt-in; the normal timeout reason is always logged.
my ($unfinished_client, $unfinished_writer) =
  make_client('idle-partial', '192.0.2.29');
accept_client($server, $unfinished_client);
$unfinished_client->{BUF} = '{"modultyp":';
$unfinished_client->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time() - 61;
$attr{Collector}{logRejectedPayload} = 1;
WIFFI_Collector_ClientTimeout($unfinished_client);
delete $attr{Collector}{logRejectedPayload};
ok(!exists $defs{$unfinished_client->{NAME}},
  'unfinished connection released on timeout');
is($server->{CLIENTS_TIMEOUT}, 3, 'unfinished timeout counted');
is($server->{FRAMES_ERROR}, 4, 'discarded unfinished frame counted once');
is($log_levels[-1], 2, 'unfinished-frame timeout is logged at level 2');
like($logs[-1],
  qr/TCP client idle timeout; incomplete WIFFI frame discarded.*payload \(12 bytes\): \{"modultyp":/,
  'rejection reason and opt-in raw unfinished JSON are logged');

# Whitespace does not constitute a telegram (same contract as EOF and ETX).
my ($whitespace_client, $whitespace_writer) =
  make_client('idle-whitespace', '192.0.2.30');
accept_client($server, $whitespace_client);
$whitespace_client->{BUF} = " \t\n";
$whitespace_client->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time() - 61;
WIFFI_Collector_ClientTimeout($whitespace_client);
is($server->{CLIENTS_TIMEOUT}, 4, 'whitespace-only timeout counted');
is($server->{FRAMES_ERROR}, 4, 'whitespace-only tail not a rejected telegram');
is($log_levels[-1], 3, 'whitespace-only timeout logged at level 3');

# Absolute lifetime expires even with recent data; empty buffer does not
# become a spurious malformed frame.
my ($life_client, $life_writer) = make_client('lifetime', '192.0.2.31');
accept_client($server, $life_client);
$life_client->{'.WIFFI_ACCEPTED_AT'} = Time::HiRes::time() - 181;
$life_client->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time();
WIFFI_Collector_ClientTimeout($life_client);
ok(!exists $defs{$life_client->{NAME}},
  'absolute lifetime closes active sender');
is($server->{CLIENTS_TIMEOUT}, 5, 'absolute lifetime counted as timeout');
is($server->{FRAMES_ERROR}, 4, 'absolute lifetime not counted as bad frame');
is($log_levels[-1], 3, 'empty-buffer lifetime logged at level 3');
like($logs[-1], qr/TCP client lifetime exceeded/,
  'lifetime timeout distinguished in diagnostics');

# Absolute lifetime with an unfinished frame records both counters.
my ($life_partial, $life_partial_writer) =
  make_client('lifetime-partial', '192.0.2.32');
accept_client($server, $life_partial);
$life_partial->{BUF} = '{"vars":';
$life_partial->{'.WIFFI_ACCEPTED_AT'} = Time::HiRes::time() - 181;
$life_partial->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time();
WIFFI_Collector_ClientTimeout($life_partial);
is($server->{CLIENTS_TIMEOUT}, 6, 'unfinished lifetime counted as timeout');
is($server->{FRAMES_ERROR}, 5, 'unfinished lifetime is one frame rejection');
is($log_levels[-1], 2, 'unfinished lifetime rejected at level 2');
like($logs[-1], qr/TCP client lifetime exceeded; incomplete WIFFI frame/,
  'lifetime failure names the abandoned unfinished frame');
unlike($logs[-1], qr/payload \(/,
  'rejected payload is omitted again after disabling opt-in');

# A timer fired before its deadline should reschedule, not count an expiry.
my ($recent_client, $recent_writer) = make_client('recent', '192.0.2.33');
accept_client($server, $recent_client);
my $scheduled_before = scalar(@timers);
WIFFI_Collector_ClientTimeout($recent_client);
ok(scalar(@timers) == $scheduled_before + 1,
  'recent client reschedules for remaining idle/lifetime');
is($server->{CLIENTS_TIMEOUT}, 6, 'early timer callback is not a timeout');
is($server->{FRAMES_ERROR}, 5, 'early timer callback is not a frame error');
CommandDelete(undef, $recent_client->{NAME});

# Server Undef closes all current temporary clients, leaving no active count.
my ($one, $w1) = make_client('server-1', '192.0.2.31');
my ($two, $w2) = make_client('server-2', '192.0.2.32');
accept_client($server, $one);
accept_client($server, $two);
is($server->{CLIENTS_ACTIVE}, 2, 'two live clients before server close');
WIFFI_Collector_Undef($server);
is($server->{CLIENTS_ACTIVE}, 0, 'server close decrements every child');
ok(!exists $defs{$one->{NAME}} && !exists $defs{$two->{NAME}},
  'server close deletes temporary client devices');
is(scalar(@timers), 0, 'all client timer entries cleaned on server close');
close($_) for grep { defined(fileno($_)) } @writers;

done_testing();
