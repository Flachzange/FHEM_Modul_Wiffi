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
  $hash->{AttrFn} = 'WIFFI_DEVICE_Attr';
  $hash->{AttrList} = 'stripReadingPrefix:0,1 disable:0,1 '.$readingFnAttributes;
}

sub WIFFI_DEVICE_Attr {
  my ($cmd, $name, $attr_name, $value) = @_;
  return undef unless $attr_name eq 'disable' && $cmd eq 'set';
  return 'Usage: attr <device> disable 0|1'
    unless defined $value && $value =~ /\A[01]\z/;
  if ($value eq '1') {
    my $hash = $defs{$name};
    if ($hash) {
      my $pending = delete $hash->{'.WIFFI_HTTP'};
      HttpUtils_Close($pending) if $pending;
    }
  }
  return undef;
}

sub WIFFI_DEVICE_Define {
  my ($hash, $def) = @_;
  my @parts = split /\s+/, $def;
  my ($name, $type, $collector, $mac) = @parts;
  return 'Usage: define <name> WIFFI_DEVICE <collector-name> <mac-address>'
    unless @parts == 4;
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
  my $pulse = ($hash->{MODULTYP} // '') eq 'PULSECOUNTER';
  my $choices = $pump ? 'on off on-for-timer httpGet'
    : $pulse ? 'counter httpGet'
    : 'httpGet';
  return "Unknown argument ".($cmd // '').", choose one of $choices"
    unless defined $cmd && ($cmd eq 'httpGet'
      || ($pump && $cmd =~ /\A(?:on|off|on-for-timer)\z/)
      || ($pulse && $cmd eq 'counter'));
  return 'WIFFI device is disabled' if AttrVal($name, 'disable', 0) eq '1';

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
  } elsif ($cmd eq 'counter') {
    return 'Usage: set <device> counter <channel (1..4)> <value (0..999999)>'
      unless @args == 2
        && $args[0] =~ /\A[1-4]\z/
        && length($args[1]) <= 32
        && $args[1] =~ /\A(?:0|[1-9][0-9]{0,5})(?:\.[0-9]+)?\z/
        && $args[1] <= 999999;
    $path = "/?counter:$args[0]:$args[1]:";
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
  # FHEM DoSet otherwise emits a synthetic on/off/httpGet event even though
  # no WIFFI telemetry confirmed a physical state change.
  # Suppress that event in DoSet's list context; retain scalar error contract.
  return wantarray ? (undef, 1) : undef;
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
=pod
=item device
=item summary Logical receiver and HTTP controller for one WIFFI device
=item summary_DE Logisches Ger&auml;t f&uuml;r WIFFI-Messwerte und HTTP-Steuerung

=begin html

<a id="WIFFI_DEVICE"></a>
<h3>WIFFI_DEVICE</h3>
<p>
  Represents one STALL WIFFI device attached to a
  <code>WIFFI_Collector</code>. Valid TCP telegrams update the sensor
  readings. The default names match <code>vars[].homematic_name</code>
  from WIFFI JSON, including the <code>w_</code> prefix where present.
  <code>Systeminfo</code> fields use the <code>Systeminfo_</code> prefix.
</p>
<a id="WIFFI_DEVICE-define"></a>
<h4>Define</h4>
<ul>
  <li><code>define &lt;name&gt; WIFFI_DEVICE &lt;collector-name&gt; &lt;MAC-address&gt;</code><br>
      Define a logical WIFFI sender by its collector and MAC address.
      The MAC address may use six hexadecimal octets with colons or
      exactly 12 hexadecimal digits without separators (case-insensitive).
      Both are stored in uppercase colon-separated form.
      Examples (alternatives):
      <code>define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector 02:00:00:00:00:01</code>
      or <code>define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector 020000000001</code>.
      The collector can also create logical devices automatically when
      its <code>autocreate</code> attribute is enabled.</li>
</ul>
<a id="WIFFI_DEVICE-set"></a>
<h4>Set</h4>
<ul>
  <li><a id="WIFFI_DEVICE-set-on"></a><b>on</b> (type <code>wiffi-pump</code> only)<br>
      Switch the pump on until turned off, using
      <code>/?trigger:on:</code>.</li>
  <li><a id="WIFFI_DEVICE-set-off"></a><b>off</b> (type <code>wiffi-pump</code> only)<br>
      Switch the pump off using <code>/?trigger:off:</code>.</li>
  <li><a id="WIFFI_DEVICE-set-on-for-timer"></a><b>on-for-timer</b> &lt;seconds&gt;
      (type <code>wiffi-pump</code> only)<br>
      Switch on for 1 to 3600 seconds using
      <code>/?trigger:&lt;seconds&gt;:</code>. Example:
      <code>set WIFFI_PUMP2 on-for-timer 30</code>.</li>
  <li><a id="WIFFI_DEVICE-set-counter"></a><b>counter</b> &lt;channel&gt; &lt;value&gt;
      (type <code>PULSECOUNTER</code> only)<br>
      Set counter channel 1 to 4 with the documented
      <code>/?counter:&lt;channel&gt;:&lt;value&gt;:</code> command.
      Values use a dot as decimal separator and must be between 0 and
      999999. Example:
      <code>set WIFFI_PULSECOUNTER_Water counter 2 143.550</code>.
      The HTTP response is not confirmation of the stored value:
      subsequent device telemetry is authoritative. With standard
      reading names the result is visible in <code>w_counter1</code>
      through <code>w_counter4</code> (or without <code>w_</code> when
      <code>stripReadingPrefix 1</code> is active). Firmware may quantize
      the value according to its configured counter resolution.</li>
  <li><a id="WIFFI_DEVICE-set-httpGet"></a><b>httpGet</b> &lt;relative-path&gt;<br>
      Send a GET request to an explicit relative HTTP path/query on the
      WIFFI device. Available for all WIFFI types. Example:
      <code>set WIFFI_PUMP2 httpGet /?param:0:240:</code>.
      This is an expert control command, <b>not read-only</b>:
      depending on firmware it can change configuration or trigger
      device operations. Absolute URLs, foreign hosts, fragments and
      malformed paths are refused.</li>
</ul>
<p>
  HTTP commands use the verified IPv4 address of the last accepted
  TCP sender, on port 80, with a five-second timeout, no redirects
  and at most one concurrent request per logical device. A successful
  HTTP reply does not update pump feedback or other readings;
  only later received telemetry does. Successful asynchronous HTTP
  commands do not generate a synthetic FHEM set-command event.
  Type-specific shortcuts are available according to the latest valid
  <code>modultyp</code>: pump controls for <code>wiffi-pump</code> and
  <code>counter</code> for <code>PULSECOUNTER</code>. A changed type can
  add or remove these shortcuts.
</p>
<a id="WIFFI_DEVICE-attr"></a>
<h4>Attributes</h4>
<ul>
  <li><a id="WIFFI_DEVICE-attr-stripReadingPrefix"></a><b>stripReadingPrefix</b> (0,1; default 0)<br>
      When 1, remove one leading <code>w_</code> from each
      <code>homematic_name</code> sensor reading. Other reading names
      are unchanged. The default preserves the original CCU names.
      Avoid collisions if both prefixed and unprefixed names occur.</li>
  <li><a id="WIFFI_DEVICE-attr-disable"></a><b>disable</b> (0,1; default 0)<br>
      When 1, ignore incoming telemetry and do not update this
      device's readings, state, module type or heartbeat. Other
      WIFFI devices continue to update. Block all HTTP Set commands
      and cancel a pending HTTP request. The previous readings and
      device definition remain. Use <code>disable 0</code> or
      <code>deleteattr &lt;name&gt; disable</code> to re-enable.</li>
</ul>
<a id="WIFFI_DEVICE-readings"></a>
<h4>Readings and display</h4>
<ul>
  <li>Sensor readings use the sender's <code>homematic_name</code>;
      <code>Systeminfo_sec_seit_reset</code> is available as a heartbeat.
      A valid telegram updates <code>state</code> to <code>online</code>.</li>
  <li>On initial autocreate the collector configures
      <code>event-on-change-reading</code>,
      <code>event-on-update-reading</code> for the heartbeat, and
      <code>DbLogExclude</code> for the uptime counter. Newly discovered
      pumps also receive <code>stateFormat wiffi_pump</code> and
      <code>devStateIcon true:on false:off</code>. These are ordinary
      user-editable FHEM attributes, not immutable module settings.</li>
</ul>

=end html

=begin html_DE

<a id="WIFFI_DEVICE"></a>
<h3>WIFFI_DEVICE</h3>
<p>
  Repr&auml;sentiert ein STALL-WIFFI-Ger&auml;t an einem
  <code>WIFFI_Collector</code>. G&uuml;ltige TCP-Telegramme
  aktualisieren die Messwert-Readings. Die Namen entsprechen
  standardm&auml;&szlig;ig exakt dem JSON-Feld
  <code>vars[].homematic_name</code>, einschlie&szlig;lich eines
  vorhandenen <code>w_</code>-Pr&auml;fixes.
  Systeminformationen verwenden das Pr&auml;fix <code>Systeminfo_</code>.
</p>
<a id="WIFFI_DEVICE-define"></a>
<h4>Define</h4>
<ul>
  <li><code>define &lt;name&gt; WIFFI_DEVICE &lt;collector-name&gt; &lt;MAC-Adresse&gt;</code><br>
      Erstellt ein logisches Ger&auml;t mit Collector und MAC-Adresse.
      Die MAC-Adresse kann aus sechs Hex-Oktetten mit Doppelpunkten
      oder aus genau zw&ouml;lf Hex-Zeichen ohne Trennzeichen bestehen
      (Gro&szlig;-/Kleinschreibung beliebig). Intern wird immer die
      gro&szlig;geschriebene Form mit Doppelpunkten verwendet.
      Beispiele (Alternativen):
      <code>define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector 02:00:00:00:00:01</code>
      oder <code>define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector 020000000001</code>.
      Bei aktiviertem <code>autocreate</code> kann der Collector
      neue Ger&auml;te auch selbst anlegen.</li>
</ul>
<a id="WIFFI_DEVICE-set"></a>
<h4>Set</h4>
<ul>
  <li><a id="WIFFI_DEVICE-set-on"></a><b>on</b> (nur <code>wiffi-pump</code>)<br>
      Schaltet die Pumpe mit <code>/?trigger:on:</code> dauerhaft ein,
      bis ein Ausschaltbefehl folgt.</li>
  <li><a id="WIFFI_DEVICE-set-off"></a><b>off</b> (nur <code>wiffi-pump</code>)<br>
      Schaltet die Pumpe mit <code>/?trigger:off:</code> aus.</li>
  <li><a id="WIFFI_DEVICE-set-on-for-timer"></a><b>on-for-timer</b> &lt;Sekunden&gt;
      (nur <code>wiffi-pump</code>)<br>
      Schaltet die Pumpe f&uuml;r 1 bis 3600 Sekunden mit
      <code>/?trigger:&lt;Sekunden&gt;:</code> ein. Beispiel:
      <code>set WIFFI_PUMP2 on-for-timer 30</code>.</li>
  <li><a id="WIFFI_DEVICE-set-counter"></a><b>counter</b> &lt;Kanal&gt; &lt;Wert&gt;
      (nur <code>PULSECOUNTER</code>)<br>
      Setzt Z&auml;hlerkanal 1 bis 4 mit dem dokumentierten Befehl
      <code>/?counter:&lt;Kanal&gt;:&lt;Wert&gt;:</code>.
      Dezimalwerte verwenden einen Punkt und m&uuml;ssen zwischen 0 und
      999999 liegen. Beispiel:
      <code>set WIFFI_PULSECOUNTER_Wasser counter 2 143.550</code>.
      Die HTTP-Antwort best&auml;tigt den gespeicherten Wert nicht:
      ma&szlig;geblich ist erst die folgende Ger&auml;tetelemetrie. Bei
      Standardnamen ist das Ergebnis in <code>w_counter1</code> bis
      <code>w_counter4</code> sichtbar (bzw. ohne <code>w_</code> bei
      <code>stripReadingPrefix 1</code>). Die Firmware kann den Wert
      entsprechend der konfigurierten Z&auml;hleraufl&ouml;sung quantisieren.</li>
  <li><a id="WIFFI_DEVICE-set-httpGet"></a><b>httpGet</b> &lt;relativer-Pfad&gt;<br>
      Sendet einen GET-Aufruf mit explizitem relativen HTTP-Pfad und
      optionaler Query an das WIFFI-Ger&auml;t. F&uuml;r alle
      WIFFI-Typen verf&uuml;gbar. Beispiel:
      <code>set WIFFI_PUMP2 httpGet /?param:0:240:</code>.
      Dies ist ein Expertenbefehl zur Steuerung, <b>kein
      reiner Lesezugriff</b>. Je nach Firmware k&ouml;nnen dadurch
      Parameter ver&auml;ndert oder Ger&auml;teaktionen ausgel&ouml;st
      werden. Absolute URLs, fremde Hosts, Fragmente und
      ung&uuml;ltige Pfade werden abgewiesen.</li>
</ul>
<p>
  HTTP-Befehle gehen an die zuletzt aus einem g&uuml;ltigen
  TCP-Telegramm ermittelte IPv4-Absenderadresse, Port 80.
  Das Timeout betr&auml;gt f&uuml;nf Sekunden; Weiterleitungen und
  parallele Anfragen an dasselbe logische Ger&auml;t sind gesperrt.
  Eine erfolgreiche HTTP-Antwort &auml;ndert keine Pumpen- oder
  Messwert-Readings. Daf&uuml;r ist neue TCP-Telemetrie erforderlich.
  Erfolgreich gestartete HTTP-Befehle erzeugen auch kein zus&auml;tzliches
  k&uuml;nstliches FHEM-Set-Event.
  Die angebotenen typabh&auml;ngigen Befehle richten sich nach dem zuletzt
  g&uuml;ltigen <code>modultyp</code>: Pumpenbefehle f&uuml;r
  <code>wiffi-pump</code> und <code>counter</code> f&uuml;r
  <code>PULSECOUNTER</code>. Sie passen sich bei einem Typwechsel an.
</p>
<a id="WIFFI_DEVICE-attr"></a>
<h4>Attribute</h4>
<ul>
  <li><a id="WIFFI_DEVICE-attr-stripReadingPrefix"></a><b>stripReadingPrefix</b> (0,1; Standard 0)<br>
      Entfernt bei 1 genau ein f&uuml;hrendes <code>w_</code>
      aus jedem Sensor-Reading-Namen (<code>homematic_name</code>).
      Andere Readings bleiben unver&auml;ndert. Standardm&auml;&szlig;ig
      bleiben die originalen CCU-Namen erhalten. M&ouml;gliche
      Namenskollisionen beachten.</li>
  <li><a id="WIFFI_DEVICE-attr-disable"></a><b>disable</b> (0,1; Standard 0)<br>
      Mit 1 werden eingehende Telegramme f&uuml;r dieses Ger&auml;t
      ignoriert: Messwerte, <code>state</code>, Typ und Heartbeat
      bleiben unver&auml;ndert. Andere WIFFI-Ger&auml;te arbeiten
      weiter. Alle HTTP-Set-Befehle werden gesperrt; laufende
      HTTP-Anfragen werden abgebrochen. Definition und bisherige
      Readings bleiben erhalten. Reaktivierung mit
      <code>disable 0</code> oder
      <code>deleteattr &lt;name&gt; disable</code>.</li>
</ul>
<a id="WIFFI_DEVICE-readings"></a>
<h4>Readings und Anzeige</h4>
<ul>
  <li>Sensor-Readings stammen aus <code>homematic_name</code>;
      <code>Systeminfo_sec_seit_reset</code> kann als Lebenszeichen
      verwendet werden. Ein g&uuml;ltiges Telegramm setzt
      <code>state</code> auf <code>online</code>.</li>
  <li>Beim erstmaligen Autocreate setzt der Collector
      <code>event-on-change-reading</code>,
      <code>event-on-update-reading</code> f&uuml;r das Lebenszeichen
      und <code>DbLogExclude</code> f&uuml;r den Uptime-Z&auml;hler.
      Neue Pumpenger&auml;te erhalten zus&auml;tzlich
      <code>stateFormat wiffi_pump</code> und
      <code>devStateIcon true:on false:off</code>.
      Das sind normale, vom Benutzer &auml;nderbare FHEM-Attribute.</li>
</ul>

=end html_DE

=cut
