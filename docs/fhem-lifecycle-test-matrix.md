# WIFFI Collector — FHEM listener lifecycle verification matrix

**Issue:** [#4](https://github.com/Flachzange/FHEM_Modul_Wiffi/issues/4)  
**Implementation branch:** `feat/tcp-collector-initial`  
**Status:** isolated Perl unit tests pass; **no live FHEM integration run has been performed yet**. Do not mark the items below as verified until checked in a real installation.

## Inspected reference behavior

- FHEM `TcpServerUtils.pm` from `mhop/fhem-mirror` (GitHub `master`, content blob `678e1c5bd363fd7a2e5fc74df14484886862203d`, inspected 2026-10-14): `TcpServer_Open` creates a listener, writes `state=Initialized` before binding, and populates `FD`, `PORT` and `%selectlist` on success. `TcpServer_Close` closes sockets and removes corresponding `%selectlist` entries but does not remove the hash's `SERVERSOCKET` key.
- FHEM `00_MQTT2_SERVER.pm` from the same mirror (file blob `6203d044750faf121b5903197395c89ea003ea4d`): uses `OLDDEF` for modify and offers `set reopen`.
- FHEM module development and command reference: [RenameFn callback semantics](https://wiki.fhem.de/wiki/DevelopmentModuleIntro); [FHEM rename/rereadcfg](https://fhem.de/commandref_modular_DE.html). `RenameFn($new,$old)` runs after FHEM changes the parent's `%defs` name.
- **Not a live environment revision:** file blob IDs are evidence of the inspected source content, not the revision of the user's installed FHEM.

## Real FHEM test information (to fill in)

| Item | Actual value |
| --- | --- |
| FHEM version / SVN revision | NOT RECORDED |
| Perl version | NOT RECORDED |
| Host / platform / configuration backend (file or configDB) | NOT RECORDED |
| Tested WIFFI collector port(s) | NOT RECORDED |
| Firmware/model and observed TCP framing | NOT RECORDED |
| Date of live test | NOT RUN |

## Lifecycle acceptance matrix

All rows are **not yet verified on real FHEM**.

| ID | Scenario | Expected behavior and evidence to record | Live status |
| --- | --- | --- | --- |
| L01 | Initial FHEM startup and listener bind | `LISTENER_STATUS=listening`, port bound once, `LISTENER_ERROR` empty; one listener `%selectlist` key; level-3 success log | Not run |
| L02 | Logical `WIFFI_DEVICE` restored before collector | Existing definition and MAC survive, telemetry starts after collector binds, no extra device created | Not run |
| L03 | Port unavailable at initial define/startup | Definition survives, `LISTENER_STATUS=error`, reason visible in `LISTENER_ERROR` and level-1 log; no stale socket key | Not run |
| L04 | Port freed, `set WIFFI_Collector reopen` | Fresh bind at configured port, status `listening`, error cleared; no duplicate listener | Not run |
| L05 | Reopen attempted repeatedly while port remains occupied | Every failed attempt returns/logs underlying cause, no retries or hidden errors, no stale listener | Not run |
| L06 | `set WIFFI_Collector reopen` while active clients exist | Old socket and all temporary clients close; timeout timers canceled; `CLIENTS_ACTIVE=0`; new port listener accepts telegrams | Not run |
| L07 | `modify WIFFI_Collector 9295` from a test port | Old port closed, new port accepts telemetry, no orphaned `%selectlist` entries or temporary clients; INTERNALS consistent | Not run |
| L08 | Invalid `modify` port | Rejects syntax before closing healthy existing listener | Not run |
| L09 | Modified port occupied | Retains collector definition and new configured port; status `error`, manual `reopen` works once port is released | Not run |
| L10 | `rename` of collector and rename back | Live TCP listener selectlist key and temporary parent references follow name; existing `WIFFI_DEVICE` definitions refer to new collector; no sensor readings or user attributes changed | Not run |
| L11 | `undefine` collector | Listener and all temporary TCP clients removed; no open socket, selectlist entries, or timeout timers | Not run |
| L12 | `rereadcfg` | Current collector removed with sockets/clients and recreated exactly once from configDB/file; logical WIFFI devices reconnect and update | Not run |
| L13 | FHEM restart | Exactly one listener and no stale temporary clients after restart; next valid frame accepted | Not run |
| L14 | Module `reload` | No unexpected duplicate listeners or stale callbacks; document whether explicit `set reopen` is required for current FHEM | Not run |
| L15 | EOF/read error/60-s idle/180-s absolute lifetime | Temporary clients removed and `CLIENTS_ACTIVE` reduced; listener remains healthy, other devices continue receiving | Not run |
| L16 | Known device remains after a failed listener bind | Last sensor readings and attributes unchanged; recovery doesn't duplicate autocreated devices | Not run |

### Suggested staging checks

Use a **test FHEM instance**, not the production collector, for disruptive operations (port conflicts, `modify`, `rereadcfg`, `reload`, rename and restart).

In the FHEM command field:

```text
list WIFFI_Collector
set WIFFI_Collector reopen
{ join(" ", sort grep { /^WIFFI_Collector(?:\.|_)/ } keys %main::selectlist) }
```

From the FHEM host's shell, optionally verify the actual TCP listener using `ss -ltnp` with the test port. Record `LISTENER_STATUS`, `LISTENER_ERROR`, `CLIENTS_ACTIVE`, `CONNECTS`, socket/listener counts, and relevant FHEM log lines before/after each operation. If a temporary client persists, note its `NAME`, `SNAME` and `FD` without publishing real identifiers in repository test fixtures.

### Automated test coverage

`t/lifecycle.t` checks callback registration, bind failure and recovery, repeated failure logging, manual reopen, active-child cleanup, correct selectlist key on `modify` and `rename`, deferred startup rename, and undef/redefine behavior. `t/transport.t` checks connection limits and timeouts. Both use isolated FHEM mocks; they do **not** verify the full core event loop, configDB persistence, actual socket handles or select-list lifetime on the target system.

Issue #9 tracks the separate implementation of the standard FHEM `disable` attribute.
