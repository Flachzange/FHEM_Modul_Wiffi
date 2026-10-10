# SPDX-License-Identifier: GPL-2.0-or-later
package WIFFI::Parser;

use strict;
use warnings;
use JSON::PP ();

sub normalize_mac {
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

sub decode {
  my ($raw) = @_;
  die "empty WIFFI telegram" unless defined $raw && length $raw;
  my $obj = JSON::PP->new->utf8->allow_bignum->decode($raw);
  die "expected JSON object" unless ref($obj) eq 'HASH';
  die "missing vars array" unless ref($obj->{vars}) eq 'ARRAY';
  die "missing Systeminfo" unless ref($obj->{Systeminfo}) eq 'HASH';
  die "missing modultyp" unless defined $obj->{modultyp} && $obj->{modultyp} ne '';

  my $mac = normalize_mac($obj->{Systeminfo}{'MAC-Adresse'});
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

sub extract_frames {
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

1;
