# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;
use JSON::PP ();

# Source-level metadata/registration check; not a substitute for loading the
# modules in a real FHEM and observing FVERSION there.
my @files = ('FHEM/00_WIFFI_Collector.pm', 'FHEM/10_WIFFI_DEVICE.pm');
my @versions;
for my $file (@files) {
  open my $fh, '<', $file or die "$file: $!";
  local $/;
  my $code = <$fh>;
  close $fh;
  my ($basename) = $file =~ m{([^/]+)\z};
  my ($meta_json) = $code =~
    /^=for :application\/json;q=META\.json \Q$basename\E\n(.*?)^=end :application\/json;q=META\.json\s*$/msg;
  ok(defined $meta_json, "$file has its own embedded META.json");
  next unless defined $meta_json;
  my $meta = eval { JSON::PP::decode_json($meta_json) };
  ok($meta && ref($meta) eq 'HASH', "$file metadata is valid JSON");
  next unless $meta;
  like($meta->{version}, qr/^v\d+\.\d+\.\d+$/, "$file declares a semantic module version");
  push @versions, $meta->{version};
  like($code, qr/^use FHEM::Meta;$/m, "$file imports FHEM::Meta");
  like($code, qr/return FHEM::Meta::InitMod\(__FILE__, \$hash\);/,
    "$file Initialize loads embedded metadata");
  like($code, qr/return \$@ unless FHEM::Meta::SetInternals\(\$hash\);/,
    "$file Define requests FVERSION through FHEM::Meta");
  like($code, qr/\$hash->\{FVERSION\} \/\/= '\Q$basename\E:' \./,
    "$file has missing-x_version fallback for native FVERSION Internal");
  ok(!($code =~ /readings\w*Update\(\$hash,\s*['"](?:FVERSION|VERSION)['"]/),
    "$file does not create a module-version reading");
}
is(scalar @versions, 2, 'both FHEM modules have metadata');
is($versions[0], $versions[1], 'collector and device share one project release version');
done_testing();
