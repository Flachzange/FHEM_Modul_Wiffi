# FHEM WIFFI Collector (early prototype)

Event-driven TCP/JSON collector for classic STALL WIFFI devices. **Experimental:** real FHEM telemetry/autocreate were observed on WIFFI-pump 2, WEATHERMAN and PULSECOUNTER in October 2026. Pump on/off and timer startup, PULSECOUNTER `counter`, `reset`, FHEMWEB's detail link, `reopen`, normal FHEM restart/configDB restoration and `disable`/`enable` of both module types were also confirmed by the maintainer. These observations are **not** evidence for every firmware variant or port-conflict, `reload`/`rereadcfg`, active-client or failure-injection scenarios. **The maintainer has explicitly decided not to carry out the remaining comprehensive staging tests**; these scenarios remain unverified, not pending as a release/merge requirement.

## Design

- One `WIFFI_Collector` listens on a shared TCP port, using FHEM's `TcpServerUtils`, and contains the shared JSON parser.
- One logical `WIFFI_DEVICE` per MAC address, with a MAC-only `DEF` and a standard FHEM `IODev` reference to the receiving collector; optional automatic creation on the first valid telegram, disabled by default.
- Uses `vars[].homematic_name` as the FHEM reading name by default. Optionally removes only the leading `w_` per device using `stripReadingPrefix`.
- Exposes `Systeminfo` fields with a `Systeminfo_` prefix.
- Reassembles stream fragments delimited by ETX (`0x03`) or EOT (`0x04`); attempts any remaining JSON on TCP EOF.
- Validates `vars[]` and `Systeminfo` before publishing: malformed entries/names, **missing** `vars[].value`, JSON array/object values, duplicate names and cross-namespace collisions reject the entire telegram. On rejection, no readings, `state`, heartbeat or `FRAMES_OK` are updated; `FRAMES_ERROR` increments and logs the reason at level 2. Rejected JSON payloads can additionally be logged with `attr <collector> logRejectedPayload 1` (default `0`); control characters are escaped to keep entries on one line, and payloads over 16 KiB are truncated explicitly. Repeated errors are logged individually. **JSON `null` is accepted** for a present `vars[].value` or optional `Systeminfo` field: it means *no new value*, so only that reading is skipped, retaining its previous value and timestamp. Other valid readings (including a present non-null heartbeat) are updated normally, and the frame counts as `FRAMES_OK`. Optional `name`/`type` metadata may also be `null`.
- Sensor measurements are **optional by presence** unless required by verified protocol evidence. **Observed WEATHERMAN behavior:** on the installed hardware, the brightness malfunction reports `w_lux: 0` rather than omitting it; `0` is a valid measurement and must be retained. JSON `null` leaves a previously known value untouched (without refreshing its timestamp); an invalid container value is rejected. A genuinely omitted `w_lux` is not synthesized. No fixed device-specific list of required sensor measurements is imposed without verified firmware evidence.
- Required envelope fields: a scalar nonempty `modultyp`, a `vars` array, and a `Systeminfo` object with a valid scalar `MAC-Adresse` (identity-only, not a reading). Other Systeminfo keys, including `sec_seit_reset`, are optional; a missing or `null` heartbeat is not synthesized or refreshed.
- No Node-RED, MQTT intermediary, `notify`, polling, or own periodic timer.

## Module version and last telegram

Both FHEM modules embed matching `FHEM::Meta` version `v0.2.0` (experimental development version; this branch is **not** a published release). The FHEM-standard `FVERSION` INTERNAL displays the installed module version on each collector and logical device; custom files without SVN `$Id` require a minimal fallback from the embedded META.json `version`, because `FHEM::Meta` may not generate `x_version` automatically. It identifies the installed FHEM Perl module, not the WIFFI firmware in `Systeminfo_firmware`. The two embedded version values must always agree; `t/meta.t` checks this. No module-version Reading or DbLog event is generated. After replacing both module files, **restart FHEM** to initialize the module metadata and refresh the `FVERSION` INTERNAL on existing devices. This was confirmed by the maintainer on 2026-10-14: `FVERSION` appeared after a restart. Merely copying the files did not update the running module. CI uses a small metadata contract double, not the real runtime.

Each collector and logical device also exposes a `LAST_TELEGRAM` INTERNAL (local FHEM receive time). The collector reflects the most recent syntactically valid, identity-accepted WIFFI telegram, including an otherwise unknown MAC. Invalid JSON and duplicate/conflicting identities do not advance it. A logical `WIFFI_DEVICE` updates its own timestamp only when an enabled device successfully accepts and maps a telegram; an unchanged sensor value still advances it. Disabling a logical device freezes its own timestamp, but the collector can continue to receive its telegrams. Both INTERNALS start empty after FHEM restart until new data arrive. Neither is a Reading, event, DbLog row or periodic watchdog.

## Installation / continued testing (prefer a non-production FHEM instance)

Install only `FHEM/00_WIFFI_Collector.pm` and `FHEM/10_WIFFI_DEVICE.pm` in FHEM's `FHEM/` directory. There is no separate parser installation. Then restart test FHEM.

```text
define WIFFI_Collector WIFFI_Collector 9192
attr WIFFI_Collector autocreate 1
attr WIFFI_Collector allowfrom ^192\.168\.5\.(21|22|27|28)$
```

### Rejected telegram diagnostics

By default, errors contain the TCP sender and rejection reason, but not the full JSON. To inspect incoming telegrams when parsing, identity validation or reading publication fails, enable:

```text
attr WIFFI_Collector logRejectedPayload 1
```

Each rejected frame is logged individually at FHEM log level 2. The opt-in entry includes the original payload (normal telegrams in full, capped at 16 KiB with a `truncated` marker for unusually large data); CR/LF and control bytes are escaped so there is one logical log record per frame. `FRAMES_ERROR` still counts every rejection. Successfully parsed telemetry including `value: null` is **not** logged as an error. Identifiers such as local IP addresses and MACs, and user-defined field values, may be present in the log: enable this on installations where log access and retention are appropriate. This attribute affects only error logging; it does not emit new FHEM readings or DbLog events.

### TCP connection limits and INTERNALS

The shared TCP receiver stays nonblocking and uses FHEM `TcpServer_Accept` / `TcpServer_Close` and temporary `WIFFI_Collector` client devices. There is no periodic polling. Per-client timeout callbacks use FHEM `InternalTimer`, and are removed on disconnect. Limits are currently fixed (not user attributes):

| INTERNAL | Meaning |
| --- | --- |
| `CLIENTS_ACTIVE` | Currently accepted, open WIFFI TCP clients (usually 0 between short-lived WIFFI sends) |
| `CLIENTS_PEAK` | Maximum concurrent active clients since the collector was defined |
| `CLIENTS_REJECTED` | Clients disconnected immediately because the active-client limit was reached |
| `CLIENTS_TIMEOUT` | Accepted TCP connections closed after 60 s inactivity or 180 s absolute lifetime; each expired connection is counted once, whether or not it contained an unfinished frame |
| `MAX_CLIENTS` | 16 concurrent active WIFFI TCP clients |
| `CLIENT_IDLE_TIMEOUT` | 60 seconds since the client's last received TCP data |
| `CLIENT_MAX_LIFETIME` | 180 seconds since accepting the client (absolute upper bound) |
| `MAX_FRAME` | 262144 bytes per **individual** ETX/EOT-delimited frame or unfinished tail, not the total size of coalesced complete frames |
| `CONNECTS` | FHEM `TcpServer_Accept` connection count; includes connections subsequently rejected by the collector limit |

A complete frame larger than `MAX_FRAME` is rejected and counted as `FRAMES_ERROR`; if a following complete frame is valid, it is still processed. A growing unfinished frame larger than `MAX_FRAME` closes only that temporary TCP client. A client that is idle or exceeds its absolute lifetime is closed through FHEM's delete/undefine path and increments the `CLIENTS_TIMEOUT` INTERNAL. **Only if its unfinished receive buffer contains a non-whitespace telegram** is that discarded tail also counted as `FRAMES_ERROR`. Therefore, a silent client or a client that previously sent complete valid telegrams but leaves the connection open is not a malformed-frame error. The same holds for whitespace-only input. The timeout is logged on **level 3** if no incomplete telegram is discarded, or **level 2** with a precise rejection reason if an incomplete telegram is discarded. Repeated occurrences are logged individually; `logRejectedPayload` includes the incomplete telegram's raw data only when explicitly enabled. A connection that closes with a complete JSON object but no ETX/EOT is accepted on EOF for firmware compatibility; an incomplete JSON EOF tail is rejected. Each failure is logged, with optional full-payload logging controlled by `logRejectedPayload`.

`CLIENTS_ACTIVE`, `CLIENTS_PEAK`, `CLIENTS_REJECTED`, `CLIENTS_TIMEOUT`, `MAX_CLIENTS`, `CLIENT_IDLE_TIMEOUT`, and `CLIENT_MAX_LIFETIME` are **INTERNALS**, not Readings. No new events, DbLog rows, or polling are generated for statistics. Counters reset on collector definition/redefinition (`define`/`modify`) and are not persisted as historical totals. Manual `set reopen` retains these counters; deleting/renaming a temporary client or a normal EOF does not increment `CLIENTS_TIMEOUT`. The isolated transport tests cover client-count changes, frame boundaries and timeouts, but cleanup in a **real FHEM process**, including `%selectlist` and socket ownership across shutdown/reload/modify, still needs the live integration matrix in issues #3 and #4.

### Listener lifecycle, manual recovery and logging

The collector registers a manual `set reopen` command. There are **no automatic bind retries** or background retry loops. The effective listener status is exposed **only through INTERNALS**:

| INTERNAL | Meaning |
| --- | --- |
| `LISTENER_STATUS` | `stopped` during deferred startup or after a successful close, `listening` after a successful bind, or `error` after a failed bind or incomplete temporary-client cleanup |
| `LISTENER_ERROR` | Last TCP bind or temporary-client cleanup error (empty after successful bind or new definition) |
| `TCP_PORT` | Desired configured TCP port, retained after a failed bind for recovery |

After a port conflict or other bind failure, the WIFFI collector definition remains present. The failure is recorded in `LISTENER_ERROR`, with the port, underlying error text and recovery instruction at **FHEM log level 1**. Every failed attempt is logged individually. After resolving the cause, run:

```text
set WIFFI_Collector reopen
```

`reopen` first tries to delete all accepted temporary TCP clients, closes the old listener and clears stale listener/socket metadata. **If any client deletion reports an error or leaves its original FHEM definition behind, no new listener is opened.** `CLIENTS_ACTIVE` reflects only remaining open client sockets, `LISTENER_STATUS=error` and `LISTENER_ERROR` identify the cleanup failure; each individual failure is logged at **level 1** (including repeat attempts). After correcting the cause, `set reopen` retries the cleanup and can restore reception without an automatic retry loop. A failed port bind likewise returns/logs an error and keeps the collector defined. Successful opens, listener closes and renames are logged at **level 3**. These lifecycle logs are independent of `logRejectedPayload`, which controls *only* inclusion of raw rejected JSON in frame diagnostics.

On `modify WIFFI_Collector <new-port>`, temporary clients and the existing listener are closed before binding the new port. If client cleanup fails, the module returns an error: FHEM restores the previous device definition, the old configured `TCP_PORT` remains, and the listener stays stopped with an error until manual `set reopen`. The collector's per-definition counters are reset **only on successful redefinition**. Invalid port syntax is rejected without closing the healthy listener. `undefine` also reports a cleanup failure rather than allowing FHEM to remove a collector with clients left behind. After correcting the failure, retry `undefine` or use `set reopen`. A normal `rename` preserves the active connection while migrating the listener select-list entry, temporary client parent references and the `IODev` attributes and any remaining legacy `DEF` references of its logical WIFFI_DEVICE children; sensor readings and user-defined attributes unrelated to the binding remain unchanged. Downstream automations referring to the old collector name may require updating.

FHEM's own `TcpServer_Open` currently writes its usual `state=Initialized` **Reading** when attempting to open a port, even before bind success. That framework behavior is not used as the listener health indicator; `LISTENER_STATUS` and `LISTENER_ERROR` are not Readings and produce no additional events or DbLog rows.

**Verification limit:** `t/lifecycle.t` exercises FHEM/TcpServerUtils contracts with a test double, including simulated `CommandDelete`/`UndefFn`/`DeleteFn` refusal, partial child cleanup, repeated recovery attempts and lifecycle rollback. These are isolated unit tests; actual socket ownership, `%selectlist`, `reload`, `rereadcfg` and live FHEM failure recovery are not fully verified. The maintainer has declined further exhaustive lifecycle/failure-injection testing; the unverified scenarios remain documented in the [historical verification matrix](docs/fhem-lifecycle-test-matrix.md).

### Standard FHEM `disable` attribute (Issue #9)

Both the listener and each logical device support `disable:0,1` independently. Use the normal FHEM commands:

```text
attr WIFFI_Collector disable 1
attr WIFFI_Collector disable 0
deleteattr WIFFI_Collector disable
attr WIFFI_PUMP2 disable 1
attr WIFFI_PUMP2 disable 0
deleteattr WIFFI_PUMP2 disable
```

- **Collector disabled:** close the listener and accepted TCP connections, including their temporary FHEM client entries and associated timers. No incoming telemetry is received and `set WIFFI_Collector reopen` is refused while disabled. At FHEM startup, an already-disabled collector does not bind its port. `disable 0` or `deleteattr disable` opens the configured port again without requiring a restart; unsuccessful rebinds remain visible in `LISTENER_STATUS=error` and `LISTENER_ERROR`. Existing logical device definitions/readings are preserved.
- **Individual WIFFI_DEVICE disabled:** an accepted telegram for that MAC does not update readings, `state`, `MODULTYP` or heartbeat; it is intentionally ignored rather than counted in `FRAMES_OK`, `FRAMES_ERROR` or `FRAMES_UNKNOWN`. Autocreate does not create a replacement for the disabled, already-known MAC. Other logical devices on the same collector continue to receive data. `on`, `off`, `on-for-timer` and `httpGet` are blocked; a currently pending asynchronous HTTP request is closed and any late callback ignored. Removing the attribute or setting `disable 0` resumes normal telemetry and commands.
- These are **independent scopes**: disabling the collector stops the TCP listener, but does not by itself block an already-defined logical device from making a direct HTTP request to its last observed peer. To disable that outgoing control as well, disable the `WIFFI_DEVICE` itself.
- Deliberate disabling does not introduce new diagnostic readings or polling. The maintainer confirmed that `disable`/`enable` worked for both `WIFFI_Collector` and `WIFFI_DEVICE` in live FHEM. Detailed FD/`%selectlist`, disabled-startup and pending HTTP cancellation acceptance is still pending; isolated regression tests cover those paths but do not establish the full live lifecycle.

### Synchronous FHEM callbacks during TCP receive

FHEM executes Reading-triggered `notify`/DOIF callbacks synchronously. If an action during the first of several already-buffered TCP telegrams deletes, modifies or reopens the Collector, the old connection is invalidated and **remaining frames from that connection are not delivered**. The same applies if the logical WIFFI_DEVICE handling the frame is deleted or explicitly modified. A simple `rename` of Collector or logical device does **not** interrupt processing as long as the exact original object and listener remain valid.

The implementation checks live FHEM hash identity and the collector listener generation between frames and after device publication. Interrupting an existing batch is logged at **level 3**; it is an intentional lifecycle action and must not increment `FRAMES_ERROR`. Real malformed telegrams still increment `FRAMES_ERROR` and are logged individually at level 2 (optional `logRejectedPayload`). No additional Readings, FHEM events or timers are created.

Regression tests in `t/reentrancy.t` invoke synchronous callbacks while running the real WIFFI modules under a controlled FHEM contract double. This provides regression coverage but does **not** replace live-FHEM validation of socket ownership, selectlist or notify/DOIF callback chains.

### Automatic device discovery

Enable `autocreate` explicitly with `attr WIFFI_Collector autocreate 1` after restricting `allowfrom` to trusted sources. Each first valid telegram from an unknown normalized MAC then creates a persistent FHEM `WIFFI_DEVICE`. No separate `define` commands are needed for each WIFFI.

Names are deliberately deterministic and independent of `modultyp`: `WIFFI_` followed by **all 12 hexadecimal MAC digits** (for example `WIFFI_020000000001` for the synthetic test MAC `02:00:00:00:00:01`). The automatically created device can be renamed; future telegrams continue to match by the defined MAC and collector. Running `attr WIFFI_Collector autocreate 0` again stops only *new* automatic definitions; existing devices keep receiving data.

Autocreate sets `room WIFFI` and these event/DbLog defaults on every newly discovered logical device:

```text
attr <device> event-on-change-reading .*
attr <device> event-on-update-reading Systeminfo_sec_seit_reset
attr <device> DbLogExclude ^Systeminfo_sec_seit_reset$
```

Unchanged readings continue to receive fresh timestamps, but do not generate ordinary change events; `Systeminfo_sec_seit_reset` still generates a heartbeat event on each update and is excluded from DbLog. Note that unchanged sensor values no longer generate periodic graph/database samples through the normal event stream. For a newly detected `wiffi-pump`, autocreate additionally sets `stateFormat wiffi_pump` and `devStateIcon true:on false:off`, displaying the reported pump state in FHEMWEB. It does **not** set `webCmd`.

These attributes are set only at initial autocreate and only if a `DEFINED` handler has not already set the attribute. New devices additionally receive the source-pinned standard `IODev` attribute, which is needed to keep collector assignment deterministic when multiple collectors exist. They are not forced onto existing logical devices, and later telegrams never overwrite user configuration. All defaults can be changed or removed with normal `attr`/`deleteattr` commands.

The collector records successful auto-creations in the `AUTOCREATED` internal, and rejects duplicate logical MAC assignments, a changed sending IP for a known MAC, or a sending IP already associated with a different MAC. No arbitrary existing FHEM device is overwritten on name collision. Conflict resolution is deliberately manual. If a device legitimately changes IP, first verify the new assignment; then run `modify <device-name> <MAC>` in FHEM (for example `modify WIFFI_020000000001 02:00:00:00:00:01`) to clear its learned peer identity. Subsequent valid frames can then establish the new IP. Peer identity is an in-process observation and cannot authenticate senders or detect past conflicts after restart. Automatic discovery should only be used on a trusted LAN.

The WiFFI devices need to push TCP/JSON to FHEM's IP address on port 9192. **Do not change all devices at once**; initially test one device and keep the established Node-RED integrations until proven reliable.

Manual definition without auto-create is also possible. To select a
specific collector **directly when creating a device**, use:

```text
define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector B4:E6:2D:17:DB:07
save
```

For a new interactive `define`, FHEM stores **only the MAC in `DEF`**
and our module creates the persistent `IODev=WIFFI_Collector` attribute
through FHEM's standard `CommandAttr` mechanism. You do not need a
separate `attr` command.

The shorter form also works:

```text
define WIFFI_PUMP2 WIFFI_DEVICE B4:E6:2D:17:DB:07
save
```

If **exactly one active WIFFI_Collector** exists when this new device is
defined, its `IODev` attribute is likewise set automatically. If
multiple collectors exist, the MAC-only definition is left unbound
instead of assigning a possibly wrong collector; specify the collector
in `define`, or set `attr WIFFI_PUMP2 IODev WIFFI_Collector` afterward.
If there is no collector yet, the IODev attribute can be set once one
has been created.

A MAC can also be entered as exactly 12 hexadecimal digits without
colons (e.g. `B4E62D17DB07`). The normalized `MAC` INTERNAL remains
uppercase with colons. Both supported manual define forms converge to
the same **MAC-only DEF + persistent IODev attribute**, which a later
`save` also stores in configDB. Autocreate persists the receiving
collector in the same way. FHEM additionally keeps its own `IODev`
INTERNAL and Reading.

**Migration for existing devices** (same device name and Readings, no deletion
or recreated FUUID): old definitions such as
`define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector 02:00:00:00:00:01`
continue to load unchanged. After updating both module files, run:

```text
attr WIFFI_PUMP2 IODev WIFFI_Collector
modify WIFFI_PUMP2 B4:E6:2D:17:DB:07
save
```

Use the **actual MAC from your existing `DEF`** in the `modify` command;
the address shown above is the known WIFFI-pump example and is not a
universal placeholder for every device. Repeat per device, with its own MAC
and appropriate collector. This explicit migration also works with configDB:
`save` persists the MAC-only definition and its `IODev` attribute.
A `modify` invalidates the previously learned TCP peer, so the device
needs another telegram before its direct HTTP commands work again.
Do **not** delete/redefine the device just to change the definition.
During configDB/FHEM startup, existing definitions are loaded without automatically writing attributes or changing their stored DEF; the automatic IODev persistence applies to **new interactive definitions**, not passive configuration restoration.
A collector rename updates matching `IODev` attributes and any remaining
legacy collector prefix in `DEF`.

Removing `attr IODev` intentionally unbinds a device at runtime and clears
the previously learned peer. Reassign it explicitly; do not rely on the
old IODev Reading to select a different collector later. `IODev` is the
only runtime binding: the former `COLLECTOR` INTERNAL is no longer used.

For devices already created while the earlier **unfiltered** autocreate defaults were active (such as `WIFFI_DEADBEEFFE00`), add the three attributes manually if desired. For an unfiltered device, remove them using `deleteattr <device> <attribute>`. Updating the collector does **not** retrofit attributes onto existing devices.

The module does not alter attributes on existing devices or edit existing MQTT2 devices.

### Optional reading-name normalization

To consistently omit the firmware-specific `w_` prefix on an individual device:

```text
attr WIFFI_WEATHERMAN stripReadingPrefix 1
```

This maps `w_temperatur` to `temperatur`, `w_lux` to `lux` and `w_counter1` to `counter1`; `wiffi_pump`, `Systeminfo_sec_seit_reset` and names without the exact leading `w_` remain unchanged. Default is `0`, preserving the original names on other devices (including existing PULSECOUNTERs and pumps). The `desc` JSON field is never used for naming.

When two original names would produce the same target name (for example `w_lux` and `lux`), or an incoming name would map to FHEM's reserved `state`, the entire telegram is rejected before updating any readings. The collector counts this as `FRAMES_ERROR`.

Switching the attribute does **not** remove already-existing old readings from the device. Check and update any `stateFormat`, `userReadings`, plots and automation references; then delete stale old readings manually if desired. This option does not recreate old MQTT reading names: e.g. `lux` differs from the former Node-RED `helligkeit`.

### WEATHERMAN integration: readings, events and DbLog (field notes, 2026-10-11)

The following is an **installation example**, not a module default or a promise about all firmware versions. A WEATHERMAN sending valid TCP telegrams was observed with `stripReadingPrefix 1`. The native names come from `vars[].homematic_name`, *not* `desc` or the former Node-RED MQTT aliases:

| Former MQTT reading | Native FHEM reading |
| --- | --- |
| `aussentemperatur` | `temperatur` |
| `rel_feuchte`, `abs_feuchte` | `feuchte_rel`, `feuchte_abs` |
| `helligkeit` | `lux` |
| `regenstatus` | `regenmelder` |
| `regen_pro_h` | `regen_letzte_h` |
| `nn_luftdruck` | `barometer` |
| `peak_windgeschwindigkeit` | `wind_spitze` |
| `avg_windgeschwindigkeit` | `wind_mittel` |
| `windwinkel` | `wind_dir` |
| `sonne_azimut`, `sonne_elevation` | `azimut`, `elevation` |

Other observed native readings include `regenstaerke`, `sonne_scheint` and `windchill`. Verify the actual `list <device>` output before updating downstream consumers. The site-specific `temperature` and `brightness` aliases and the moving averages `windwinkel.av`, `windwinkel.avH`, `peak_windgeschwindigkeit.av` were created with **FHEM `userReadings`**, not by this module. The average wind direction uses a separate circular-mean helper because 0° and 360° are equivalent.

Example **event policy** for a site needing fresh plot samples even while sensor values remain unchanged:

```text
attr WIFFI_WEATHERMAN stripReadingPrefix 1
attr WIFFI_WEATHERMAN event-on-change-reading (?!Systeminfo_zeitpunkt$).*
attr WIFFI_WEATHERMAN event-on-update-reading Systeminfo_sec_seit_reset
attr WIFFI_WEATHERMAN event-min-interval ^(lux|wind_dir|wind_mittel|wind_spitze)$:60,^(temperatur|feuchte_rel|feuchte_abs|barometer|regenmelder|regenstaerke|regen_letzte_h|sonne_scheint)$:300
```

With `event-on-change-reading`, **real value changes remain immediate** (e.g. `regenmelder false -> true`); `event-min-interval` also emits unchanged readings after the configured interval *when a new telegram arrives*. It is **not a fixed polling scheduler** and is **not a general upper rate limit for changing readings**. The explicitly listed `Systeminfo_sec_seit_reset` update event serves as a heartbeat; exclude it from DbLog when not needed in history.

**DbLog filtering is separate from event generation.** High-frequency wind changes can still produce many database records even with `event-min-interval`. To cap only database writes, an optional `DbLogExclude` entry such as `^(wind_dir|wind_mittel|windwinkel[.]av|peak_windgeschwindigkeit[.]av)$:60:force` may be **appended to existing exclusions**. Do not overwrite the existing `DbLogExclude` list when adding it. `wind_spitze` may intentionally remain unthrottled in history to preserve short gusts. This extra wind-history limit was proposed during the field test; its deployment was **not confirmed**.

When migrating FHEM DOIF/notify/SVG references, keep display titles such as `title 'Weatherman'` unchanged, but update every `#logdb Weatherman:old_reading` source to a **verified** native reading. In one installation the active SVG configurations were checked after the migration, with no remaining references to the old MQTT `Weatherman` data source. Test alarm/awning control conditions and DOIF `wait` independently before removing the old MQTT device.

### Direct control of WIFFI-pump 2

Once a valid TCP telegram identifies a logical device as `wiffi-pump`, it exposes these FHEM setters:

```text
set WIFFI_PUMP2 on
set WIFFI_PUMP2 off
set WIFFI_PUMP2 on-for-timer 300
```

The manufacturer documents the HTTP requests `/?trigger:on:` (switch on **indefinitely**), `/?trigger:off:` (switch off), and `/?trigger:300:` (switch on for 300 seconds). Duration is restricted by this module to an integer from 1 to 3600 seconds. The named pump shortcuts are deliberately limited to `wiffi-pump`; arbitrary paths use the separate device-independent `httpGet` setter. Command references: [STALL WIFFI-pump-2 manual](https://www.stall.biz/project/wiffi-pump-2-die-intelligente-steuerung-der-zirkulationspumpe-mit-heizungsueberwachung/) and [STALL command reference PDF](https://www.stall.biz/wp-content/uploads/2016/08/wiffi_update_anleitung22-1.pdf). The manufacturer's changelog lists `wiffi_pump2_110` as a web-server stability update without major functional changes. **Live verification (2026-10-11, firmware `wiffi_pump2_110`):** the FHEMWEB `on`/`off` controls switched the physical pump, and later incoming `wiffi_pump` readings reflected `true`/`false`. `set WIFFI_PUMP2 on-for-timer 30` also started the pump successfully; the exact 30-second expiration was **not independently timed**. These results apply to the tested WIFFI-pump 2 only, not to all WIFFI firmwares or arbitrary `httpGet` paths.

### Device restart

The observed classic WIFFI types `wiffi-pump`, `PULSECOUNTER` and
`weatherman` expose a `reset` convenience setter:

```text
set WIFFI_PUMP2 reset
set WIFFI_PULSECOUNTER_Wasser reset
set WIFFI_WEATHERMAN reset
```

It sends the manufacturer-documented `/?reset:` restart command. STALL
documents this restart path for WIFFI-pump, PULSECOUNTER and WEATHERMAN
devices. The setter does not synthesize a successful reboot reading: the
next accepted telemetry is authoritative. In particular,
`Systeminfo_sec_seit_reset` should begin again at a small value after the
device reconnects. A successful HTTP response only confirms request handling,
not that the reboot completed. This `reset` setter is **only a restart**;
it is deliberately distinct from the destructive vendor `factory` command,
which is not exposed as a named setter.

### PULSECOUNTER counter correction

For the observed `PULSECOUNTER` module type the device now exposes one additional convenience setter:

```text
set WIFFI_PULSECOUNTER_Wasser counter 2 143.550
```

It maps directly to the manufacturer's documented `/?counter:<channel>:<value>:` command. Channels 1 through 4 are accepted. The value must use a dot as decimal separator. The module **conservatively limits input to 0..999999**, matching STALL's published range for the normal `w_counterN` CCU/telemetry values; this is a module-side safety limit, not a claim that `counter_LAN41` cannot internally store larger values. Within that range the decimal representation is forwarded unchanged rather than rounded. Source: [STALL PULSECOUNTER2-LAN command documentation](https://www.stall.biz/project/pulsecounter-lan2-verbraeuche-von-strom-gas-und-wasser-komfortabel-messen/).

This setter deliberately satisfies an **observability requirement**: the resulting physical counter value is sent again in normal telemetry as `w_counter1`..`w_counter4` (or `counter1`..`counter4` with `stripReadingPrefix 1`). An HTTP 2xx response is therefore not treated as confirmation and no optimistic/shadow reading is created. The later telemetry value wins. Device-side counter configuration can quantize the requested value to its configured resolution.

**Observed device evidence (2026-10-11, `counter_LAN41`):** a direct device request `/?counter:2:143.550:` was accepted and the channel subsequently continued counting from the corrected value in normal counter telemetry. A request for `143.592` later read back as `143.590`, demonstrating why the module must not invent a successful exact readback from the HTTP request itself.

Other PULSECOUNTER expert parameters and WEATHERMAN configuration commands are **not** promoted to named setters merely because their web interfaces expose them. Where the configured value is visible only in the device web UI and not in normal WIFFI telemetry, it stays available through the explicit `httpGet` escape hatch until a simple verified telemetry readback exists.

**Dynamic device type:** `WIFFI_DEVICE` takes `modultyp` from every otherwise valid telegram and stores it as the `MODULTYP` INTERNAL. When an established device reports a different type, the transition is logged at **FHEM log level 3** (old → new), but the frame remains valid: readings and heartbeat are updated normally and `FRAMES_ERROR` is not increased. The pump-only `on`, `off` and `on-for-timer` commands are offered **only while the current type is `wiffi-pump`**. The `counter` command is offered only while the current type is exactly `PULSECOUNTER`. The `reset` command is offered for the observed classic `wiffi-pump`, `PULSECOUNTER` and `weatherman` types. Type-specific commands disappear when the device reports another type and return when the matching type is observed again. The explicit `httpGet` command remains available to all types. The observed type is **not persisted**: after a restart or an explicit logical-device `modify`, the first accepted telegram determines it again.

Existing `stateFormat` and `devStateIcon` attributes are **not changed automatically** on a type transition. Pump defaults are set only on initial autocreate and user-defined attributes must be preserved. If a former pump stops reporting `wiffi_pump`, manually adjust or remove its obsolete display attributes and any automation depending on old readings. The dynamic transition behavior has isolated regression tests, **not a dedicated live FHEM type-switch test**.

### Webinterface link in FHEMWEB

As soon as a logical WIFFI device has learned a validated TCP peer, FHEMWEB
shows a **WIFFI Webinterface** link on the **device detail page**, with a
blank line before the Set controls. The link is **not** shown in the room
overview. The target is always `http://<validated-peer>/` and opens in a
new tab. No JSON-reported IP address or user-supplied host is used.
The link disappears until a valid peer is known, for example immediately
after an explicit `modify`.

The implementation uses FHEM's module `FW_detailFn` and keeps the standard
`DeviceOverview` enabled. FHEMWEB's `FW_addDetailToSummary` would create
an unwanted separate row in the room overview, so it is deliberately omitted.

### Generic HTTP GET for every WIFFI device

All logical `WIFFI_DEVICE` instances expose a device-bound HTTP GET setter independently of the reported module type:

```text
set WIFFI_PUMP2 httpGet /?trigger:120:
set WIFFI_PUMP2 httpGet /?param:0:240:
```

The setter accepts exactly one **relative path beginning with `/`**, including an optional query. It always builds `http://<last-observed-TCP-peer><path>` (port 80). No scheme, hostname, destination port, fragment, whitespace, control characters, backslashes or malformed percent escapes are accepted. Maximum path/query length: 2048 characters. FHEM HttpUtils is instructed with `ignoreredirects => 1` to avoid HTTP redirects to other targets. It does not support POST, custom headers or request bodies.

This is a low-level **configuration and control command**: issuing HTTP GET on a WIFFI can trigger actions such as a relay switch, network changes, reboot or factory reset, depending on the device and firmware. It is intentionally not limited to read-only paths. Use it only with commands you understand and on a trusted LAN. The module does not attempt to predict device support for a path, does not treat an HTTP 200 as confirmation of the physical action and does not modify incoming WIFFI readings.

The HTTP request uses FHEM's asynchronous `HttpUtils_NonblockingGet` (no external `wget` or polling). It targets only the verified TCP peer address from the last incoming telegram, not the JSON-reported IP reading. Another command is refused while an HTTP request is outstanding (5-second timeout), and outstanding requests are canceled on undefine/modify. After a restart or modify, wait for a fresh TCP telegram before sending commands.

A successful HTTP request is **not confirmation that the relay changed state**. Successful asynchronous `set` calls suppress FHEM's automatically generated command event; they do not emit a misleading `on`, `off` or `httpGet` event just because an HTTP request started. The native `wiffi_pump` reading is updated only by subsequent sensor telemetry, not optimistically by a `set` command. Any transport or HTTP status error is logged, with no additional diagnostic readings. Commands must only be used from a trusted network; the manufacturer's endpoint does not provide cryptographic authentication.



## Recognized sample devices

MAC addresses below are **synthetic placeholders**, not identifiers of the observed physical WIFFI devices.

| Type | MAC | Example readings |
| --- | --- | --- |
| WIFFI-pump 2 | `02:00:00:00:00:01` | `wiffi_ww_temp`, `wiffi_pump` |
| WEATHERMAN | `02:00:00:00:00:02` | `w_temperatur`, `w_lux` |
| PULSECOUNTER Strom | `02:00:00:00:00:03` | `w_counter1`, `w_power1` |
| PULSECOUNTER Gas | `02:00:00:00:00:04` | `w_counter1`, `w_power1` |

## Known limitations / pending work

- Real FHEM telemetry was observed for WIFFI-pump 2, WEATHERMAN and PULSECOUNTER. Manual `reopen`, normal restart with configDB restore and both module types' `disable`/`enable` were positively confirmed. Other firmware variants, special TCP framing, `reload`/`rereadcfg`, port collisions and failure recovery remain **unverified**; further comprehensive staging tests are deliberately **not planned**.
- **Tested on physical WIFFI-pump 2 (`wiffi_pump2_110`, 2026-10-11):** `on`/`off` switch the pump and `on-for-timer 30` starts it. Timer expiry was not independently measured.
- **PULSECOUNTER2-LAN (`counter_LAN41`):** the manufacturer's direct `counter` HTTP command changes the physical counter and normal telemetry reports the resulting value (2026-10-11). The maintainer subsequently confirmed that the FHEM `counter` convenience setter works. The exact setter value and a before/after reading transcript were not recorded.
- Other generic `httpGet` commands and WEATHERMAN configuration actions have not been promoted to convenience setters without telemetry-visible readback.
- No timer-based offline detector: consumers may use the `Systeminfo_sec_seit_reset` reading age.
- Statistics and listener diagnostics are collector INTERNALS, not Readings. `reopen` and `disable`/`enable` have successful real-FHEM smoke tests; `modify`, `rename`, `reload`, `rereadcfg`, complete socket cleanup and detailed failure paths are covered by isolated regression tests but not by individual live acceptance records. The maintainer waived the detailed matrix, as documented in [issue #4](https://github.com/Flachzange/FHEM_Modul_Wiffi/issues/4); #9 is closed.
- Automatic creation produces stable names from the **full MAC address**. Rename FHEM devices as desired; matching uses collector + MAC, not the name.
- Existing MQTT-derived reading names (e.g. `gas_vars_2_value`, `aussentemperatur`) are deliberately **not** retained; dependent `userReadings`, statistics, DOIF, and DbLog queries need migration.
- Systeminfo and numeric readings are preserved as text; the code must not interpret units or coerce implausible counters.

## FHEM framework compatibility audit

The [source-backed FHEM API audit](docs/fhem-framework-audit.md) records concrete framework requirements, the deliberately narrow compatibility fixes and the separation between isolated tests and system-specific verification. Both module-specific `define` commands require exactly their documented argument count; surplus parameters are rejected rather than ignored.

## FHEM command reference and release procedure

The two installable FHEM module files contain English and German embedded
commandref documentation. FHEM displays it through its normal module help
mechanism (`help WIFFI_Collector` / `help WIFFI_DEVICE`); it covers the
implemented `define`, `set`, `attr`, reading and diagnostic interfaces.
The user-facing commandref contains no development TODOs or test-status notes.

The separate [release verification checklist](docs/release-readiness.md)
covers the FHEM commandref generator, compatibility checks, actual integration
evidence, migration considerations and packaging. FHEM module documentation
format follows the [official developer guidelines](https://wiki.fhem.de/wiki/Guidelines_zur_Dokumentation).

## Testing

```sh
prove -I t/lib t/parser.t t/device.t t/autocreate.t t/set.t t/transport.t t/lifecycle.t t/reentrancy.t t/commandref.t t/meta.t t/telegram_internals.t t/iodev.t
```

This is the test command used by `.github/workflows/perl-tests.yml`. The `t/commandref.t` test validates English/German commandref sections, anchor parity and simple HTML tag pairing. It exercises the two real Perl modules against **isolated FHEM contract doubles**, not a full FHEM runtime or live socket/hardware environment. The CI workflow also checks Perl syntax for both modules. Real hardware observations, the completed **partial** FHEM smoke tests and the deliberately **waived/unverified** full listener/lifecycle matrix are documented separately in [`docs/fhem-lifecycle-test-matrix.md`](docs/fhem-lifecycle-test-matrix.md).

## License

This project is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License**, as published by the Free Software Foundation, **either version 2 of the License or (at your option) any later version** (`GPL-2.0-or-later`).

This program is distributed **without any warranty**, including any implied warranty of merchantability or fitness for a particular purpose. See [`LICENSE`](LICENSE) for the full GPLv2 license text.
