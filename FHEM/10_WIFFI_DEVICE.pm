# SPDX-License-Identifier: GPL-2.0-or-later
# Logical FHEM device for one WIFFI sensor
package main;
use strict;
use warnings;
use HttpUtils;
use vars qw(%defs $readingFnAttributes);

sub WIFFI_DEVICE_Initialize {
  my ($hash) = @_;
  $hash->{DefFn} = 'WIFFI_DEVICE_Define';
  $hash->{UndefFn} = 'WIFFI_DEVICE_Undef';
  $hash->{SetFn} = 'WIFFI_DEVICE_Set';
  $hash->{AttrList} = 'stripReadingPrefix:0,1 '.$readingFnAttributes;
}

sub WIFFI_DEVICE_Define {
  my ($hash, $def) = @_;
  my ($name, $type, $collector, $mac) = split /\s+/, $def;
  return 'Usage: define <name> WIFFI_DEVICE <collector-name> <mac-address>'
    unless defined $collector && defined $mac;
  # A WIFFI_DEVICE may be restored before the collector. Load its shared
  # parser without creating a listener or requiring a defined collector.
  if (!defined &WIFFI_Collector_NormalizeMac) {
    my $loaded = LoadModule('WIFFI_Collector');
    return 'Cannot load WIFFI_Collector'
      if !defined $loaded || $loaded eq 'UNDEFINED'
        || !defined &WIFFI_Collector_NormalizeMac;
  }
  my $normalized = WIFFI_Collector_NormalizeMac($mac);
  return 'Invalid WIFFI MAC address' unless $normalized;
  # A successful modify invalidates any in-flight frame targeting the
  # previous definition; plain rename keeps the same definition generation.
  ++$hash->{'.WIFFI_DEFINITION_GEN'} if exists $hash->{OLDDEF};
  $hash->{COLLECTOR} = $collector;
  $hash->{MAC} = $normalized;
  # Explicit `modify` acknowledges that the device's TCP peer can change.
  if (exists $hash->{OLDDEF}) {
    # A modify invalidates any control request using the previous identity/IP.
    my $pending = delete $hash->{'.WIFFI_HTTP'};
    HttpUtils_Close($pending) if $pending;
    delete $hash->{PEER};
    delete $hash->{MODULTYP};
  }
  readingsSingleUpdate($hash, 'state', 'waiting', 0);
  return undef;
}

sub WIFFI_DEVICE_Undef {
  my ($hash) = @_;
  my $pending = delete $hash->{'.WIFFI_HTTP'};
  HttpUtils_Close($pending) if $pending;
  return undef;
}

# Every WIFFI supports an explicit relative HTTP GET path. The documented
# pump shortcuts are intentionally available only for type wiffi-pump.
# HTTP responses never change the authoritative telemetry-driven readings.
sub WIFFI_DEVICE_Set {
  my ($hash, $name, $cmd, @args) = @_;
  my $pump = ($hash->{MODULTYP} // '') eq 'wiffi-pump';
  my $choices = $pump ? 'on off on-for-timer httpGet' : 'httpGet';
  return "Unknown argument ".($cmd // '').", choose one of $choices"
    unless defined $cmd && ($cmd eq 'httpGet'
      || ($pump && $cmd =~ /\A(?:on|off|on-for-timer)\z/));

  my $path;
  if ($cmd eq 'httpGet') {
    # Relative path and query only: no host, port, scheme, fragments,
    # control characters, whitespace, or malformed percent escapes.
    return 'Usage: set <device> httpGet </path[?query]>'
      unless @args == 1
        && length($args[0]) <= 2048
        && $args[0] =~ m{\A/(?!/)[A-Za-z0-9._~%!\$&'()*+,;=:@/?-]*\z}
        && $args[0] !~ /%(?![0-9A-Fa-f]{2})/;
    $path = $args[0];
  } elsif ($cmd eq 'on-for-timer') {
    return 'Usage: set <device> on-for-timer <seconds (1..3600)>'
      unless @args == 1 && $args[0] =~ /\A[1-9][0-9]{0,3}\z/
        && $args[0] <= 3600;
    $path = "/?trigger:$args[0]:";
  } else {
    return "Usage: set <device> $cmd" if @args;
    $path = "/?trigger:$cmd:";
  }

  my $collector = $defs{$hash->{COLLECTOR}};
  return 'WIFFI collector is not defined'
    unless $collector && $collector->{TYPE} eq 'WIFFI_Collector';
  return 'WIFFI command already pending' if $hash->{'.WIFFI_HTTP'};

  # Only target the observed TCP peer, never an untrusted JSON reading.
  # Require a unicast IPv4 address to avoid HTTP URL/host injection.
  my $peer = $hash->{PEER} // '';
  my @octets = split /\./, $peer, -1;
  return 'No valid WIFFI TCP peer yet; wait for a fresh telegram'
    unless @octets == 4
      && !(grep { $_ !~ /\A[0-9]{1,3}\z/ || $_ > 255 } @octets)
      && $octets[0] >= 1 && $octets[0] <= 223
      && $octets[0] != 127;

  my $param = {
    url      => "http://$peer$path",
    method   => 'GET',
    timeout  => 5,
    ignoreredirects => 1,
    hash     => $hash,
    command  => $cmd,
    callback => \&WIFFI_DEVICE_HttpDone,
  };
  $hash->{'.WIFFI_HTTP'} = $param;
  my $ok = eval { HttpUtils_NonblockingGet($param); 1 };
  if (!$ok) {
    delete $hash->{'.WIFFI_HTTP'}
      if $hash->{'.WIFFI_HTTP'} && $hash->{'.WIFFI_HTTP'} == $param;
    my $error = $@ || 'unknown HTTP client error';
    Log3($hash, 2, "$name: unable to initiate WIFFI $cmd: $error");
    return "Failed to send WIFFI command";
  }
  return undef; # HTTP is asynchronous; no optimistic pump state update.
}

sub WIFFI_DEVICE_HttpDone {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  return unless $hash && $hash->{'.WIFFI_HTTP'}
    && $hash->{'.WIFFI_HTTP'} == $param;
  delete $hash->{'.WIFFI_HTTP'};

  # A renamed/deleted device must not be updated using a stale callback.
  return unless $defs{$hash->{NAME}} && $defs{$hash->{NAME}} == $hash;
  my $code = $param->{code};
  if ($err || (defined $code && $code !~ /\A2[0-9]{2}\z/)) {
    my $failure = $err || "HTTP status $code";
    Log3($hash, 2, "$hash->{NAME}: WIFFI $param->{command} failed: $failure");
  }
}

sub WIFFI_DEVICE_Process {
  my ($hash, $data, $peer) = @_;

  # Optional, per-device naming convention. Validate the full mapping before
  # publishing anything: both "w_foo" and "foo" may exist in one telegram.
  my $strip = AttrVal($hash->{NAME}, 'stripReadingPrefix', 0) eq '1';
  my %mapped;
  for my $reading (keys %{$data->{readings}}) {
    my $name = $reading;
    $name =~ s/\Aw_// if $strip;
    if ($name eq '' || $name eq 'state' || exists $mapped{$name}) {
      Log3($hash, 2, "$hash->{NAME}: WIFFI reading name collision or reserved name: $reading -> $name");
      return 0;
    }
    $mapped{$name} = $data->{readings}{$reading};
  }

  # The latest valid telegram determines which type-specific commands exist.
  # A changed type is diagnostic information, not a malformed frame.
  if (defined $hash->{MODULTYP} && $hash->{MODULTYP} ne $data->{modultyp}) {
    my ($old, $new) = ($hash->{MODULTYP}, $data->{modultyp});
    for ($old, $new) {
      s/[\x00-\x1F\x7F]/ /g;
      $_ = substr($_, 0, 100);
    }
    Log3($hash, 3, "$hash->{NAME}: WIFFI modultyp changed: $old -> $new");
  }
  $hash->{PEER} = $peer;
  $hash->{MODULTYP} = $data->{modultyp};
  readingsBeginUpdate($hash);
  for my $reading (sort keys %mapped) {
    readingsBulkUpdate($hash, $reading, $mapped{$reading});
  }
  readingsBulkUpdate($hash, 'state', 'online');
  readingsEndUpdate($hash, 1);
  return 1;
}
1;
