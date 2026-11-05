# Tempo — Google Play store listing assets

Rendered from the app's own design tokens (`DESIGN.md`) and the real screenshots in
`screenshots/`, so the listing matches the product. Regenerate with:

```bash
./store-listing/render.sh
```

Requires Google Chrome (headless) and Python 3 with Pillow.

## Upload map

| File | Play Console slot | Spec |
| --- | --- | --- |
| `icon-512.png` | App icon | 512×512, 32-bit PNG |
| `feature-graphic-1024x500.png` | Feature graphic | 1024×500, PNG, no alpha |
| `wear-screenshot-1-quick-log-768.png` | Wear OS screenshots | 768×768, 1:1 |
| `wear-screenshot-2-label-768.png` | Wear OS screenshots | 768×768, 1:1 |
| `phone-screenshot-1-1080x1920.png` | Phone screenshots | 1080×1920, 9:16 |
| `phone-screenshot-2-1080x1920.png` | Phone screenshots | 1080×1920, 9:16 |

The **Wear OS form factor setup** needs at least one Wear OS screenshot; both are
provided. The full listing (feature graphic, phone screenshots) can wait until you
publish beyond internal testing.

## Short description (80 char max)

```
A plain record of your whole day. Label it later.
```

## Full description (4000 char max)

```
Tempo is a private, offline-first record of your whole day, from local midnight to local midnight. An open Lap always runs, and you label what it was after the fact. Labeling closes the Lap as a Record and opens the next one in the same instant, so every moment belongs to exactly one Record or the open Lap.

NO GOALS, NO STREAKS, NO JUDGMENT

Tempo describes how a day was spent. It does not score it, set targets, or ask you to be more productive.

LABEL AFTER THE FACT

Tap an Activity to close the open Lap and start the next one. Not sure what something was? Split marks a boundary now and leaves an Untracked Record you can label later.

UNDO COSTS NOTHING

Every label or Split has a 3-second undo window that restores the Lap exactly as it was.

CORRECT THE PAST

Drag the edge between two Records, split or merge neighbours, or relabel any Record. Edits that would create a gap or overlap are refused.

MIDNIGHT AND TRAVEL STAY HONEST

Anything crossing local midnight is split at 00:00 in the zone you were in, including sleep and the open Lap. Every Record stores the time zone it started and ended in, so a 6-hour flight is always 6h and past Records keep the clock times they were lived in.

COLOR BLOCKS DASHBOARD

A hatched panel for the open Lap and its elapsed time, a midnight-to-midnight strip of the day, Split and "Same as last" actions, and a grid of Activity blocks in their own colours.

PIXEL WATCH (WEAR OS)

A watch-face complication shows the open Lap's elapsed time, anchored on its start instant with no polling. The tile offers your three most-used Activities. Labeling from the watch gives haptic and visual confirmation and immediately returns to the watch face, so notifications are never suppressed.

PRIVATE BY DEFAULT

Your records live in a local SQLite database on your device. No account is required. Google Drive export is optional and private to your own Drive. A local MCP server lets Claude or Gemini read your own data, with deterministic PII redaction for contact names, emails, phone numbers, and URLs.

OPEN EXPORT

Continuous CSV export in the Simple Time Tracker schema, written atomically, for tools like BNPB. Times stay in each Record's own zone.

Tempo is for Android, macOS, and Wear OS.
```
