# SPDX-License-Identifier: GPL-2.0-or-later
# Nonblocking shared TCP collector for STALL WIFFI JSON
package main;
use strict;
use warnings;
use Errno qw(EAGAIN EWOULDBLOCK);
use TcpServerUtils;
use JSON::PP ();
use vars qw(%defs $init_done $readingFnAttributes);

# Parser helpers live here so an installed FHEM module needs no additional .pm file.
sub WIFFI_Collector_NormalizeMac {
  my ($mac) = @_;
  return undef unless defined $mac;
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
  $hash->{AttrList} = 'autocreate:0,1 logRejectedPayload:0,1 allowfrom '.$readingFnAttributes;
}

sub WIFFI_Collector_Define {
  my ($hash, $def) = @_;
  my ($name, $type, $port) = split /\s+/, $def;
  return 'Usage: define <name> WIFFI_Collector <tcp-port>'
    unless defined $port && $port =~ /\A[0-9]{1,5}\z/
      && $port >= 1 && $port <= 65535;

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
  $hash->{MAX_CLIENTS} = 16;
  $hash->{CLIENT_IDLE_TIMEOUT} = 60;
  $hash->{CLIENT_MAX_LIFETIME} = 180;

  if ($init_done) {
    return TcpServer_Open($hash, $port, 'global');
  }
  InternalTimer(0, sub {
    return unless $defs{$name} && $defs{$name} == $hash;
    my $err = TcpServer_Open($hash, $port, 'global');
    Log3($hash, 1, $err) if $err;
  }, $hash, 0);
  return undef;
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
    ++$server->{FRAMES_ERROR};
    WIFFI_Collector_LogRejected($server, $client->{PEER},
      $now >= $life_deadline ? 'TCP client lifetime exceeded'
                            : 'TCP client idle timeout',
      $client->{BUF});
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
  for my $name (keys %defs) {
    my $client = $defs{$name};
    next unless $client->{TYPE} eq 'WIFFI_Collector'
      && defined $client->{SNAME} && $client->{SNAME} eq $hash->{NAME};
    CommandDelete(undef, $name);
  }
  return TcpServer_Close($hash);
}

sub WIFFI_Collector_Read {
  my ($hash) = @_;
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
  unless ($server) {
    CommandDelete(undef, $hash->{NAME});
    return;
  }
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
    WIFFI_Collector_ProcessFrame($server, $tail, $hash->{PEER})
      if $tail =~ /\S/;
    CommandDelete(undef, $hash->{NAME});
    return;
  }

  $hash->{'.WIFFI_LAST_ACTIVITY'} = Time::HiRes::time();
  $hash->{BUF} .= $chunk;
  my $max_frame = $server->{MAX_FRAME} // 262144;
  # First extract ALL complete frames. Their combined size is not limited by
  # MAX_FRAME; only an individual complete frame or the unfinished tail is.
  for my $frame (WIFFI_Collector_ExtractFrames(\$hash->{BUF})) {
    if (length($frame) > $max_frame) {
      ++$server->{FRAMES_ERROR};
      WIFFI_Collector_LogRejected($server, $hash->{PEER},
        "oversized WIFFI frame (".length($frame)." bytes, max $max_frame)",
        $frame);
      next;
    }
    WIFFI_Collector_ProcessFrame($server, $frame, $hash->{PEER});
  }
  if (length($hash->{BUF}) > $max_frame) {
    ++$server->{FRAMES_ERROR};
    WIFFI_Collector_LogRejected($server, $hash->{PEER},
      "oversized unfinished WIFFI frame (max $max_frame bytes)", $hash->{BUF});
    CommandDelete(undef, $hash->{NAME});
    return;
  }
}

sub WIFFI_Collector_ProcessFrame {
  my ($server, $raw, $peer) = @_;
  my $packet = eval { WIFFI_Collector_Decode($raw) };
  if (!$packet) {
    $server->{FRAMES_ERROR}++;
    my $error = $@ || 'unknown JSON error';
    chomp $error;
    WIFFI_Collector_LogRejected($server, $peer, $error, $raw);
    return;
  }

  # Match existing logical devices by the complete normalized MAC.  Never
  # silently adopt a device solely because its FHEM name or sender IP matches.
  my @matches;
  my $peer_conflict;
  for my $hash (values %defs) {
    next unless $hash->{TYPE} eq 'WIFFI_DEVICE';
    next unless ($hash->{COLLECTOR} // '') eq $server->{NAME};
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
    return;
  }
  my $device = $matches[0];
  if ($device && defined $device->{PEER} && $device->{PEER} ne $peer) {
    $server->{FRAMES_ERROR}++;
    WIFFI_Collector_LogRejected($server, $peer,
      "WIFFI MAC changed sender IP: ".
      "$device->{NAME} ($device->{PEER} -> $peer); check device identity", $raw);
    return;
  }

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
      if ($error) {
        Log3($server, 2, "$server->{NAME}: autocreate failed: $error");
      } else {
        # CommandDefine triggers DEFINED events. A user automation may have
        # renamed, changed or deleted the device while it was being created.
        my $created = $defs{$name};
        if ($created && $created->{TYPE} eq 'WIFFI_DEVICE'
            && ($created->{COLLECTOR} // '') eq $server->{NAME}
            && ($created->{MAC} // '') eq $packet->{mac}) {
          # Defaults apply only at creation, never to existing devices.
          # WIFFI-pump uses its real pump feedback for FHEMWEB status.
          # Do not override attributes set by a DEFINED event handler.
          my @defaults = (
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
            Log3($server, 2, "$server->{NAME}: default attr $key failed: $attr_error")
              if $attr_error;
            # ATTR notifications may remove or rename the new device.
            if (!$defs{$name} || $defs{$name} != $created) {
              $created = undef;
              last;
            }
          }
          if ($created) {
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
    return;
  }

  if ($packet->{reported_ip} && $peer ne $packet->{reported_ip}) {
    Log3($server, 3, "$server->{NAME}: reported IP $packet->{reported_ip} ".
      "differs from TCP peer $peer");
  }
  # WIFFI_DEVICE_Process stores the peer and module identity before
  # publishing readings, which may trigger reentrant FHEM callbacks.
  if (!WIFFI_DEVICE_Process($device, $packet, $peer)) {
    $server->{FRAMES_ERROR}++;
    WIFFI_Collector_LogRejected($server, $peer,
      "reading mapping rejected by $device->{NAME}", $raw);
    return;
  }
  $server->{FRAMES_OK}++;
}
1;
