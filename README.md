# FHEM WIFFI Collector (early prototype)

Event-driven TCP/JSON collector for classic STALL WIFFI devices. **Experimental:** not yet validated against a running FHEM installation or real hardware.

## Design

- One `WIFFI_Collector` listens on a shared TCP port, using FHEM's `TcpServerUtils`.
- One logical `WIFFI_DEVICE` per MAC address; optional auto-creation.
- Uses `vars[].homematic_name` **unchanged** as the FHEM reading name.
- Exposes `Systeminfo` fields with a `Systeminfo_` prefix.
- Reassembles stream fragments delimited by ETX (`0x03`) or EOT (`0x04`); attempts any remaining JSON on TCP EOF.
- Accepts malformed frames only as errors, never applies partial updates.
- No Node-RED, MQTT intermediary, `notify`, polling, or own periodic timer.

## Planned first test (in a non-production FHEM instance)

Install `FHEM/00_WIFFI_Collector.pm`, `FHEM/10_WIFFI_DEVICE.pm` in FHEM's `FHEM/` directory, and `FHEM/WIFFI/Parser.pm` in its `FHEM/WIFFI/` subdirectory. Then restart test FHEM.

```text
define WIFFI_Collector WIFFI_Collector 9192
attr WIFFI_Collector autocreate 1
attr WIFFI_Collector allowfrom ^192\.168\.5\.(21|22|27|28)$
attr WIFFI_Collector DbLogExclude .*
```

The WiFFI devices need to push TCP/JSON to FHEM's IP address on port 9192. **Do not change all devices at once**; initially test one device and keep the established Node-RED integrations until proven reliable.

Manual definition without auto-create is also possible:

```text
define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector B4:E6:2D:17:DB:07
```

For individual logical devices, consider:

```text
attr WIFFI_PUMP2 event-on-change-reading .*
attr WIFFI_PUMP2 event-on-update-reading Systeminfo_sec_seit_reset
attr WIFFI_PUMP2 DbLogExclude ^Systeminfo_sec_seit_reset$
```

These attributes are examples and should be reviewed against existing logging and watchdog settings. The collector itself does not rename or edit existing MQTT2 devices.

## Recognized sample devices

| Type | MAC | Example readings |
| --- | --- | --- |
| WIFFI-pump 2 | `B4:E6:2D:17:DB:07` | `wiffi_ww_temp`, `wiffi_pump` |
| WEATHERMAN | `E8:DB:84:98:C6:D3` | `w_temperatur`, `w_lux` |
| PULSECOUNTER Strom | `DE:AD:BE:EF:FE:00` | `w_counter1`, `w_power1` |
| PULSECOUNTER Gas | `DE:AD:BE:EF:FE:01` | `w_counter1`, `w_power1` |

## Known limitations / pending work

- Prototype has not been integration-tested on FHEM; real TCP framing must be checked against source bytes and firmware versions.
- No direct device commands or HTTP control implemented.
- No timer-based offline detector: consumers may use the `Systeminfo_sec_seit_reset` reading age.
- Statistics counters are internals on the collector; diagnostic readings and reload/modify/disable behavior need validation.
- Automatic creation produces names from type and trailing MAC octets. Rename FHEM devices as desired.
- Existing MQTT-derived reading names (e.g. `gas_vars_2_value`, `aussentemperatur`) are deliberately **not** retained; dependent `userReadings`, statistics, DOIF, and DbLog queries need migration.
- Systeminfo and numeric readings are preserved as text; the code must not interpret units or coerce implausible counters.

## Testing

```sh
prove -I FHEM t/parser.t
```

## License

This project is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License**, as published by the Free Software Foundation, **either version 2 of the License or (at your option) any later version** (`GPL-2.0-or-later`).

This program is distributed **without any warranty**, including any implied warranty of merchantability or fitness for a particular purpose. See [`LICENSE`](LICENSE) for the full GPLv2 license text.
