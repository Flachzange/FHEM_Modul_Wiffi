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

sub WIFFI_Collector_Decode {
  my ($raw) = @_;
  die "empty WIFFI telegram" unless defined $raw && length $raw;
  my $obj = JSON::PP->new->utf8->allow_bignum->decode($raw);
  die "expected JSON object" unless ref($obj) eq 'HASH';
  die "missing vars array" unless ref($obj->{vars}) eq 'ARRAY';
  die "missing Systeminfo" unless ref($obj->{Systeminfo}) eq 'HASH';
  die "missing modultyp" unless defined $obj->{modultyp} && $obj->{modultyp} ne '';

  my $mac = WIFFI_Collector_NormalizeMac($obj->{Systeminfo}{'MAC-Adresse'});
  die "missing or invalid MAC-Adresse" unless defined $mac;

  my %readings;
  my $reported_ip;
  for my $var (@{$obj->{vars}}) {
    next unless ref($var) eq 'HASH';
    my $name = $var->{homematic_name};
    next unless defined $name && $name =~ /\A[A-Za-z_][A-Za-z0-9_.-]*\z/;
    next unless exists $var->{value} && defined $var->{value};
    die "duplicate CCU name $name" if exists $readings{$name};
    my $value = $var->{value};
    die "unsupported value type for $name"
      if ref($value) && ref($value) !~ /\A(?:JSON::PP::Boolean|Math::BigInt|Math::BigFloat)\z/;
    $readings{$name} =
      ref($value) eq 'JSON::PP::Boolean' ? ($value ? 'true' : 'false') : "$value";
    $reported_ip = "$value" if defined $var->{name} && $var->{name} eq '0';
  }

  for my $key (keys %{$obj->{Systeminfo}}) {
    next unless $key =~ /\A[A-Za-z_][A-Za-z0-9_.-]*\z/;
    my $value = $obj->{Systeminfo}{$key};
    next unless defined $value && !ref($value);
    $readings{"Systeminfo_$key"} = "$value";
  }

  return {
    mac         => $mac,
    modultyp    => "$obj->{modultyp}",
    reported_ip => $reported_ip,
    readings    => \%readings,
  };
}

sub WIFFI_Collector_ExtractFrames {
  my ($buffer_ref) = @_;
  my @frames;
  while ($$buffer_ref =~ /[\x03\x04]/) {
    my $pos = $-[0];
    my $frame = substr($$buffer_ref, 0, $pos, '');
    substr($$buffer_ref, 0, 1, '');
    $frame =~ s/\A\s+|\s+\z//g;
    push @frames, $frame if length $frame;
  }
  return @frames;
}

sub WIFFI_Collector_Initialize {
  my ($hash) = @_;
  $hash->{DefFn} = 'WIFFI_Collector_Define';
  $hash->{UndefFn} = 'WIFFI_Collector_Undef';
  $hash->{ReadFn} = 'WIFFI_Collector_Read';
  $hash->{AttrList} = 'autocreate:0,1 allowfrom '.$readingFnAttributes;
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

sub WIFFI_Collector_Undef {
  my ($hash) = @_;
  RemoveInternalTimer($hash);
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
    $client->{CD}->blocking(0) if $client;
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
    $tail =~ s/\A\s+|\s+\z//g;
    WIFFI_Collector_ProcessFrame($server, $tail, $hash->{PEER})
      if length $tail;
    CommandDelete(undef, $hash->{NAME});
    return;
  }

  $hash->{BUF} .= $chunk;
  if (length($hash->{BUF}) > $server->{MAX_FRAME}) {
    $server->{FRAMES_ERROR}++;
    Log3($server, 2, "$hash->{NAME}: oversized or unterminated telegram");
    CommandDelete(undef, $hash->{NAME});
    return;
  }
  for my $frame (WIFFI_Collector_ExtractFrames(\$hash->{BUF})) {
    WIFFI_Collector_ProcessFrame($server, $frame, $hash->{PEER});
  }
}

sub WIFFI_Collector_ProcessFrame {
  my ($server, $raw, $peer) = @_;
  my $packet = eval { WIFFI_Collector_Decode($raw) };
  if (!$packet) {
    $server->{FRAMES_ERROR}++;
    my $error = $@ || 'unknown JSON error';
    chomp $error;
    Log3($server, 2, "$server->{NAME}: invalid WIFFI from $peer: $error");
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
    Log3($server, 2, "$server->{NAME}: WIFFI identity conflict from $peer");
    return;
  }
  my $device = $matches[0];
  if ($device && defined $device->{PEER} && $device->{PEER} ne $peer) {
    $server->{FRAMES_ERROR}++;
    Log3($server, 2, "$server->{NAME}: WIFFI MAC changed sender IP: ".
      "$device->{NAME} ($device->{PEER} -> $peer); check device identity");
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
          my @defaults = (['room', 'WIFFI']);
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
  WIFFI_DEVICE_Process($device, $packet, $peer);
  $server->{FRAMES_OK}++;
}
1;
