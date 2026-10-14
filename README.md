# FHEM WIFFI Collector (early prototype)

Event-driven TCP/JSON collector for classic STALL WIFFI devices. **Experimental:** direct FHEM TCP reception, autocreate and repeated readings updates were observed on a real WIFFI-pump 2 on 2026-10-10. A WEATHERMAN also supplied live TCP readings in an actual FHEM installation on 2026-10-11. Other device/firmware variants, runtime lifecycle and failure paths still need testing.

## Design

- One `WIFFI_Collector` listens on a shared TCP port, using FHEM's `TcpServerUtils`, and contains the shared JSON parser.
- One logical `WIFFI_DEVICE` per MAC address; optional automatic creation on the first valid telegram, disabled by default.
- Uses `vars[].homematic_name` as the FHEM reading name by default. Optionally removes only the leading `w_` per device using `stripReadingPrefix`.
- Exposes `Systeminfo` fields with a `Systeminfo_` prefix.
- Reassembles stream fragments delimited by ETX (`0x03`) or EOT (`0x04`); attempts any remaining JSON on TCP EOF.
- Validates `vars[]` and `Systeminfo` before publishing: malformed entries/names, **missing** `vars[].value`, JSON array/object values, duplicate names and cross-namespace collisions reject the entire telegram. On rejection, no readings, `state`, heartbeat or `FRAMES_OK` are updated; `FRAMES_ERROR` increments and logs the reason at level 2. Rejected JSON payloads can additionally be logged with `attr <collector> logRejectedPayload 1` (default `0`); control characters are escaped to keep entries on one line, and payloads over 16 KiB are truncated explicitly. Repeated errors are logged individually. **JSON `null` is accepted** for a present `vars[].value` or optional `Systeminfo` field: it means *no new value*, so only that reading is skipped, retaining its previous value and timestamp. Other valid readings (including a present non-null heartbeat) are updated normally, and the frame counts as `FRAMES_OK`. Optional `name`/`type` metadata may also be `null`.
- Sensor measurements are **optional by presence** unless required by verified protocol evidence. **Observed WEATHERMAN behavior:** on the installed hardware, the brightness malfunction reports `w_lux: 0` rather than omitting it; `0` is a valid measurement and must be retained. JSON `null` leaves a previously known value untouched (without refreshing its timestamp); an invalid container value is rejected. A genuinely omitted `w_lux` is not synthesized. No fixed device-specific list of required sensor measurements is imposed without verified firmware evidence.
- Required envelope fields: a scalar nonempty `modultyp`, a `vars` array, and a `Systeminfo` object with a valid scalar `MAC-Adresse` (identity-only, not a reading). Other Systeminfo keys, including `sec_seit_reset`, are optional; a missing or `null` heartbeat is not synthesized or refreshed.
- No Node-RED, MQTT intermediary, `notify`, polling, or own periodic timer.

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
| `MAX_CLIENTS` | 16 concurrent active WIFFI TCP clients |
| `CLIENT_IDLE_TIMEOUT` | 60 seconds since the client's last received TCP data |
| `CLIENT_MAX_LIFETIME` | 180 seconds since accepting the client (absolute upper bound) |
| `MAX_FRAME` | 262144 bytes per **individual** ETX/EOT-delimited frame or unfinished tail, not the total size of coalesced complete frames |
| `CONNECTS` | FHEM `TcpServer_Accept` connection count; includes connections subsequently rejected by the collector limit |

A complete frame larger than `MAX_FRAME` is rejected and counted as `FRAMES_ERROR`; if a following complete frame is valid, it is still processed. A growing unfinished frame larger than `MAX_FRAME` closes only that temporary TCP client. A client that is idle or exceeds its absolute lifetime is closed through FHEM's delete/undefine path and counted as `FRAMES_ERROR`. A connection that closes with a complete JSON object but no ETX/EOT is accepted on EOF for firmware compatibility; an incomplete JSON EOF tail is rejected. Each failure is logged, with optional full-payload logging controlled by `logRejectedPayload`.

`CLIENTS_ACTIVE`, `CLIENTS_PEAK`, `CLIENTS_REJECTED`, `MAX_CLIENTS`, `CLIENT_IDLE_TIMEOUT`, and `CLIENT_MAX_LIFETIME` are **INTERNALS**, not Readings. No new events, DbLog rows, or polling are generated for statistics. Counters reset on collector definition/redefinition and are not persisted as historical totals. The isolated transport tests cover client-count changes, frame boundaries and timeouts, but cleanup in a **real FHEM process**, including `%selectlist` and socket ownership across shutdown/reload/modify, still needs the live integration matrix in issues #3 and #4.

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

These attributes are set only at initial autocreate and only if a `DEFINED` handler has not already set the attribute. They are not forced onto existing logical devices, and later telegrams never overwrite user configuration. All defaults can be changed or removed with normal `attr`/`deleteattr` commands.

The collector records successful auto-creations in the `AUTOCREATED` internal, and rejects duplicate logical MAC assignments, a changed sending IP for a known MAC, or a sending IP already associated with a different MAC. No arbitrary existing FHEM device is overwritten on name collision. Conflict resolution is deliberately manual. If a device legitimately changes IP, first verify the new assignment; then run `modify <device-name> <collector-name> <MAC>` in FHEM (for example `modify WIFFI_020000000001 WIFFI_Collector 02:00:00:00:00:01`) to clear its learned peer identity. Subsequent valid frames can then establish the new IP. Peer identity is an in-process observation and cannot authenticate senders or detect past conflicts after restart. Automatic discovery should only be used on a trusted LAN.

The WiFFI devices need to push TCP/JSON to FHEM's IP address on port 9192. **Do not change all devices at once**; initially test one device and keep the established Node-RED integrations until proven reliable.

Manual definition without auto-create is also possible:

```text
define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector B4:E6:2D:17:DB:07
```

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

The manufacturer documents the HTTP requests `/?trigger:on:` (switch on **indefinitely**), `/?trigger:off:` (switch off), and `/?trigger:300:` (switch on for 300 seconds). Duration is restricted by this module to an integer from 1 to 3600 seconds. The named pump shortcuts are deliberately limited to `wiffi-pump`; arbitrary paths use the separate device-independent `httpGet` setter. Command references: [STALL WIFFI-pump-2 manual](https://www.stall.biz/project/wiffi-pump-2-die-intelligente-steuerung-der-zirkulationspumpe-mit-heizungsueberwachung/) and [STALL command reference PDF](https://www.stall.biz/wp-content/uploads/2016/08/wiffi_update_anleitung22-1.pdf). The manufacturer's changelog lists `wiffi_pump2_110` as a web-server stability update without major functional changes. Actual HTTP control still requires a live test on this firmware.

### Generic HTTP GET for every WIFFI device

All logical `WIFFI_DEVICE` instances expose a device-bound HTTP GET setter independently of the reported module type:

```text
set WIFFI_PUMP2 httpGet /?trigger:120:
set WIFFI_PUMP2 httpGet /?param:0:240:
```

The setter accepts exactly one **relative path beginning with `/`**, including an optional query. It always builds `http://<last-observed-TCP-peer><path>` (port 80). No scheme, hostname, destination port, fragment, whitespace, control characters, backslashes or malformed percent escapes are accepted. Maximum path/query length: 2048 characters. FHEM HttpUtils is instructed with `ignoreredirects => 1` to avoid HTTP redirects to other targets. It does not support POST, custom headers or request bodies.

This is a low-level **configuration and control command**: issuing HTTP GET on a WIFFI can trigger actions such as a relay switch, network changes, reboot or factory reset, depending on the device and firmware. It is intentionally not limited to read-only paths. Use it only with commands you understand and on a trusted LAN. The module does not attempt to predict device support for a path, does not treat an HTTP 200 as confirmation of the physical action and does not modify incoming WIFFI readings.

The HTTP request uses FHEM's asynchronous `HttpUtils_NonblockingGet` (no external `wget` or polling). It targets only the verified TCP peer address from the last incoming telegram, not the JSON-reported IP reading. Another command is refused while an HTTP request is outstanding (5-second timeout), and outstanding requests are canceled on undefine/modify. After a restart or modify, wait for a fresh TCP telegram before sending commands.

A successful HTTP request is **not confirmation that the relay changed state**. The native `wiffi_pump` reading is updated only by subsequent sensor telemetry, not optimistically by a `set` command. Any transport or HTTP status error is logged, with no additional diagnostic readings. Commands must only be used from a trusted network; the manufacturer's endpoint does not provide cryptographic authentication.



## Recognized sample devices

| Type | MAC | Example readings |
| --- | --- | --- |
| WIFFI-pump 2 | `B4:E6:2D:17:DB:07` | `wiffi_ww_temp`, `wiffi_pump` |
| WEATHERMAN | `E8:DB:84:98:C6:D3` | `w_temperatur`, `w_lux` |
| PULSECOUNTER Strom | `DE:AD:BE:EF:FE:00` | `w_counter1`, `w_power1` |
| PULSECOUNTER Gas | `DE:AD:BE:EF:FE:01` | `w_counter1`, `w_power1` |

## Known limitations / pending work

- Initial WIFFI-pump 2 live test passed; remaining WIFFI model variants, TCP framing edge cases, startup/reload/disable and failure recovery require real FHEM integration tests.
- Pump and generic HTTP GET commands are implemented but have **not yet been tested against actual WIFFI hardware**; the live test so far covers inbound TCP telemetry only.
- No timer-based offline detector: consumers may use the `Systeminfo_sec_seit_reset` reading age.
- Statistics counters are internals on the collector; diagnostic readings and reload/modify/disable behavior need validation.
- Automatic creation produces stable names from the **full MAC address**. Rename FHEM devices as desired; matching uses collector + MAC, not the name.
- Existing MQTT-derived reading names (e.g. `gas_vars_2_value`, `aussentemperatur`) are deliberately **not** retained; dependent `userReadings`, statistics, DOIF, and DbLog queries need migration.
- Systeminfo and numeric readings are preserved as text; the code must not interpret units or coerce implausible counters.

## Testing

```sh
prove -I t/lib t/parser.t t/device.t t/autocreate.t t/set.t
```

## License

This project is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License**, as published by the Free Software Foundation, **either version 2 of the License or (at your option) any later version** (`GPL-2.0-or-later`).

This program is distributed **without any warranty**, including any implied warranty of merchantability or fitness for a particular purpose. See [`LICENSE`](LICENSE) for the full GPLv2 license text.
