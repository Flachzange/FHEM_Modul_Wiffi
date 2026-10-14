# SPDX-License-Identifier: GPL-2.0-or-later
# Logical FHEM device for one WIFFI sensor
package main;
use strict;
use warnings;
use HttpUtils;
use FHEM::Meta;
use vars qw(%defs $init_done $readingFnAttributes);

sub WIFFI_DEVICE_Initialize {
  my ($hash) = @_;
  $hash->{DefFn} = 'WIFFI_DEVICE_Define';
  $hash->{UndefFn} = 'WIFFI_DEVICE_Undef';
  $hash->{SetFn} = 'WIFFI_DEVICE_Set';
  $hash->{AttrFn} = 'WIFFI_DEVICE_Attr';
  $hash->{FW_detailFn} = 'WIFFI_DEVICE_FwDetail';
  $hash->{FW_deviceOverview} = 1;
  $hash->{AttrList} = 'IODev stripReadingPrefix:0,1 disable:0,1 '.$readingFnAttributes;
  return FHEM::Meta::InitMod(__FILE__, $hash);
}

# FHEM changes the IODev reference after AttrFn('set'), but does not
# clear it on deleteattr. Keep accepted peer/HTTP control tied to the active
# collector, not to a stale address from another IO device.
sub WIFFI_DEVICE_Attr {
  my ($cmd, $name, $attr_name, $value) = @_;
  my $hash = $defs{$name};
  if ($attr_name eq 'IODev') {
    if ($cmd eq 'set') {
      return 'IODev must be a WIFFI_Collector'
        if !$defs{$value} && $init_done;
      return 'IODev must be a WIFFI_Collector'
        if $defs{$value} && ($defs{$value}{TYPE} // '') ne 'WIFFI_Collector';
      return 'IODev must be a WIFFI_Collector listener'
        if $defs{$value} && defined $defs{$value}{SNAME};
    }
    if ($hash) {
      my $new_io = $cmd eq 'set' ? $defs{$value} : undef;
      if (!$hash->{IODev} || !$new_io || $hash->{IODev} != $new_io) {
        my $pending = delete $hash->{'.WIFFI_HTTP'};
        HttpUtils_Close($pending) if $pending;
        delete @{$hash}{qw(PEER MODULTYP)};
        ++$hash->{'.WIFFI_DEFINITION_GEN'};
      }
      if ($cmd eq 'del') {
        delete $hash->{IODev};
        delete $hash->{READINGS}{IODev};
      }
    }
    return undef;
  }
  return undef unless $attr_name eq 'disable' && $cmd eq 'set';
  return 'Usage: attr <device> disable 0|1'
    unless defined $value && $value =~ /\A[01]\z/;
  if ($value eq '1' && $hash) {
    my $pending = delete $hash->{'.WIFFI_HTTP'};
    HttpUtils_Close($pending) if $pending;
  }
  return undef;
}

sub WIFFI_DEVICE_Define {
  my ($hash, $def) = @_;
  my @parts = split /\s+/, $def;
  my ($name, $type, $first, $second) = @parts;
  return 'Usage: define <name> WIFFI_DEVICE <mac-address> [legacy: <collector> <mac-address>]'
    unless @parts == 3 || @parts == 4;
  # The former syntax (<collector> <MAC>) remains readable for configDB
  # restoration. Its collector name is only an IODev assignment hint;
  # no separate COLLECTOR internal is kept.
  my ($collector, $mac) = @parts == 4 ? ($first, $second) : (undef, $first);
  if (!defined &WIFFI_Collector_NormalizeMac) {
    my $loaded = LoadModule('WIFFI_Collector');
    return 'Cannot load WIFFI_Collector'
      if !defined $loaded || $loaded eq 'UNDEFINED'
        || !defined &WIFFI_Collector_NormalizeMac;
  }
  my $normalized = WIFFI_Collector_NormalizeMac($mac);
  return 'Invalid WIFFI MAC address' unless $normalized;
  return $@ unless FHEM::Meta::SetInternals($hash);

  # Resolve explicitly configured IODev first; otherwise the legacy hint.
  # During startup the collector may not yet exist: core resolves
  # IODevMissing / IODevName after all definitions are loaded.
  my $configured = AttrVal($name, 'IODev', undef);
  my $preferred = $configured || $collector;
  if ($preferred && !$defs{$preferred}) {
    return "WIFFI collector $preferred is not defined" if $init_done;
    $hash->{IODevMissing} = 1;
    $hash->{IODevName} = $preferred;
  } else {
    return 'IODev must be a WIFFI_Collector'
      if $preferred && (($defs{$preferred}{TYPE} // '') ne 'WIFFI_Collector'
        || defined $defs{$preferred}{SNAME});
    AssignIoPort($hash, $preferred);
  }
  if ($hash->{IODev} && ($hash->{IODev}{TYPE} // '') ne 'WIFFI_Collector') {
    delete $hash->{IODev};
    return 'IODev must be a WIFFI_Collector';
  }
  ++$hash->{'.WIFFI_DEFINITION_GEN'} if exists $hash->{OLDDEF};
  $hash->{MAC} = $normalized;
  if (exists $hash->{OLDDEF}) {
    my $pending = delete $hash->{'.WIFFI_HTTP'};
    HttpUtils_Close($pending) if $pending;
    delete @{$hash}{qw(PEER MODULTYP)};
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

sub WIFFI_DEVICE_ValidPeer {
  my ($hash) = @_;
  my $peer = $hash->{PEER} // '';
  my @octets = split /\./, $peer, -1;
  return undef unless @octets == 4
    && !(grep { $_ !~ /\A[0-9]{1,3}\z/ || $_ > 255 } @octets)
    && $octets[0] >= 1 && $octets[0] <= 223
    && $octets[0] != 127;
  return $peer;
}

sub WIFFI_DEVICE_FwDetail {
  my ($FW_wname, $name, $room, $pageHash) = @_;
  my $hash = $defs{$name};
  return undef unless $hash && $hash->{TYPE} eq 'WIFFI_DEVICE';
  my $peer = WIFFI_DEVICE_ValidPeer($hash);
  return undef unless $peer;
  # FHEMWEB appends one <br> after FW_detailFn; add one more for spacing.
  return qq{<a href="http://$peer/" target="_blank" rel="noopener noreferrer">WIFFI Webinterface</a><br>};
}

# Every WIFFI supports an explicit relative HTTP GET path. Named shortcuts
# are exposed only for verified module types: pump controls for wiffi-pump,
# counter correction for PULSECOUNTER, and restart for the observed classic
# wiffi-pump/PULSECOUNTER/weatherman types. HTTP responses never change the
# authoritative telemetry-driven readings.
sub WIFFI_DEVICE_Set {
  my ($hash, $name, $cmd, @args) = @_;
  my $type = $hash->{MODULTYP} // '';
  my $pump = $type eq 'wiffi-pump';
  my $pulse = $type eq 'PULSECOUNTER';
  my $weather = $type eq 'weatherman';
  my $reset = $pump || $pulse || $weather;
  my $choices = $pump ? 'on off on-for-timer reset httpGet'
    : $pulse ? 'counter reset httpGet'
    : $weather ? 'reset httpGet'
    : 'httpGet';
  return "Unknown argument ".($cmd // '').", choose one of $choices"
    unless defined $cmd && ($cmd eq 'httpGet'
      || ($reset && $cmd eq 'reset')
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
  } elsif ($cmd eq 'reset') {
    return 'Usage: set <device> reset' if @args;
    $path = '/?reset:';
  } elsif ($cmd eq 'on-for-timer') {
    return 'Usage: set <device> on-for-timer <seconds (1..3600)>'
      unless @args == 1 && $args[0] =~ /\A[1-9][0-9]{0,3}\z/
        && $args[0] <= 3600;
    $path = "/?trigger:$args[0]:";
  } else {
    return "Usage: set <device> $cmd" if @args;
    $path = "/?trigger:$cmd:";
  }

  my $collector = $hash->{IODev};
  return 'WIFFI collector is not defined'
    unless $collector && ($collector->{TYPE} // '') eq 'WIFFI_Collector'
      && $defs{$collector->{NAME}} && $defs{$collector->{NAME}} == $collector;
  return 'WIFFI command already pending' if $hash->{'.WIFFI_HTTP'};

  # Only target the observed TCP peer, never an untrusted JSON reading.
  # Require a unicast IPv4 address to avoid HTTP URL/host injection.
  my $peer = WIFFI_DEVICE_ValidPeer($hash);
  return 'No valid WIFFI TCP peer yet; wait for a fresh telegram'
    unless defined $peer;

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
  $hash->{LAST_TELEGRAM} = TimeNow();
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
  <li><code>define &lt;name&gt; WIFFI_DEVICE &lt;MAC-address&gt;</code><br>
      Identify the WIFFI sender by MAC address (six colon-separated
      hex octets, or exactly 12 hex digits without separators).
      Example:
      <code>define WIFFI_PUMP2 WIFFI_DEVICE 02:00:00:00:00:01</code>.
      With a single collector, FHEM can assign IODev automatically;
      with several collectors, set <code>attr &lt;name&gt; IODev &lt;collector&gt;</code>
      explicitly. Newly autocreated devices always receive an explicit
      IODev attribute for the source collector.</li>
  <li>Existing definitions using
      <code>define &lt;name&gt; WIFFI_DEVICE &lt;collector&gt; &lt;MAC&gt;</code>
      remain supported for compatibility. To migrate without recreating
      the device: first set <code>attr &lt;name&gt; IODev &lt;collector&gt;</code>,
      then <code>modify &lt;name&gt; &lt;MAC&gt;</code> and save your
      FHEM configuration.</li>
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
  <li><a id="WIFFI_DEVICE-set-reset"></a><b>reset</b>
      (types <code>wiffi-pump</code>, <code>PULSECOUNTER</code> and
      <code>weatherman</code>)<br>
      Restart the WIFFI using the documented <code>/?reset:</code> command.
      The HTTP response is not proof of a completed restart. Confirmation
      comes from subsequent telemetry, especially a newly restarted
      <code>Systeminfo_sec_seit_reset</code> counter. This is a restart,
      not a factory reset; the destructive vendor <code>factory</code>
      command is not exposed as a named setter.</li>
  <li><a id="WIFFI_DEVICE-set-counter"></a><b>counter</b> &lt;channel&gt; &lt;value&gt;
      (type <code>PULSECOUNTER</code> only)<br>
      Set counter channel 1 to 4 with the documented
      <code>/?counter:&lt;channel&gt;:&lt;value&gt;:</code> command.
      Values use a dot as decimal separator. This module deliberately
      limits values to 0..999999, matching the manufacturer's published
      range for the normal <code>w_counterN</code> telemetry/CCU values.
      Example:
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
<p>
  When FHEMWEB knows a valid TCP peer for the device, its detail page
  includes a <b>WIFFI Webinterface</b> link to
  <code>http://&lt;peer&gt;/</code>, with a blank line before the Set controls.
  The room overview has no extra link row. The link uses only the validated
  source address learned from accepted TCP telemetry and opens in a new tab.
</p>
<h4>Attributes</h4>
<ul>
  <li><a id="WIFFI_DEVICE-attr-IODev"></a><b>IODev</b><br>
      Selects the WIFFI_Collector that receives this device's telegrams.
      Changing or deleting the binding clears the previously learned
      sender peer and cancels pending HTTP requests. FHEM also exposes
      an IODev reading as part of its standard IO association.</li>
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
  <li><code>FVERSION</code> is the installed FHEM module version.
      <code>LAST_TELEGRAM</code> is the local time of the last successfully
      mapped WIFFI telegram for this enabled device, even if measured
      values are unchanged. Both are INTERNALS, not Readings/events.</li>
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
  <li><code>define &lt;name&gt; WIFFI_DEVICE &lt;MAC-Adresse&gt;</code><br>
      Identifiziert das WIFFI-Ger&auml;t anhand seiner MAC-Adresse
      (sechs Hex-Oktette mit Doppelpunkten oder zw&ouml;lf Hex-Zeichen
      ohne Trennzeichen). Beispiel:
      <code>define WIFFI_PUMP2 WIFFI_DEVICE 02:00:00:00:00:01</code>.
      Bei einem einzigen Collector kann FHEM IODev automatisch zuweisen.
      Bei mehreren Collectors <code>attr &lt;name&gt; IODev &lt;collector&gt;</code>
      explizit setzen. Beim Autocreate wird das IODev-Attribut
      immer auf den empfangenden Collector gesetzt.</li>
  <li>Alte Definitionen der Form
      <code>define &lt;name&gt; WIFFI_DEVICE &lt;collector&gt; &lt;MAC&gt;</code>
      bleiben kompatibel. Umstellung ohne Neuanlage:
      zuerst <code>attr &lt;name&gt; IODev &lt;collector&gt;</code>,
      dann <code>modify &lt;name&gt; &lt;MAC&gt;</code> und
      die FHEM-Konfiguration speichern.</li>
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
  <li><a id="WIFFI_DEVICE-set-reset"></a><b>reset</b>
      (f&uuml;r <code>wiffi-pump</code>, <code>PULSECOUNTER</code> und
      <code>weatherman</code>)<br>
      Startet das WIFFI mit dem dokumentierten Befehl
      <code>/?reset:</code> neu. Die HTTP-Antwort beweist keinen
      abgeschlossenen Neustart. Best&auml;tigt wird er erst durch folgende
      Ger&auml;tetelemetrie, insbesondere einen neu begonnenen Z&auml;hler
      <code>Systeminfo_sec_seit_reset</code>. Dies ist nur ein Neustart,
      kein Werksreset; der destruktive Herstellerbefehl
      <code>factory</code> wird nicht als eigener Setter angeboten.</li>
  <li><a id="WIFFI_DEVICE-set-counter"></a><b>counter</b> &lt;Kanal&gt; &lt;Wert&gt;
      (nur <code>PULSECOUNTER</code>)<br>
      Setzt Z&auml;hlerkanal 1 bis 4 mit dem dokumentierten Befehl
      <code>/?counter:&lt;Kanal&gt;:&lt;Wert&gt;:</code>.
      Dezimalwerte verwenden einen Punkt. Das Modul begrenzt die Eingabe
      bewusst auf 0..999999 entsprechend dem vom Hersteller ver&ouml;ffentlichten
      Bereich der normalen <code>w_counterN</code>-Telemetrie/CCU-Werte.
      Beispiel:
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
<p>
  Sobald FHEMWEB einen g&uuml;ltigen TCP-Peer des Ger&auml;ts kennt, wird
  in der Ger&auml;tedetailansicht der Link <b>WIFFI Webinterface</b> auf
  <code>http://&lt;peer&gt;/</code> angezeigt, mit einer Leerzeile vor den
  Set-Befehlen. Die Raum&uuml;bersicht erh&auml;lt keine zus&auml;tzliche
  Link-Zeile. Verwendet wird ausschlie&szlig;lich die validierte
  Quelladresse aus akzeptierter TCP-Telemetrie; der Link &ouml;ffnet in
  einem neuen Tab.
</p>
<h4>Attribute</h4>
<ul>
  <li><a id="WIFFI_DEVICE-attr-IODev"></a><b>IODev</b><br>
      Ordnet das Ger&auml;t dem empfangenden WIFFI_Collector zu.
      Beim Wechsel oder L&ouml;schen werden die bisherige
      TCP-Absenderadresse verworfen und offene HTTP-Anfragen beendet.
      FHEM erzeugt bei der Zuordnung auch sein normales IODev-Reading.</li>
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
  <li><code>FVERSION</code> zeigt die Version des installierten
      FHEM-Moduls. <code>LAST_TELEGRAM</code> ist die lokale
      Empfangszeit des letzten erfolgreich zugeordneten Telegramms
      dieses aktiven Ger&auml;ts, auch bei unver&auml;nderten Messwerten.
      Beides sind INTERNALS, keine Readings oder Events.</li>
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

=for :application/json;q=META.json 10_WIFFI_DEVICE.pm
{
  "name": "FHEM-WIFFI-Device",
  "abstract": "Logical FHEM receiver for one WIFFI device",
  "version": "v0.1.0",
  "author": ["Flachzange"],
  "license": ["open_source"],
  "release_status": "testing"
}
=end :application/json;q=META.json

=cut
