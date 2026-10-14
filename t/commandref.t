# SPDX-License-Identifier: GPL-2.0-or-later
use strict;
use warnings;
use Test::More;

# Validate the FHEM commandref source structure and the HTML tag subset
# checked by FHEM's commandref_join.pl. This is not a live FHEM help test.
my %required = (
  'FHEM/00_WIFFI_Collector.pm' => [qw(
    WIFFI_Collector WIFFI_Collector-define WIFFI_Collector-set
    WIFFI_Collector-set-reopen WIFFI_Collector-attr
    WIFFI_Collector-attr-autocreate WIFFI_Collector-attr-disable
    WIFFI_Collector-attr-allowfrom WIFFI_Collector-attr-logRejectedPayload
  )],
  'FHEM/10_WIFFI_DEVICE.pm' => [qw(
    WIFFI_DEVICE WIFFI_DEVICE-define WIFFI_DEVICE-set
    WIFFI_DEVICE-set-on WIFFI_DEVICE-set-off
    WIFFI_DEVICE-set-on-for-timer WIFFI_DEVICE-set-httpGet
    WIFFI_DEVICE-attr WIFFI_DEVICE-attr-disable
    WIFFI_DEVICE-attr-stripReadingPrefix
  )],
);

for my $file (sort keys %required) {
  open my $fh, '<', $file or die "Cannot open $file: $!";
  local $/;
  my $code = <$fh>;
  close $fh;

  like($code, qr/\n1;\n=pod\n=item device\n/s,
    "$file commandref follows the Perl module return");
  like($code, qr/^=item summary \S/m, "$file English summary");
  like($code, qr/^=item summary_DE \S/m, "$file German summary");
  like($code, qr/\n=cut\s*\z/, "$file POD is closed");

  my @ids_by_lang;
  for my $language ('html', 'html_DE') {
    my $start = "=begin $language";
    my $end = "=end $language";
    my @blocks = ($code =~ /^\Q$start\E\n\n(.*?)^\Q$end\E\s*$/msg);
    is(scalar @blocks, 1, "$file $language has one correctly separated section");
    next unless @blocks == 1;
    my $html = $blocks[0];
    my @ids = ($html =~ /<a id="([^"]+)"><\/a>/g);
    push @ids_by_lang, \@ids;
    is(scalar @ids, scalar(keys %{ {map { $_ => 1 } @ids} }),
      "$file $language has no duplicate anchors");
    for my $id (@{$required{$file}}) {
      ok(grep({ $_ eq $id } @ids), "$file $language anchor $id");
    }
    for my $tag (qw(b code div h3 h4 i li p table td tr u ul)) {
      my $opens = () = $html =~ /<$tag(?:\s[^>]+)?>/gi;
      my $closes = () = $html =~ m{</$tag>}gi;
      is($opens, $closes, "$file $language balanced $tag");
      unlike($html, qr/<$tag\s[^>]+>/i,
        "$file $language no FHEM-disallowed attributes on $tag");
    }
    unlike($html, qr/\b(?:TODO|FIXME|test pending|not yet verified)\b/i,
      "$file $language contains user documentation only");
  }
  is_deeply($ids_by_lang[0], $ids_by_lang[1],
    "$file German and English command anchors agree") if @ids_by_lang == 2;
}
done_testing();
