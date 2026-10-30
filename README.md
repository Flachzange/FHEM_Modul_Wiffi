# FHEM WIFFI Collector

Direkte FHEM-Anbindung für klassische WIFFI-Geräte mit kompatiblem TCP/JSON-Telegrammformat, ohne Node-RED oder MQTT. Beispiele sind **WIFFI-pump 2, WEATHERMAN und PULSECOUNTER2-LAN**. Ein Collector empfängt die Daten; jedes WIFFI erhält ein eigenes FHEM-Gerät.

Eine frühere Lösung zur WIFFI-Anbindung in FHEM war [Log2Syslog](https://wiki.fhem.de/wiki/Log2Syslog). Der WIFFI Collector bündelt TCP-Empfang, JSON-Auswertung und die Zuordnung zu eigenen FHEM-Geräten.

Geräteinformationen, Firmware und Anleitungen: [STALL.biz](https://www.stall.biz/).

**Stand: v0.2.1, experimentell.**

## Installation und Einrichtung

1. [00_WIFFI_Collector.pm](FHEM/00_WIFFI_Collector.pm) und [10_WIFFI_DEVICE.pm](FHEM/10_WIFFI_DEVICE.pm) in das Verzeichnis `FHEM/` der FHEM-Installation kopieren.
2. FHEM neu starten. Bei Updates immer beide Dateien ersetzen.
3. Collector anlegen und die WIFFI-Geräte für TCP/JSON-Versand an die FHEM-IP und den gewählten Port konfigurieren:

```text
define WIFFI_Collector WIFFI_Collector 9195
attr WIFFI_Collector allowfrom ^192\.0\.2\.(10|11)$
attr WIFFI_Collector autocreate 1
```

Die IP-Adressen sind Beispiele und müssen durch die eigenen WIFFI-Adressen ersetzt werden. Nur vertrauenswürdige Absender freigeben.

Beim ersten Telegramm entstehen Geräte mit Namen wie `WIFFI_020000000001`. Sie können anschließend umbenannt werden. Mit `save` die angelegten Geräte und Attribute speichern.

Alternativ ein Gerät manuell anlegen (Beispiel-MAC ersetzen):

```text
define WIFFI_PUMP2 WIFFI_DEVICE WIFFI_Collector 02:00:00:00:00:01
save
```

Die Collector-Zuordnung wird als `IODev`-Attribut gespeichert. MAC-Adressen sind auch ohne Doppelpunkte möglich. Bei einer manuellen MAC-only-Anlage wird genau ein vorhandener aktiver Collector automatisch gewählt; bei mehreren ist `IODev` explizit zu setzen.

## Befehle und Attribute

Die gerätespezifischen Befehle erscheinen nach dem ersten gültigen Telegramm.

| Gerät | `set`-Befehl | Funktion |
| --- | --- | --- |
| WIFFI-pump 2 | `on`, `off`, `on-for-timer <Sekunden>` | Pumpe schalten; Timer 1–3600 Sekunden |
| PULSECOUNTER | `counter <Kanal> <Wert>` | Kanal 1–4 setzen; Wert 0–999999, Dezimalpunkt |
| WIFFI-pump, PULSECOUNTER, WEATHERMAN | `reset` | Gerät neu starten, kein Werksreset |
| Alle WIFFI-Geräte | `httpGet <relativer Pfad>` | Expertenbefehl; kann die Gerätekonfiguration ändern |
| Collector | `reopen` | TCP-Empfang schließen und erneut öffnen |

HTTP-Befehle verwenden den zuletzt empfangenen TCP-Absender. Erst neue Telemetrie bestätigt Änderungen; HTTP-Antworten erzeugen keine Messwert-Updates. In der Gerätedetailansicht führt **WIFFI Webinterface** zur Geräteoberfläche.

| Attribut | Bedeutung |
| --- | --- |
| `IODev <Collector>` | Collector einem WIFFI_DEVICE zuordnen |
| `disable 1` / `disable 0` | Collector oder einzelnes Gerät deaktivieren/aktivieren; ein deaktivierter Collector allein sperrt keine direkten HTTP-Befehle |
| `stripReadingPrefix 1` | Am WIFFI_DEVICE ein führendes `w_` aus Reading-Namen entfernen |

## Readings und Diagnose

Reading-Namen entsprechen `vars[].homematic_name`; Systeminformationen beginnen mit `Systeminfo_`. Autocreate setzt Änderungsereignisse und einen Update-Heartbeat für `Systeminfo_sec_seit_reset`; der Heartbeat ist vom DbLog ausgeschlossen. Unveränderte Messwerte erzeugen dadurch keine regelmäßigen Diagramm-/Datenbankeinträge. Die Attribute bleiben anpassbar.

`FVERSION` zeigt die Modulversion, `LAST_TELEGRAM` den letzten Empfang. Empfangsprobleme stehen im FHEM-Log und in den Collector-INTERNALS, insbesondere `LISTENER_STATUS`, `LISTENER_ERROR` und `FRAMES_ERROR`. Es gibt keine automatische Offline-Erkennung.

Bestehende Collector-plus-MAC-Definitionen bleiben unterstützt. Beim Wechsel von MQTT müssen abhängige DOIFs, Plots und Readings angepasst werden; das Modul migriert sie nicht automatisch.

## Weitere Informationen

- Vollständige Befehlsreferenz in FHEM: `help WIFFI_Collector` und `help WIFFI_DEVICE`.
- [Änderungen](CHANGELOG.md), [Prüfstand und bekannte Grenzen](docs/fhem-lifecycle-test-matrix.md), [Framework-Audit](docs/fhem-framework-audit.md), [Release-Prüfung](docs/release-readiness.md).
- Lizenz: [GPL-2.0-or-later](LICENSE).

## Entwicklung

[AGENTS.md](AGENTS.md) ist eine synchronisierte Kopie aus
[Flachzange/FHEM_Agent_Rules](https://github.com/Flachzange/FHEM_Agent_Rules).
Vor Arbeiten zusätzlich [AGENTS-WIFFI.md](AGENTS-WIFFI.md) lesen.
Generische Erkenntnisse zentral vorschlagen; projektspezifische Regeln im Zusatz pflegen.
Die übernommene Revision steht in [.github/agent-rules.json](.github/agent-rules.json).
Der CI-Check verifiziert Quelle und Bytegleichheit; die Pflichtprüfung muss zusätzlich
in den Repository-Einstellungen aktiviert werden.
