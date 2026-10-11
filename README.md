# FHEM WIFFI Collector (early prototype)

Event-driven TCP/JSON collector for classic STALL WIFFI devices. **Experimental:** direct FHEM TCP reception, autocreate and repeated readings updates were observed on a real WIFFI-pump 2 on 2026-10-10. Other WIFFI models, runtime lifecycle and failure paths still need testing.

## Design

- One `WIFFI_Collector` listens on a shared TCP port, using FHEM's `TcpServerUtils`, and contains the shared JSON parser.
- One logical `WIFFI_DEVICE` per MAC address; optional automatic creation on the first valid telegram, disabled by default.
- Uses `vars[].homematic_name` **unchanged** as the FHEM reading name.
- Exposes `Systeminfo` fields with a `Systeminfo_` prefix.
- Reassembles stream fragments delimited by ETX (`0x03`) or EOT (`0x04`); attempts any remaining JSON on TCP EOF.
- Accepts malformed frames only as errors, never applies partial updates.
- No Node-RED, MQTT intermediary, `notify`, polling, or own periodic timer.

## Installation / continued testing (prefer a non-production FHEM instance)

Install only `FHEM/00_WIFFI_Collector.pm` and `FHEM/10_WIFFI_DEVICE.pm` in FHEM's `FHEM/` directory. There is no separate parser installation. Then restart test FHEM.

```text
define WIFFI_Collector WIFFI_Collector 9192
attr WIFFI_Collector autocreate 1
attr WIFFI_Collector allowfrom ^192\.168\.5\.(21|22|27|28)$
```

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
