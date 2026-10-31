# 10: Deep Link URL Scheme Handler (`timetracker://`)

Status: ready
Phase: 3 - Desktop macOS & Automations
Dependencies: 02, 08

## Scope
Register and handle `timetracker://` deep links on macOS (and Android).

## Deliverables
- URL scheme registration in `Info.plist` (macOS) and `AndroidManifest.xml` (Android).
- Endpoints:
  - `timetracker://start?activity=...&comment=...&tags=...`
  - `timetracker://stop?comment=...`
  - `timetracker://pause`
  - `timetracker://resume`
  - `timetracker://toggle?activity=...`
- Headless execution support: `foreground=false` updates state without stealing window focus.
- Raycast script command and macOS Shortcuts actions.
