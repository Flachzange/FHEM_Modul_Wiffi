# SPDX-License-Identifier: GPL-2.0-or-later
# Nonblocking shared TCP collector for STALL WIFFI JSON
package main;
use strict;
use warnings;
use Errno qw(EAGAIN EWOULDBLOCK);
use TcpServerUtils;
use JSON::PP ();
use Time::HiRes ();
use FHEM::Meta;
use vars qw(%defs %selectlist $init_done $readingFnAttributes);

# Parser helpers live here so an installed FHEM module needs no additional .pm file.
sub WIFFI_Collector_NormalizeMac {
  my ($mac) = @_;
  return undef unless defined $mac;
  # Also accept exactly 12 hex digits without separators.
  $mac = join ':', ($mac =~ /(..)/g) if $mac =~ /\A[0-9a-fA-F]{12}\z/;
  my @octets = split /:/, $mac, -1;
  return undef unless @octets == 6;
  for my $octet (@octets) {
    return undef unless $octet =~ /\A[0-9a-fA-F]{1,2}\z/;
    $octet = sprintf '%02X', hex $octet;
  }
  return join ':', @octets;
}

# Keep values as delivered (including large decimals and boolean strings).
# JSON null means no new value: omit that reading from this update, not the
# entire telegram. Reject JSON containers rather than silently losing data.
sub WIFFI_Collector_ValueText {
  my ($value, $context) = @_;
  return undef unless defined $value;
  my $kind = ref($value);
  return $value ? 'true' : 'false' if $kind eq 'JSON::PP::Boolean';
  return "$value" if !$kind || $kind eq 'Math::BigInt' || $kind eq 'Math::BigFloat';
  die "$context: unsupported value type";
}

sub WIFFI_Collector_Decode {
  my ($raw) = @_;
  die "empty WIFFI telegram" unless defined $raw && length $raw;
  my $obj = JSON::PP->new->utf8->allow_bignum->decode($raw);
  die "expected JSON object" unless ref($obj) eq 'HASH';
  die "missing vars array" unless ref($obj->{vars}) eq 'ARRAY';
  die "missing Systeminfo" unless ref($obj->{Systeminfo}) eq 'HASH';
  die "missing or invalid modultyp"
    unless defined $obj->{modultyp} && !ref($obj->{modultyp})
      && length($obj->{modultyp});

  my $raw_mac = $obj->{Systeminfo}{'MAC-Adresse'};
  die "missing or invalid MAC-Adresse" unless defined $raw_mac && !ref($raw_mac);
  my $mac = WIFFI_Collector_NormalizeMac($raw_mac);
  die "missing or invalid MAC-Adresse" unless defined $mac;

  # Decode and validate EVERYTHING before any FHEM reading or heartbeat update.
  # Optional sensor fields may be absent; provided fields must be well-formed.
  my %readings;
  my %seen_names; # also track names whose value is JSON null
  my $reported_ip;
  for my $index (0 .. $#{$obj->{vars}}) {
    my $var = $obj->{vars}[$index];
    die "vars[$index]: expected JSON object" unless ref($var) eq 'HASH';
    my $name = $var->{homematic_name};
    die "vars[$index]: missing or invalid homematic_name"
      unless defined $name && !ref($name)
        && $name =~ /\A[A-Za-z_][A-Za-z0-9_.-]*\z/;
    die "vars[$index]: duplicate CCU name" if exists $seen_names{$name};
    $seen_names{$name} = 1;
    die "vars[$index]: reserved state reading" if $name eq 'state';
    die "vars[$index]: missing value" unless exists $var->{value};
    # Optional metadata may be JSON null (unknown); containers are invalid.
    for my $metadata (qw(name type)) {
      next unless exists $var->{$metadata} && defined $var->{$metadata};
      die "vars[$index]: invalid $metadata" if ref($var->{$metadata});
    }

    my $text = WIFFI_Collector_ValueText($var->{value}, "vars[$index]");
    next unless defined $text; # JSON null: preserve existing reading and timestamp
    $readings{$name} = $text;
    $reported_ip = $text
      if defined $var->{name} && $var->{name} eq '0';
  }

  for my $key (keys %{$obj->{Systeminfo}}) {
    # The mandatory hyphenated MAC key identifies the sender, but is not
    # a public Systeminfo reading (same policy as the original collector).
    next if $key eq 'MAC-Adresse';
    die "Systeminfo: invalid field name"
      unless $key =~ /\A[A-Za-z_][A-Za-z0-9_.-]*\z/;
    my $name = "Systeminfo_$key";
    die "Systeminfo: reading name collision" if exists $seen_names{$name};
    my $text = WIFFI_Collector_ValueText($obj->{Systeminfo}{$key}, "Systeminfo");
    next unless defined $text; # optional Systeminfo null: no update
    $readings{$name} = $text;
  }

  return {
    mac         => $mac,
    modultyp    => "$obj->{modultyp}",
    reported_ip => $reported_ip,
    readings    => \%readings,
  };
}

# Log every rejected frame. Raw payload logging is an explicit opt-in because
# values can include device identifiers and user-defined names. Escape control
# characters so a malformed frame cannot forge additional FHEM log entries.
sub WIFFI_Collector_LogRejected {
  my ($server, $peer, $reason, $raw) = @_;
  $reason //= 'unknown error';
  $reason =~ s/[\x00-\x1F\x7F]/ /g;
  my $message = "$server->{NAME}: invalid WIFFI from $peer: $reason";
  if (AttrVal($server->{NAME}, 'logRejectedPayload', 0)) {
    my $payload = defined $raw ? $raw : '';
    my $length = length($payload);
    # Bound log amplification while including normal WIFFI telegrams in full.
    my $max_log_bytes = 16384;
    my $truncated = $length > $max_log_bytes;
    $payload = substr($payload, 0, $max_log_bytes) if $truncated;
    $payload =~ s/([\x00-\x1F\x7F])/sprintf('\\x%02X', ord($1))/ge;
    $message .= " | payload ($length bytes".
      ($truncated ? ', truncated' : '')."): $payload";
  }
  Log3($server, 2, $message);
}

# Extract each wire frame independently. Keep whitespace for the byte-size check
# and diagnostic payloads; JSON::PP already permits surrounding whitespace.
sub WIFFI_Collector_ExtractFrames {
  my ($buffer_ref) = @_;
  my @frames;
  while ($$buffer_ref =~ /[\x03\x04]/) {
    my $pos = $-[0];
    my $frame = substr($$buffer_ref, 0, $pos, '');
    substr($$buffer_ref, 0, 1, '');
    push @frames, $frame if $frame =~ /\S/;
  }
  return @frames;
}

sub WIFFI_Collector_Initialize {
  my ($hash) = @_;
  $hash->{DefFn} = 'WIFFI_Collector_Define';
  $hash->{UndefFn} = 'WIFFI_Collector_Undef';
  $hash->{ReadFn} = 'WIFFI_Collector_Read';
  $hash->{SetFn} = 'WIFFI_Collector_Set';
  $hash->{AttrFn} = 'WIFFI_Collector_Attr';
  $hash->{RenameFn} = 'WIFFI_Collector_Rename';
  $hash->{Clients} = ':WIFFI_DEVICE:';
  $hash->{AttrList} = 'autocreate:0,1 logRejectedPayload:0,1 disable:0,1 allowfrom '.$readingFnAttributes;
  return FHEM::Meta::InitMod(__FILE__, $hash);
}

# Start and stop the listener through one path for initial define, modify
# and explicit recovery. TcpServerUtils owns %selectlist/socket registration.
# In the inspected FHEM TcpServer_Close implementation, the closed socket
# remains in SERVERSOCKET; remove stale metadata before a future reopen.
sub WIFFI_Collector_CloseListener {
  my ($hash, $reason) = @_;
  my $name = $hash->{NAME};
  # Invalidate any Read() currently processing a batch of TCP frames.
  # A rename must not change this generation; reopen/modify/delete do.
  ++$hash->{'.WIFFI_LISTENER_GEN'};
  RemoveInternalTimer($hash); # also cancels a deferred initial bind

  # Delete temporary children while their parent still exists; FHEM may
  # refuse CommandDelete if a child UndefFn/DeleteFn returns an error.
  my @failed;
  for my $client_name (keys %defs) {
    my $client = $defs{$client_name};
    next unless $client && $client->{TYPE} eq 'WIFFI_Collector'
      && defined $client->{SNAME} && $client->{SNAME} eq $name;
    my $err = CommandDelete(undef, $client_name);
    my $remains = $defs{$client_name} && $defs{$client_name} == $client;
    next unless $err || $remains;
    my $detail = $err || 'temporary client still defined after deletion';
    $detail .= ' (client still defined)' if $err && $remains;
    $detail =~ s/[\x00-\x1F\x7F]/ /g;
    $detail = substr($detail, 0, 500);
    Log3($hash, 1, "$name: TCP client $client_name cleanup failed".
      (defined $reason ? " ($reason)" : '').": $detail");
    push @failed, "$client_name: $detail";
  }
  if (defined $hash->{SERVERSOCKET}) {
    TcpServer_Close($hash);
    Log3($hash, 3, "$name: WIFFI listener closed".
      (defined $reason ? " ($reason)" : ''));
  }
  delete @{$hash}{qw(SERVERSOCKET FD PORT stacktrace)};
  # Derive live client count from surviving sockets, even if a refused
  # deletion left a temporary FHEM child in %defs.
  $hash->{CLIENTS_ACTIVE} = scalar grep {
    my $client = $defs{$_};
    $client && $client->{TYPE} eq 'WIFFI_Collector'
      && ($client->{SNAME} // '') eq $name
      && defined $client->{CD}
  } keys %defs;
  if (@failed) {
    my $err = "$name: TCP client cleanup failed for ".join(', ', @failed);
    $hash->{LISTENER_STATUS} = 'error';
    $hash->{LISTENER_ERROR} = $err;
    return $err;
  }
  $hash->{LISTENER_STATUS} = 'stopped';
  return undef;
}

sub WIFFI_Collector_OpenListener {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $port = $hash->{TCP_PORT};
  my $err = TcpServer_Open($hash, $port, 'global');
  if ($err) {
    # TcpServer_Open can leave SERVERSOCKET defined but false after a
    # failed bind, and it updates FHEM's state reading before binding.
    delete @{$hash}{qw(SERVERSOCKET FD PORT stacktrace)};
    $hash->{LISTENER_STATUS} = 'error';
    $hash->{LISTENER_ERROR} = "$err";
    Log3($hash, 1, "$name: WIFFI listener could not bind TCP port ".
      "$port: $err; use 'set $name reopen' after correcting the cause");
    return $err;
  }
  $hash->{LISTENER_STATUS} = 'listening';
  $hash->{LISTENER_ERROR} = '';
  Log3($hash, 3, "$name: WIFFI listener listening on TCP port $port");
  return undef;
}

# FHEM calls AttrFn before storing/removing the attribute. The requested
# transition therefore comes from $cmd/$value, not AttrVal(disable).
sub WIFFI_Collector_Attr {
  my ($cmd, $name, $attr_name, $value) = @_;
  return undef unless $attr_name eq 'disable';
  my $hash = $defs{$name};
  return undef unless $hash && !defined $hash->{SNAME};

  if ($cmd eq 'set') {
    return 'Usage: attr <collector> disable 0|1'
      unless defined $value && $value =~ /\A[01]\z/;
    if ($value eq '1') {
      # During config loading, the deferred initial bind will check disable.
      WIFFI_Collector_CloseListener($hash, 'disabled') if $init_done;
      return undef;
    }
  } elsif ($cmd ne 'del' || AttrVal($name, 'disable', 0) ne '1') {
    return undef;
  }

  return undef unless $init_done;
  return undef if defined $hash->{SERVERSOCKET};
  # Reuse the existing cleanup contract, including partial client deletion.
  my $err = WIFFI_Collector_CloseListener($hash, 'enable');
  return $err if $err;
  WIFFI_Collector_OpenListener($hash);
  return undef; # A failed bind remains visible through LISTENER_ERROR.
}

sub WIFFI_Collector_Define {
  my ($hash, $def) = @_;
  my @parts = split /\s+/, $def;
  my ($name, $type, $port) = @parts;
  return 'Usage: define <name> WIFFI_Collector <tcp-port>'
    unless @parts == 3 && $port =~ /\A[0-9]{1,5}\z/
      && $port >= 1 && $port <= 65535;
  return $@ unless FHEM::Meta::SetInternals($hash);

  # FHEM invokes DefFn on modify with OLDDEF set, reusing the same hash.
  # Reject invalid port arguments BEFORE tearing down a healthy listener.
  if (exists $hash->{OLDDEF} || defined $hash->{SERVERSOCKET}) {
    my $err = WIFFI_Collector_CloseListener($hash, 'modify');
    return $err if $err; # FHEM CommandModify will restore the old DEF.
  }

  $hash->{TCP_PORT} = $port;
  $hash->{MAX_FRAME} = 262144;
  $hash->{FRAMES_OK} = 0;
  $hash->{FRAMES_ERROR} = 0;
  $hash->{FRAMES_UNKNOWN} = 0;
  $hash->{AUTOCREATED} = 0;
  # Connection statistics are internals, not readings/events/DbLog records.
  $hash->{CLIENTS_ACTIVE} = 0;
  $hash->{CLIENTS_PEAK} = 0;
  $hash->{CLIENTS_REJECTED} = 0;
  $hash->{CLIENTS_TIMEOUT} = 0;
  $hash->{MAX_CLIENTS} = 16;
  $hash->{CLIENT_IDLE_TIMEOUT} = 60;
  $hash->{CLIENT_MAX_LIFETIME} = 180;
  $hash->{LISTENER_STATUS} = 'stopped';
  $hash->{LISTENER_ERROR} = '';

  if ($init_done) {
    return undef if AttrVal($name, 'disable', 0) eq '1';
    # Preserve the defined collector on a failed bind so an operator can
    # inspect LISTENER_ERROR and recover with set <collector> reopen.
    WIFFI_Collector_OpenListener($hash);
    return undef;
  }
  InternalTimer(0, sub {
    # The collector may have been renamed before startup initialization ends.
    my $current_name = $hash->{NAME};
    return unless $defs{$current_name} && $defs{$current_name} == $hash;
    return if AttrVal($current_name, 'disable', 0) eq '1';
    WIFFI_Collector_OpenListener($hash);
  }, $hash, 0);
  return undef;
}

sub WIFFI_Collector_Set {
  my ($hash, $name, $cmd, @args) = @_;
  return 'Unknown argument '.($cmd // '').', choose one of reopen'
    unless defined $cmd && $cmd eq 'reopen';
  return 'Usage: set <collector> reopen' if @args;
  return 'WIFFI collector is disabled' if AttrVal($name, 'disable', 0) eq '1';
  my $err = WIFFI_Collector_CloseListener($hash, 'manual reopen');
  return $err if $err;
  $err = WIFFI_Collector_OpenListener($hash);
  return $err if $err;
  return undef;
}

# FHEM renames the device in %defs before calling RenameFn($new,$old).
# Migrate the listener selectlist key and internal references in place;
# interrupting an active listener is unnecessary.
sub WIFFI_Collector_Rename {
  my ($new, $old) = @_;
  my $hash = $defs{$new};
  return unless $hash && $hash->{TYPE} eq 'WIFFI_Collector';
  my $port = $hash->{PORT};
  if (defined $hash->{SERVERSOCKET} && defined $port
      && exists $selectlist{"$old.$port"}) {
    $selectlist{"$new.$port"} = delete $selectlist{"$old.$port"};
  }
  for my $device (values %defs) {
    next unless $device && $device->{TYPE};
    if ($device->{TYPE} eq 'WIFFI_Collector'
        && defined $device->{SNAME} && $device->{SNAME} eq $old) {
      $device->{SNAME} = $new;
    } elsif ($device->{TYPE} eq 'WIFFI_DEVICE') {
      next unless ($device->{IODev} && $device->{IODev} == $hash)
        || AttrVal($device->{NAME}, 'IODev', '') eq $old;
      # Legacy definitions still contain the old collector name until the
      # user migrates them. Modern DEF contains only the MAC address.
      $device->{DEF} =~ s/\A\Q$old\E(?=\s)/$new/
        if defined $device->{DEF};
      if (AttrVal($device->{NAME}, 'IODev', '') eq $old) {
        my $error = CommandAttr(undef, "$device->{NAME} IODev $new");
        Log3($hash, 2, "$new: could not update $device->{NAME} IODev: $error")
          if $error;
      }
    }
  }
  Log3($hash, 3, "$new: WIFFI collector renamed from $old; ".
    "client and logical-device references updated");
  return;
}

# One timeout timer per temporary connection, scheduled on accept and then
# only when the previous timer fires. The last activity time is updated on
# sysread; the absolute connection lifetime also bounds slow-drip senders.
sub WIFFI_Collector_ClientTimeout {
  my ($client) = @_;
  my $name = $client->{NAME};
  return unless $defs{$name} && $defs{$name} == $client;
  my $server = $defs{$client->{SNAME} // ''};
  return unless $server && $server->{TYPE} eq 'WIFFI_Collector';
  my $now = Time::HiRes::time();
  my $idle_deadline = ($client->{'.WIFFI_LAST_ACTIVITY'} // $now)
                    + ($server->{CLIENT_IDLE_TIMEOUT} // 60);
  my $life_deadline = ($client->{'.WIFFI_ACCEPTED_AT'} // $now)
                    + ($server->{CLIENT_MAX_LIFETIME} // 180);
  if ($now >= $idle_deadline || $now >= $life_deadline) {
    ++$server->{CLIENTS_TIMEOUT};
    my $reason = $now >= $life_deadline
      ? 'TCP client lifetime exceeded' : 'TCP client idle timeout';
    my $tail = $client->{BUF} // '';
    if ($tail =~ /\S/) {
      # Count only a discarded unfinished telegram as a frame error.
      # Empty/whitespace-only buffers may follow entirely valid telegrams.
      ++$server->{FRAMES_ERROR};
      WIFFI_Collector_LogRejected($server, $client->{PEER},
        "$reason; incomplete WIFFI frame discarded", $tail);
    } else {
      Log3($server, 3, "$server->{NAME}: $reason for $name ".
        "($client->{PEER}); no incomplete frame");
    }
    CommandDelete(undef, $name);
    return;
  }
  my $next_deadline = $idle_deadline < $life_deadline
                    ? $idle_deadline : $life_deadline;
  InternalTimer($next_deadline, 'WIFFI_Collector_ClientTimeout', $client, 0);
}

sub WIFFI_Collector_Undef {
  my ($hash) = @_;
  RemoveInternalTimer($hash);
  # TcpServer_Accept registers temporary children in %defs/%selectlist.
  # Undef is their common cleanup path (EOF, timeout, read error, shutdown).
  if (defined $hash->{SNAME}) {
    my $server = $defs{$hash->{SNAME}};
    if (delete $hash->{'.WIFFI_COUNTED'} && $server
        && $server->{TYPE} eq 'WIFFI_Collector') {
      --$server->{CLIENTS_ACTIVE} if ($server->{CLIENTS_ACTIVE} // 0) > 0;
    }
    return TcpServer_Close($hash);
  }
  return WIFFI_Collector_CloseListener($hash, 'undefine');
}

# Reentrant FHEM notify/DOIF callbacks may delete, rename, modify or reopen
# devices from inside readingsEndUpdate(). Check hash ownership rather than
# relying on names or file descriptors (which the OS can reuse).
sub WIFFI_Collector_ClientCurrent {
  my ($client, $server, $generation) = @_;
  return defined $client->{CD}
    && defined $server->{SERVERSOCKET}
    && $defs{$client->{NAME}} && $defs{$client->{NAME}} == $client
    && $defs{$server->{NAME}} && $defs{$server->{NAME}} == $server
    && ($client->{SNAME} // '') eq $server->{NAME}
    && ($server->{'.WIFFI_LISTENER_GEN'} // 0) == $generation;
}

sub WIFFI_Collector_Read {
  my ($hash) = @_;
  return if !$defs{$hash->{NAME}} || $defs{$hash->{NAME}} != $hash;
  if ($hash->{SERVERSOCKET}) {
    my $client = TcpServer_Accept($hash, 'WIFFI_Collector');
    return unless $client;
    $client->{CD}->blocking(0);
    if (($hash->{CLIENTS_ACTIVE} // 0) >= ($hash->{MAX_CLIENTS} // 16)) {
      ++$hash->{CLIENTS_REJECTED};
      Log3($hash, 2, "$hash->{NAME}: client limit reached; ".
        "rejecting $client->{PEER} (max $hash->{MAX_CLIENTS})");
      CommandDelete(undef, $client->{NAME});
      return;
    }
    $client->{'.WIFFI_COUNTED'} = 1;
    ++$hash->{CLIENTS_ACTIVE};
    $hash->{CLIENTS_PEAK} = $hash->{CLIENTS_ACTIVE}
      if $hash->{CLIENTS_ACTIVE} > ($hash->{CLIENTS_PEAK} // 0);
    my $now = Time::HiRes::time();
    $client->{'.WIFFI_ACCEPTED_AT'} = $now;
    $client->{'.WIFFI_LAST_ACTIVITY'} = $now;
    InternalTimer($now + ($hash->{CLIENT_IDLE_TIMEOUT} // 60),
      'WIFFI_Collector_ClientTimeout', $client, 0);
    return;
  }
  my $server = $defs{$hash->{SNAME}};
  unless ($server && $server->{TYPE} eq 'WIFFI_Collector') {
    CommandDelete(undef, $hash->{NAME});
    return;
  }
  my $generation = $server->{'.WIFFI_LISTENER_GEN'} // 0;
  return unless WIFFI_Collector_ClientCurrent($hash, $server, $generation);
  my $chunk = '';
  my $n = sysread($hash->{CD}, $chunk, 8192);
  if (!defined $n) {
    return if $! == EAGAIN || $! == EWOULDBLOCK;
    Log3($server, 3, "$hash->{NAME}: TCP read error: $!");
    CommandDelete(undef, $hash->{NAME});
    return;
  }
  if ($n == 0) {
    my $tail = $hash->{BUF} // '';
    # Some classic WIFFI firmware closes its TCP socket instead of sending
    # ETX/EOT. EOF is a complete boundary, not permission for partial JSON.
    WIFFI_Collector_ProcessFrame($server, $tail, $hash->{PEER}, $hash, $generation)
      if $tail =~ /\S/;
    CommandDelete(undef, $hash->{NAME})
      if $defs{$hash->{NAME}} && $defs{$hash->{NAME}} == $hash;
    return;
  }

  $hash->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time();
  $hash->{BUF} .= $chunk;
  my $max_frame = $server->{MAX_FRAME} // 262144;
  # First extract ALL complete frames. Their combined size is not limited by
  # MAX_FRAME; only an individual complete frame or the unfinished tail is.
  my @frames = WIFFI_Collector_ExtractFrames(\$hash->{BUF});
  for my $index (0 .. $#frames) {
    my $frame = $frames[$index];
    last unless WIFFI_Collector_ClientCurrent($hash, $server, $generation);
    my $keep_connection = 1;
    if (length($frame) > $max_frame) {
      ++$server->{FRAMES_ERROR};
      WIFFI_Collector_LogRejected($server, $hash->{PEER},
        "oversized WIFFI frame (".length($frame)." bytes, max $max_frame)",
        $frame);
    } else {
      $keep_connection = WIFFI_Collector_ProcessFrame(
        $server, $frame, $hash->{PEER}, $hash, $generation);
    }
    if (!$keep_connection) {
      # A device was deleted/redefined during its Reading event. Drop any
      # pending frames on this connection instead of delivering stale data.
      CommandDelete(undef, $hash->{NAME})
        if WIFFI_Collector_ClientCurrent($hash, $server, $generation);
    }
    if (!$keep_connection
        || !WIFFI_Collector_ClientCurrent($hash, $server, $generation)) {
      my $dropped = $#frames - $index;
      Log3($server, 3, "$server->{NAME}: TCP frame batch stopped after ".
        "reentrant FHEM device or listener change ($hash->{PEER}); ".
        "discarding $dropped remaining complete frame(s)");
      return;
    }
  }
  return unless WIFFI_Collector_ClientCurrent($hash, $server, $generation);
  if (length($hash->{BUF}) > $max_frame) {
    ++$server->{FRAMES_ERROR};
    WIFFI_Collector_LogRejected($server, $hash->{PEER},
      "oversized unfinished WIFFI frame (max $max_frame bytes)", $hash->{BUF});
    CommandDelete(undef, $hash->{NAME});
    return;
  }
}

# Return 1 to continue processing coalesced frames (even if this individual
# telegram was rejected), or 0 if a synchronous FHEM event invalidated the
# current target/connection. Direct decoder callers may omit client context.
sub WIFFI_Collector_ProcessFrame {
  my ($server, $raw, $peer, $client, $generation) = @_;
  my $packet = eval { WIFFI_Collector_Decode($raw) };
  if (!$packet) {
    $server->{FRAMES_ERROR}++;
    my $error = $@ || 'unknown JSON error';
    chomp $error;
    WIFFI_Collector_LogRejected($server, $peer, $error, $raw);
    return 1;
  }

  # Match existing logical devices by the complete normalized MAC.  Never
  # silently adopt a device solely because its FHEM name or sender IP matches.
  my @matches;
  my $peer_conflict;
  for my $hash (values %defs) {
    next unless $hash->{TYPE} eq 'WIFFI_DEVICE';
    next unless $hash->{IODev} && $hash->{IODev} == $server;
    if (($hash->{MAC} // '') eq $packet->{mac}) {
      push @matches, $hash;
    } elsif (defined $hash->{PEER} && $hash->{PEER} eq $peer) {
      $peer_conflict = $hash;
    }
  }

  if (@matches > 1 || $peer_conflict) {
    $server->{FRAMES_ERROR}++;
    WIFFI_Collector_LogRejected($server, $peer,
      'WIFFI identity conflict', $raw);
    return 1;
  }
  my $device = $matches[0];
  # A disabled logical device keeps its identity but receives no telemetry;
  # this is deliberate, not an unknown device or malformed frame.
  if ($device && AttrVal($device->{NAME}, 'disable', 0) eq '1') {
    # Disabling a logical device does not stop valid collector reception.
    $server->{LAST_TELEGRAM} = TimeNow();
    return 1;
  }
  if ($device && defined $device->{PEER} && $device->{PEER} ne $peer) {
    $server->{FRAMES_ERROR}++;
    WIFFI_Collector_LogRejected($server, $peer,
      "WIFFI MAC changed sender IP: ".
      "$device->{NAME} ($device->{PEER} -> $peer); check device identity", $raw);
    return 1;
  }

  # Accepted sender, whether assigned or not. Invalid/conflicting frames
  # do not advance this diagnostic INTERNAL.
  $server->{LAST_TELEGRAM} = TimeNow();

  # Stable, unambiguous default names.  Using the full MAC also makes the
  # name independent of firmware-specific modultyp strings.
  if (!$device && AttrVal($server->{NAME}, 'autocreate', 0)) {
    my $suffix = $packet->{mac};
    $suffix =~ s/://g;
    my $name = 'WIFFI_' . $suffix;
    if ($defs{$name}) {
      Log3($server, 2, "$server->{NAME}: autocreate name already exists: $name");
    } else {
      my $error = CommandDefine(undef,
        "$name WIFFI_DEVICE $server->{NAME} $packet->{mac}");
      return 0 if $client
        && !WIFFI_Collector_ClientCurrent($client, $server, $generation);
      if ($error) {
        Log3($server, 2, "$server->{NAME}: autocreate failed: $error");
      } else {
        # CommandDefine triggers DEFINED events. A user automation may have
        # renamed, changed or deleted the device while it was being created.
        my $created = $defs{$name};
        if ($created && $created->{TYPE} eq 'WIFFI_DEVICE'
            && $created->{IODev} && $created->{IODev} == $server
            && ($created->{MAC} // '') eq $packet->{mac}) {
          # Defaults apply only at creation, never to existing devices.
          # WIFFI-pump uses its real pump feedback for FHEMWEB status.
          # Do not override attributes set by a DEFINED event handler.
          my @defaults = (
            ['IODev', $server->{NAME}],
            ['room', 'WIFFI'],
            ['event-on-change-reading', '.*'],
            ['event-on-update-reading', 'Systeminfo_sec_seit_reset'],
            ['DbLogExclude', '^Systeminfo_sec_seit_reset$']
          );
          if ($packet->{modultyp} eq 'wiffi-pump') {
            push @defaults, ['stateFormat', 'wiffi_pump'],
                            ['devStateIcon', 'true:on false:off'];
          }
          for my $default (@defaults) {
            my ($key, $value) = @$default;
            next if defined AttrVal($name, $key, undef);
            my $attr_error = CommandAttr(undef, "$name $key $value");
            return 0 if $client
              && !WIFFI_Collector_ClientCurrent($client, $server, $generation);
            Log3($server, 2, "$server->{NAME}: default attr $key failed: $attr_error")
              if $attr_error;
            # ATTR notifications may remove or rename the new device.
            if (!$defs{$name} || $defs{$name} != $created) {
              $created = undef;
              last;
            }
          }
          if ($created) {
            # The legacy two-argument form supplies the source collector
            # during autocreate. Once IODev is persisted, keep only MAC in DEF.
            $created->{DEF} = $packet->{mac}
              if ($created->{DEF} // '') eq "$server->{NAME} $packet->{mac}";
            $device = $created;
            $server->{AUTOCREATED}++;
            Log3($server, 3, "$server->{NAME}: autocreated $name");
          }
        }
        if (!$device) {
          Log3($server, 2, "$server->{NAME}: autocreated device was changed ".
            "during setup; telegram not assigned");
        }
      }
    }
  }

  if (!$device) {
    $server->{FRAMES_UNKNOWN}++;
    Log3($server, 4, "$server->{NAME}: unknown WIFFI $packet->{mac} ($peer)");
    return 1;
  }

  if ($packet->{reported_ip} && $peer ne $packet->{reported_ip}) {
    Log3($server, 3, "$server->{NAME}: reported IP $packet->{reported_ip} ".
      "differs from TCP peer $peer");
  }
  # WIFFI_DEVICE_Process stores the peer and module identity before
  # publishing readings, which may trigger reentrant FHEM callbacks.
  my $device_revision = $device->{'.WIFFI_DEFINITION_GEN'} // 0;
  if (!WIFFI_DEVICE_Process($device, $packet, $peer)) {
    $server->{FRAMES_ERROR}++;
    WIFFI_Collector_LogRejected($server, $peer,
      "reading mapping rejected by $device->{NAME}", $raw);
    return 1;
  }
  # A rename retains the same hash and remains valid. A deleted/recreated
  # device or an explicit modify invalidates the frame's logical target.
  return 0 unless $defs{$device->{NAME}}
    && $defs{$device->{NAME}} == $device
    && ($device->{'.WIFFI_DEFINITION_GEN'} // 0) == $device_revision
    && $device->{IODev} && $device->{IODev} == $server;
  ++$server->{FRAMES_OK}
    if $defs{$server->{NAME}} && $defs{$server->{NAME}} == $server;
  return 1;
}
1;
=pod
=item device
=item summary TCP/JSON receiver for classic STALL WIFFI devices
=item summary_DE TCP/JSON-Empf&auml;nger f&uuml;r klassische STALL-WIFFI-Ger&auml;te

=begin html

<a id="WIFFI_Collector"></a>
<h3>WIFFI_Collector</h3>
<p>
  Receives TCP/JSON telegrams from classic STALL WIFFI devices and forwards
  validated measurements to logical <code>WIFFI_DEVICE</code> definitions.
  One collector listens on one TCP port; each physical device has its own
  logical FHEM definition.
</p>
<a id="WIFFI_Collector-define"></a>
<h4>Define</h4>
<ul>
  <li><code>define &lt;name&gt; WIFFI_Collector &lt;tcp-port&gt;</code><br>
      Listen on the given TCP port (1 to 65535).
      Example: <code>define WIFFI_Collector WIFFI_Collector 9195</code>.
      Only one listener is created for this collector.</li>
</ul>
<a id="WIFFI_Collector-set"></a>
<h4>Set</h4>
<ul>
  <li><a id="WIFFI_Collector-set-reopen"></a><b>reopen</b><br>
      Close the current listener and accepted connections, then reopen the
      configured TCP port. Useful after a bind failure or port change.
      Rejected while the collector is disabled. A failed bind is reported
      through the diagnostic INTERNALS and FHEM log.</li>
</ul>
<a id="WIFFI_Collector-attr"></a>
<h4>Attributes</h4>
<ul>
  <li><a id="WIFFI_Collector-attr-autocreate"></a><b>autocreate</b> (0,1; default 0)<br>
      Automatically create a <code>WIFFI_DEVICE</code> for an unknown,
      validated MAC address. Existing devices are matched by their complete
      normalized MAC address. Newly created devices receive default FHEM
      room, event and DbLog attributes; existing user-defined attributes
      are not overwritten.</li>
  <li><a id="WIFFI_Collector-attr-allowfrom"></a><b>allowfrom</b><br>
      FHEM/TcpServerUtils sender restriction. Allow only trusted source
      addresses on the local network; the WIFFI protocol does not
      cryptographically authenticate senders.</li>
  <li><a id="WIFFI_Collector-attr-disable"></a><b>disable</b> (0,1; default 0)<br>
      With 1, close the listening socket and all accepted TCP client
      connections; do not listen at startup. With 0, or after
      <code>deleteattr &lt;name&gt; disable</code>, reopen the configured
      port. Logical device definitions and their last readings are
      retained. Disabling only the collector does not block separate
      HTTP commands sent by an enabled <code>WIFFI_DEVICE</code>.</li>
  <li><a id="WIFFI_Collector-attr-logRejectedPayload"></a><b>logRejectedPayload</b> (0,1; default 0)<br>
      When enabled, include rejected raw telegram data in FHEM diagnostics.
      Raw data can contain sensitive sensor values and identifiers.
      Normally leave this setting disabled.</li>
</ul>
<a id="WIFFI_Collector-internals"></a>
<h4>Diagnostics (INTERNALS)</h4>
<ul>
  <li><code>FVERSION</code>: version of the installed FHEM module
      (different from the WIFFI firmware version).</li>
  <li><code>LAST_TELEGRAM</code>: local receive time of the most recent
      valid decoded/identity-accepted WIFFI telegram, even from an
      unassigned or disabled logical device. No Reading or event.</li>
  <li><code>FRAMES_OK</code>, <code>FRAMES_ERROR</code>,
      <code>FRAMES_UNKNOWN</code>, <code>AUTOCREATED</code>:
      accepted, rejected, unassigned and automatically assigned frames
      or devices.</li>
  <li><code>LISTENER_STATUS</code> (<code>listening</code>,
      <code>stopped</code> or <code>error</code>),
      <code>LISTENER_ERROR</code>, <code>TCP_PORT</code>:
      receiver status and bind/cleanup diagnostics.</li>
  <li><code>CLIENTS_ACTIVE</code>, <code>CLIENTS_PEAK</code>,
      <code>CLIENTS_REJECTED</code>, <code>CLIENTS_TIMEOUT</code>,
      <code>MAX_CLIENTS</code>, <code>CLIENT_IDLE_TIMEOUT</code>,
      <code>CLIENT_MAX_LIFETIME</code>, <code>MAX_FRAME</code>:
      connection and size limits. These are INTERNALS, not sensor readings.</li>
</ul>

=end html

=begin html_DE

<a id="WIFFI_Collector"></a>
<h3>WIFFI_Collector</h3>
<p>
  Empf&auml;ngt TCP/JSON-Telegramme klassischer STALL-WIFFI-Ger&auml;te und
  &uuml;bergibt gepr&uuml;fte Messwerte an logische
  <code>WIFFI_DEVICE</code>-Definitionen. Ein Collector verwendet einen
  TCP-Port; jedes physische Ger&auml;t besitzt eine eigene logische
  FHEM-Definition.
</p>
<a id="WIFFI_Collector-define"></a>
<h4>Define</h4>
<ul>
  <li><code>define &lt;name&gt; WIFFI_Collector &lt;tcp-port&gt;</code><br>
      Startet den TCP-Empfang auf dem angegebenen Port (1 bis 65535).
      Beispiel: <code>define WIFFI_Collector WIFFI_Collector 9195</code>.
      Der Collector verwendet genau einen Listener.</li>
</ul>
<a id="WIFFI_Collector-set"></a>
<h4>Set</h4>
<ul>
  <li><a id="WIFFI_Collector-set-reopen"></a><b>reopen</b><br>
      Schlie&szlig;t den Listener und bestehende TCP-Verbindungen und
      &ouml;ffnet den konfigurierten Port erneut. Beispielsweise nach
      einem Fehler beim Port-Binding. Bei deaktiviertem Collector
      nicht erlaubt. Fehler stehen in den Diagnose-INTERNALS und im
      FHEM-Log.</li>
</ul>
<a id="WIFFI_Collector-attr"></a>
<h4>Attribute</h4>
<ul>
  <li><a id="WIFFI_Collector-attr-autocreate"></a><b>autocreate</b> (0,1; Standard 0)<br>
      Legt f&uuml;r eine noch unbekannte, gepr&uuml;fte MAC-Adresse
      automatisch ein <code>WIFFI_DEVICE</code> an.
      Vorhandene Ger&auml;te werden &uuml;ber ihre vollst&auml;ndige,
      normalisierte MAC-Adresse erkannt. Nur neue Ger&auml;te erhalten
      voreingestellte Raum-, Event- und DbLog-Attribute. Benutzerattribute
      vorhandener Ger&auml;te bleiben unver&auml;ndert.</li>
  <li><a id="WIFFI_Collector-attr-allowfrom"></a><b>allowfrom</b><br>
      FHEM/TcpServerUtils-Beschr&auml;nkung erlaubter Absender.
      Den Empfang auf vertrauensw&uuml;rdige Adressen im lokalen
      Netzwerk begrenzen. Das WIFFI-Protokoll authentifiziert
      Absender nicht kryptografisch.</li>
  <li><a id="WIFFI_Collector-attr-disable"></a><b>disable</b> (0,1; Standard 0)<br>
      Mit 1 werden Listener und bestehende TCP-Verbindungen geschlossen.
      Bei deaktiviertem Collector wird auch beim FHEM-Start kein Port
      ge&ouml;ffnet. Mit 0 oder <code>deleteattr &lt;name&gt; disable</code>
      wird der konfigurierte Port wieder ge&ouml;ffnet.
      Ger&auml;tedefinitionen und vorhandene Messwerte bleiben erhalten.
      Die Deaktivierung des Collectors sperrt nicht automatisch die
      unabh&auml;ngige HTTP-Steuerung aktiver <code>WIFFI_DEVICE</code>.</li>
  <li><a id="WIFFI_Collector-attr-logRejectedPayload"></a><b>logRejectedPayload</b> (0,1; Standard 0)<br>
      Schreibt bei Fehlern zus&auml;tzlich das abgewiesene rohe
      Telegramm ins FHEM-Log. Das kann vertrauliche Messwerte oder
      Kennungen enthalten. Normalerweise ausgeschaltet lassen.</li>
</ul>
<a id="WIFFI_Collector-internals"></a>
<h4>Diagnose (INTERNALS)</h4>
<ul>
  <li><code>FVERSION</code>: Version des installierten FHEM-Moduls
      (nicht die WIFFI-Firmwareversion).</li>
  <li><code>LAST_TELEGRAM</code>: lokale Empfangszeit des letzten
      g&uuml;ltigen, dekodierten und identit&auml;tsgepr&uuml;ften WIFFI-Telegramms,
      auch eines unbekannten oder deaktivierten logischen Ger&auml;ts.
      Kein Reading und kein Event.</li>
  <li><code>FRAMES_OK</code>, <code>FRAMES_ERROR</code>,
      <code>FRAMES_UNKNOWN</code>, <code>AUTOCREATED</code>:
      angenommene, abgewiesene und nicht zugeordnete Telegramme
      sowie automatisch angelegte Ger&auml;te.</li>
  <li><code>LISTENER_STATUS</code> (<code>listening</code>,
      <code>stopped</code> oder <code>error</code>),
      <code>LISTENER_ERROR</code>, <code>TCP_PORT</code>:
      Listener-Zustand und Fehler beim &Ouml;ffnen oder Bereinigen.</li>
  <li><code>CLIENTS_ACTIVE</code>, <code>CLIENTS_PEAK</code>,
      <code>CLIENTS_REJECTED</code>, <code>CLIENTS_TIMEOUT</code>,
      <code>MAX_CLIENTS</code>, <code>CLIENT_IDLE_TIMEOUT</code>,
      <code>CLIENT_MAX_LIFETIME</code>, <code>MAX_FRAME</code>:
      Verbindungs- und Gr&ouml;&szlig;enbegrenzungen. Keine Readings.</li>
</ul>

=end html_DE

=for :application/json;q=META.json 00_WIFFI_Collector.pm
{
  "name": "FHEM-WIFFI-Collector",
  "abstract": "Shared TCP collector for classic WIFFI telemetry",
  "version": "v0.1.0",
  "author": ["Flachzange"],
  "license": ["open_source"],
  "release_status": "testing"
}
=end :application/json;q=META.json

=cut
