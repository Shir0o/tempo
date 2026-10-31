# 06: Wear OS Watch Face Complications

Status: completed
Phase: 2 - Wear OS Companion
Dependencies: 04

## Scope
Implement the Watch Face Complication data source services using `androidx.watchface.complications.datasource`.

## Deliverables
- Complication data provider supporting `SHORT_TEXT`, `RANGED_VALUE`, and `SMALL_IMAGE` types.
- Idle state: Renders `[▶️ Track]`; direct tap launches in-app quick sheet.
- Active state: Renders live stopwatch elapsed time via system `TimeDifferenceComplicationText` with `STYLE_STOPWATCH`; tap opens active session.
