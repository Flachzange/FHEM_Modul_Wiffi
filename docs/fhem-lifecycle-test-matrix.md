# WIFFI Collector — FHEM listener lifecycle verification matrix

**Issue:** [#4](https://github.com/Flachzange/FHEM_Modul_Wiffi/issues/4)  
**Implementation branch:** `feat/tcp-collector-initial`  
**Status (2026-10-14):** latest branch CI passes (11 test files / 1063 tests, including metadata, telegram-INTERNAL and native IODev binding regression checks); this is still an isolated test suite, not a live-FHEM validation of FVERSION. Real-FHEM telemetry, `reopen`, regular restart with configDB restore and `disable`/`enable` of both module types have been confirmed. **Maintainer decision: the remaining comprehensive L01–L18/D01–D08 staging/failure-injection tests will not be performed.** Historical unexecuted rows remain marked *Not run*, not *PASS*. This matrix is a record of verified behavior and consciously unverified scenarios, **not a pending test plan**. Investigate these paths only if a concrete defect is observed later.

## Inspected reference behavior

- FHEM `TcpServerUtils.pm` from `mhop/fhem-mirror` (GitHub `master`, content blob `678e1c5bd363fd7a2e5fc74df14484886862203d`, inspected 2026-10-14): `TcpServer_Open` creates a listener, writes `state=Initialized` before binding, and populates `FD`, `PORT` and `%selectlist` on success. `TcpServer_Close` closes sockets and removes corresponding `%selectlist` entries but does not remove the hash's `SERVERSOCKET` key.
- FHEM `00_MQTT2_SERVER.pm` from the same mirror (file blob `6203d044750faf121b5903197395c89ea003ea4d`): uses `OLDDEF` for modify and offers `set reopen`.
- FHEM module development and command reference: [RenameFn callback semantics](https://wiki.fhem.de/wiki/DevelopmentModuleIntro); [FHEM rename/rereadcfg](https://fhem.de/commandref_modular_DE.html). `RenameFn($new,$old)` runs after FHEM changes the parent's `%defs` name.
- FHEM `fhem.pl` from `mhop/fhem-mirror` (inspected 2026-10-14): `CommandDelete` returns immediately and **retains `%defs` and `%selectlist`** when `UndefFn` or `DeleteFn` returns an error. `CommandModify` invokes the module `DefFn` with `OLDDEF` set and restores the old `DEF` if it reports an error. These are the framework contracts for cleanup refusal handling, not guarantees of OS-level socket closure.
- **Not a live environment revision:** file blob IDs are evidence of the inspected source content, not the revision of the user's installed FHEM.

## Observed live FHEM / physical WIFFI functionality (not a lifecycle sign-off)

These observations were recorded during project development; they do not prove untested socket, `rereadcfg`, `reload`, `modify` or failure-injection scenarios. Later normal-operation confirmations are documented separately below.

| Date | Scope | Observed result | Not established |
| --- | --- | --- | --- |
| 2026-10-10 | WIFFI-pump 2, real FHEM | TCP reception, automatic logical-device creation and updated telemetry; five connections/five accepted frames reported in the field test | Listener error recovery, concurrency, restart or long-term stability |
| 2026-10-11 | WEATHERMAN, real FHEM | Valid telemetry/readings observed via collector | All firmware variants or lifecycle operations |
| 2026-10-11 | PULSECOUNTER2-LAN (`counter_LAN41`), real FHEM | TCP-derived counters/readings and automatic creation observed on one physical device | Other PULSECOUNTER units, sustained reliability or overall error-free operation |
| 2026-10-11 | WIFFI-pump 2 (`wiffi_pump2_110`), actual hardware | FHEMWEB `on` and `off` physically switched pump; subsequent `wiffi_pump` readings changed accordingly; `on-for-timer 30` started pump | Precise timer expiration not independently timed; generic `httpGet` and HTTP commands on other device types not field-tested |

## Live FHEM evidence and waiver of dedicated staging

| Item | Actual value |
| --- | --- |
| FHEM version / SVN revision | Latest Revision **31780**; `fhem.pl` **31759**; `01_FHEMWEB.pm` **31693**; `TcpServerUtils.pm` **31027**; `HttpUtils.pm` **31632**; `configDB.pm` **30792** (maintainer `version` output, 2026-10-14) |
| Perl version | **5.40.5** (verified by maintainer in FHEM) |
| Host / platform / configuration backend (file or configDB) | **configDB active**, explicitly confirmed; host/platform details not recorded |
| Tested WIFFI collector port(s) | **9195**; listener `WIFFI_Collector.9195` observed in `%selectlist` |
| Firmware/model and observed TCP framing | WIFFI-pump 2 `wiffi_pump2_110`, PULSECOUNTER2-LAN `counter_LAN41`, WEATHERMAN observed; no complete per-device framing characterization in the live test record |
| Dedicated lifecycle staging run | **Not performed and no longer planned (maintainer decision, 2026-10-14)**; targeted normal-operation checks recorded on that date |

## Lifecycle acceptance matrix

The **complete** lifecycle scenarios remain unverified in staging, and executing them has been **explicitly waived** by the maintainer. The following *partial live evidence* does not establish all conditions of the corresponding acceptance rows:

- **Listener/normal traffic:** `LISTENER_STATUS=listening`, `LISTENER_ERROR` empty, `WIFFI_Collector.9195` present once in `%selectlist`; at one snapshot `CONNECTS=243`, `FRAMES_OK=243`, `FRAMES_ERROR=0`, `CLIENTS_ACTIVE=0`, `CLIENTS_PEAK=2`.
- **Manual `set WIFFI_Collector reopen`:** maintainer confirms it worked and telemetry/listener remained usable afterward. Does not establish simultaneous-active-client cleanup or a failed-bind recovery scenario.
- **Normal FHEM restart with configDB:** maintainer confirms modules/devices restored and the collector resumed listening automatically on 9195. Does not prove precise restore ordering, FD/timer teardown or duplicate detection under failure.
- **`disable`/`enable` on both types:** maintainer confirms successful toggling of `WIFFI_Collector` and `WIFFI_DEVICE`. Does not establish pending-HTTP cancellation, disabled startup, deleteattr, failed bind or detailed socket/selectlist snapshots.
- **User-visible WIFFI controls and FHEMWEB:** pump on/off and timer startup, PULSECOUNTER `counter`, `reset` and detail-only webinterface link confirmed by maintainer. Reset type/arguments and before/after uptime values were not separately recorded.

| ID | Scenario | Expected behavior and evidence to record | Live status |
| --- | --- | --- | --- |
| L01 | Initial FHEM startup and listener bind | `LISTENER_STATUS=listening`, port bound once, `LISTENER_ERROR` empty; one listener `%selectlist` key; level-3 success log | **Partial live:** normal restart/bind and a single listener key confirmed; precise per-startup log/socket evidence missing |
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
| L13 | FHEM restart | Exactly one listener and no stale temporary clients after restart; next valid frame accepted | **Partial live:** successful configDB restore, listener rebinding and subsequent operation confirmed; complete client/FD evidence missing |
| L14 | Module `reload` | No unexpected duplicate listeners or stale callbacks; document whether explicit `set reopen` is required for current FHEM | Not run |
| L15 | EOF/read error/60-s idle/180-s absolute lifetime | Temporary clients removed and `CLIENTS_ACTIVE` reduced; `CLIENTS_TIMEOUT` increments on idle/lifetime expiry, whereas `FRAMES_ERROR` increments only for unfinished non-whitespace data discarded on expiry; listener remains healthy | Not run |
| L16 | Known device remains after a failed listener bind | Last sensor readings and attributes unchanged; recovery doesn't duplicate autocreated devices | Not run |
| L17 | Reentrant DOIF/notify triggers `set reopen`, `modify`, `delete` or `rename` during a batched TCP read | Old connection discards queued frames on close/modify/delete; stable hash identity allows rename; no stale reading publication or unexpected frame errors | Not run |
| L18 | Temporary client `UndefFn`/`DeleteFn` refuses deletion during collector `reopen`, `modify` or `undefine` (failure injection/staging only) | Old listener is closed, no new listener bound, `LISTENER_STATUS=error`, level-1 log and `LISTENER_ERROR` identify the child; surviving open child sockets remain counted in `CLIENTS_ACTIVE`; `modify` returns error and preserves previous definition/port, `undefine` returns error and retains collector; manual recovery after refusal is removed | Not run |

### Historical optional diagnostic procedures (not scheduled)

These commands are retained as diagnostic references, **not as a request or plan to carry out the waived tests**. If a future real defect ever justifies disruptive reproduction, use a **test FHEM instance**, not the production collector, for port conflicts, `modify`, `rereadcfg`, `reload`, rename and restart.

In the FHEM command field:

```text
list WIFFI_Collector
set WIFFI_Collector reopen
{ join(" ", sort grep { /^WIFFI_Collector(?:\.|_)/ } keys %main::selectlist) }
```

From the FHEM host's shell, optionally verify the actual TCP listener using `ss -ltnp` with the test port. Record `LISTENER_STATUS`, `LISTENER_ERROR`, `CLIENTS_ACTIVE`, `CONNECTS`, socket/listener counts, and relevant FHEM log lines before/after each operation. If a temporary client persists, note its `NAME`, `SNAME` and `FD` without publishing real identifiers in repository test fixtures.

### Automated test coverage

`t/reentrancy.t` additionally injects synchronous Reading and DEFINED/ATTR callback actions (listener reopen/modify/delete, client and logical device delete/modify, plus identity-preserving renames). The tests use real WIFFI modules and FHEM contract doubles; actual DOIF/notify behavior, socket lifecycle, and configDB still need validation. 

`t/lifecycle.t` checks callback registration, bind failure and recovery, repeated failure logging, manual reopen, active-child cleanup, failed `CommandDelete` / partial `DeleteFn` cleanup with no false listener recovery, manual retry, correct selectlist key on `modify` and `rename`, deferred startup rename, undef/redefine behavior, and the isolated collector-disable contract (including startup and failed re-enable). `t/transport.t` checks connection limits and timeouts. All eight tests run under isolated FHEM contract doubles, not a full FHEM runtime; they do **not** establish configDB persistence, physical socket handles or select-list lifetime on the target system.

## FHEM `disable` integration acceptance (Issue #9)

The `disable` contract has isolated regression tests in `t/lifecycle.t`, `t/autocreate.t` and `t/set.t`. The maintainer additionally confirms successful real-FHEM `disable`/`enable` of both module types (2026-10-14). **The detailed D01–D08 checks were not completed and will not be scheduled**; the confirmations are partial evidence only.

| ID | Scenario | Expected live observation | Live status |
| --- | --- | --- | --- |
| D01 | FHEM startup with `attr WIFFI_Collector disable 1` already saved | Definition restored; no TCP bind, selectlist listener or accepted child | Not run |
| D02 | `disable 1` while listener and TCP clients are active | Listener socket and temporary clients removed; timeout timers canceled; no subsequent telemetry; logical-device readings retained | **Partial live:** collector disable/enable worked; active-client/FD/timer details not checked |
| D03 | `disable 0`, repeated toggles, `deleteattr disable` | Port opened exactly once, TCP messages resume; no duplicate listener | **Partial live:** enable worked; repeated toggles, `deleteattr` and exact listener count at transition unrecorded |
| D04 | `set ... reopen` while Collector disabled; enable with occupied TCP port | Reopen refused while disabled; failed bind diagnosed; manual recovery possible after releasing port | Not run |
| D05 | `modify` and `rereadcfg` while Collector disabled | No premature bind; modified configured port respected when enabled; no stale clients | Not run |
| D06 | Disable a known WIFFI_DEVICE while another device continues | Disabled device readings, heartbeat and type remain unchanged; enabled device keeps updating; no duplicate autocreate | **Partial live:** device disable/enable worked; other-device/reading-timestamp details not separately recorded |
| D07 | Disabled WIFFI_DEVICE HTTP control and outstanding asynchronous request | All commands refused, in-flight request canceled, late callback inert; `disable 0` restores control | Not run |
| D08 | `deleteattr <WIFFI_DEVICE> disable` and re-enable after FHEM restart | Next valid telegram updates original device; no stale heartbeat/peer or extra device | Not run |

These unexecuted checks are retained solely to describe residual risks; **there is no pending staging acceptance task**. If future troubleshooting requires reproducing an observed failure, use a staging FHEM setup and record relevant FHEM version, sockets, logs and results. Do not mark rows verified based on isolated Perl tests.

