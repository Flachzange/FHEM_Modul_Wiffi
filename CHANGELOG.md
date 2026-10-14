# Changelog

## v0.2.1 — 2026-10-14 (working branch, not published)

- Keep explicit/legacy IODev bindings on their named collector, including when disabled. Restored MAC-only definitions without an IODev attribute remain unbound; saved attributes load normally. Interactive creation with exactly one active collector still persists that collector automatically.
- Respect `disable` set by DEFINED/ATTR handlers during autocreate before publishing the first telegram or queued TCP telemetry.
- Reject effective reading-name collisions even when one or both values are JSON null. Null without a collision continues to preserve previous readings and timestamps.
- Correct the IODev test double to match FHEM's direct binding and fallback behavior; add regression/negative controls and synchronize documentation. Both installable modules report v0.2.1 through FVERSION after restart.

No automatic configuration migration. Existing MAC-only devices need their saved IODev attribute; legacy collector-plus-MAC definitions remain supported. These corrections have isolated test coverage and source-backed FHEM checks, without new live hardware or configDB validation.

## v0.2.0 — experimental development baseline (not published)

Native TCP collector and logical WIFFI devices, nonblocking HTTP control, bilingual commandref, native IODev binding, FVERSION and LAST_TELEGRAM diagnostics. Historical live observations and accepted verification limits are recorded in the lifecycle matrix.
