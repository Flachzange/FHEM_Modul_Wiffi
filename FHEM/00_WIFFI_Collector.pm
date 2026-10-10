# SPDX-License-Identifier: GPL-2.0-only
# Nonblocking shared TCP collector for STALL WIFFI JSON
package main;
use strict;
use warnings;
use Errno qw(EAGAIN EWOULDBLOCK);
use TcpServerUtils;
use WIFFI::Parser;
use vars qw(%defs $init_done $readingFnAttributes);

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
  for my $frame (WIFFI::Parser::extract_frames(\$hash->{BUF})) {
    WIFFI_Collector_ProcessFrame($server, $frame, $hash->{PEER});
  }
}

sub WIFFI_Collector_ProcessFrame {
  my ($server, $raw, $peer) = @_;
  my $packet = eval { WIFFI::Parser::decode($raw) };
  if (!$packet) {
    $server->{FRAMES_ERROR}++;
    my $error = $@ || 'unknown JSON error';
    chomp $error;
    Log3($server, 2, "$server->{NAME}: invalid WIFFI from $peer: $error");
    return;
  }

  my $device;
  for my $hash (values %defs) {
    next unless $hash->{TYPE} eq 'WIFFI_DEVICE';
    next unless ($hash->{COLLECTOR} // '') eq $server->{NAME};
    next unless ($hash->{MAC} // '') eq $packet->{mac};
    $device = $hash;
    last;
  }

  if (!$device && AttrVal($server->{NAME}, 'autocreate', 0)) {
    my $type = uc $packet->{modultyp};
    $type =~ s/[^A-Z0-9_]/_/g;
    my $shortmac = $packet->{mac};
    $shortmac =~ s/://g;
    my $name = 'WIFFI_' . $type . '_' . substr($shortmac, -6);
    if ($defs{$name}) {
      Log3($server, 2, "$server->{NAME}: name conflict: $name");
    } else {
      my $error = CommandDefine(undef,
        "$name WIFFI_DEVICE $server->{NAME} $packet->{mac}");
      Log3($server, 2, "$server->{NAME}: autocreate failed: $error")
        if defined $error && length $error;
      $device = $defs{$name} unless $error;
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
  if ($device->{PEER} && $device->{PEER} ne $peer) {
    Log3($server, 3, "$server->{NAME}: $packet->{mac} moved from ".
      "$device->{PEER} to $peer");
  }
  WIFFI_DEVICE_Process($device, $packet, $peer);
  $server->{FRAMES_OK}++;
}
1;
