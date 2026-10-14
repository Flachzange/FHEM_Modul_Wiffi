# WIFFI Collector release verification

Use this checklist when preparing a **new release**; it is not part of the FHEM user-facing commandref. Record the actual test environment and outcomes in the release PR or issue rather than claiming coverage based only on mock tests.

## Module and documentation checks

- Confirm the two installed module files match the intended Git commit and their syntax checks succeed with the FHEM Perl environment and dependencies.
- Run the repository Perl suite using the command in `.github/workflows/perl-tests.yml`. The suite includes `t/commandref.t` to check both languages, matching anchors, section structure and HTML tag pairing.
- For the target FHEM revision, validate both commandref blocks using FHEM's own generator from the FHEM installation directory:
  ```text
  perl contrib/commandref_join.pl FHEM/00_WIFFI_Collector.pm
  perl contrib/commandref_join.pl FHEM/10_WIFFI_DEVICE.pm
  ```
  Review the rendered English and German help entries, including UTF-8/HTML entities and command anchors. This checks FHEM's actual documentation tool, not just our lightweight syntax test.
- Compare `define`, `set`, `attr`, HTTP command limitations and auto-creation behavior against current source and both commandref languages. Keep the commandref free of engineering TODOs and development/test-status notes.
- Check README, `AGENTS.md`, `AGENTS-WIFFI.md`, embedded GPL notices, LICENSE, release notes and any version/META declarations (if added). No version bump is required solely for documentation.

## Real FHEM and WIFFI behavior

- Record the actual FHEM revision, Perl version, runtime platform, active configuration backend (file or configDB), WIFFI firmware and collector port.
- Validate module load order, `define`, `modify`, `rename`, `rereadcfg`, `reload`, `undefine`, restart, failure/recovery, sockets and `%selectlist` cleanup as applicable. Use the scenario-specific [lifecycle matrix](fhem-lifecycle-test-matrix.md).
- Exercise separate collector and logical-device `disable` / re-enable / `deleteattr disable` on a staging FHEM system. Confirm listener closure, peer cleanup, unrelated device reception, HTTP cancellation, disabled startup and error reporting.
- Test live TCP telemetry/heartbeat/autocreate with relevant physical WIFFI device types. Confirm that the original `homematic_name` readings and chosen FHEM event/DbLog attributes behave as expected.
- Test WIFFI-pump HTTP `on`, `off`, `on-for-timer` and intentional expert `httpGet` commands only on authorized, noncritical hardware. Confirm subsequent telemetry reflects physical results; an HTTP success alone does not confirm relay state.
- Review any changed FHEM command/DOIF/notify, SVG, userReadings, statistics, MQTT/Node-RED, DbLog and historical data references before migrating existing installations. Do not rewrite existing device configuration automatically.

## Artifact preparation

- Generate releases from a known commit and confirm module byte equality with the repository, deterministic archive layout, checksums and readable LICENSE/documentation.
- Note what changed, how to upgrade, relevant behavior differences, evidence used, and any limitations in release notes. Merge or publish only with the maintainer's explicit approval.

Reference: [FHEM documentation guidelines](https://wiki.fhem.de/wiki/Guidelines_zur_Dokumentation).
