---
name: Tempo
description: A plain, continuous record of the whole day, midnight to midnight.
colors:
  ink: "#121210"
  ink-muted: "#8A121210"
  ink-faint: "#5C121210"
  panel: "#E9E9E2"
  paper: "#F7F7F4"
  track: "#D2D2C8"
  accent: "#C6F432"
  background: "#0B0B0A"
  surface: "#1B1B18"
  line: "#262622"
  text-muted: "#A8A8A8"
  activity-dusk: "#9AA5C8"
  activity-lilac: "#C3A6FF"
  activity-yolk: "#FFC94A"
  activity-mint: "#5EE6D0"
  activity-lime: "#C6F432"
  activity-rose: "#FF8FB8"
  activity-sky: "#7CC8FF"
  activity-apricot: "#FFB27A"
typography:
  lap-timer:
    fontFamily: "Space Grotesk"
    fontSize: "76px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-0.05em"
    fontFeature: "tnum"
  lap-title:
    fontFamily: "Space Grotesk"
    fontSize: "44px"
    fontWeight: 700
    lineHeight: 0.95
    letterSpacing: "-0.04em"
  screen-title:
    fontFamily: "Space Grotesk"
    fontSize: "32px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.04em"
  title:
    fontFamily: "Space Grotesk"
    fontSize: "18px"
    fontWeight: 700
    letterSpacing: "-0.02em"
  body:
    fontFamily: "Space Grotesk"
    fontSize: "15px"
    fontWeight: 500
  label:
    fontFamily: "Space Grotesk"
    fontSize: "13px"
    fontWeight: 600
  overline:
    fontFamily: "Space Grotesk"
    fontSize: "11px"
    fontWeight: 700
    letterSpacing: "0.08em"
rounded:
  key: "6px"
  swatch: "12px"
  row: "16px"
  block: "20px"
  card: "24px"
  sheet: "28px"
  pill: "999px"
spacing:
  xxs: "4px"
  xs: "6px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "22px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
    height: "52px"
    padding: "0 22px"
  button-outline:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    height: "52px"
    padding: "0 22px"
  activity-block:
    rounded: "{rounded.block}"
    padding: "12px"
    textColor: "{colors.ink}"
  card-light:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "16px"
  card-dark:
    backgroundColor: "{colors.surface}"
    textColor: "#FFFFFF"
    rounded: "{rounded.card}"
  nav-pill-selected:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    height: "32px"
  undo-bar:
    backgroundColor: "{colors.surface}"
    textColor: "#FFFFFF"
    rounded: "{rounded.row}"
    padding: "12px 14px"
  field:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.row}"
    padding: "14px"
---

# Design System: Tempo

## Overview

**Creative North Star: "The Day Ledger"**

Tempo is a plain, honest page of the day. Three materials carry everything: light paper for what is open or being edited, solid colour for time that is known, and diagonal hatching for time that is not yet labeled. Everything sits on near-black, so the day's colours are the brightest thing on screen and the chrome stays out of the way.

The ledger describes, it never judges. There are no scores, goals, streaks, progress rings or celebratory states; a long Sleep block and a short Errands block are drawn with the same weight. Density is calm: big type for the one live number (the open Lap), generous blocks to tap, and quiet secondary text.

The system is flat. Depth comes from tone (paper on black, colour on paper), never from shadow.

**Key Characteristics:**
- Near-black canvas, light paper panels, saturated pastel Activity blocks.
- Hatching always and only means Untracked.
- One accent, lime `#C6F432`, used sparingly for "you are here" and "act now".
- Space Grotesk everywhere, tabular figures for every time and duration.
- Big rounded shapes; pills for actions.
- Chronological 00–24 strips instead of charts that rank or score.

## Colors

A black ledger with paper inserts and a box of pastel markers; one lime highlighter.

### Primary
- **Highlighter Lime** (#C6F432): selected nav pill, open-Lap outline in History, "Undo" text, the dot on "Same as last", switches that are on. Never a large fill except the watch's confirmation flash and the Activity block that happens to be lime.

### Neutral
- **Ledger Ink** (#121210): text on paper, primary buttons on paper, the open Lap's segment in the strip.
- **Ledger Paper** (#E9E9E2): the Lap panel, day cards, bottom sheets, the Drive card.
- **Insert Paper** (#F7F7F4): fields, steppers and chips placed on Ledger Paper; the strip's empty track on paper.
- **Strip Track** (#D2D2C8): empty track and Untracked fill inside strips.
- **Night** (#0B0B0A): app background.
- **Night Card** (#1B1B18): dark cards, rows, the undo bar.
- **Hairline** (#262622): dividers between rows in a dark card; outline of secondary buttons on Night.
- **Fog** (#A8A8A8): secondary text on Night.

### Activity palette
Dusk #9AA5C8, Lilac #C3A6FF, Yolk #FFC94A, Mint #5EE6D0, Lime #C6F432, Rose #FF8FB8, Sky #7CC8FF, Apricot #FFB27A. Ink text sits on all of them. Users may pick other colours; blocks always use ink text.

### Named Rules
**The Hatch Means Unknown Rule.** Diagonal hatching is reserved for Untracked time and the open Lap's panel. Never use it as decoration.

**The One Lime Rule.** Lime marks the current place or the one action that matters now. At most one lime fill per screen besides Activity colours.

**The Paper Is Live Rule.** Light paper surfaces hold what is open or being changed (the Lap, a day in focus, an edit sheet). Settled lists live on Night.

## Typography

**Display, body and label:** Space Grotesk (bundled in `assets/fonts`, never loaded from a CDN), with the system sans as fallback.

**Character:** a grotesk with a slightly mechanical edge; tight negative tracking at large sizes makes numbers read like a stamped ledger.

### Hierarchy
- **Lap timer** (600, 76px, line-height 1, −0.05em, tabular): the open Lap's elapsed time. One per screen.
- **Lap title** (700, 44px, 0.95, −0.04em): "Untracked since 10:06".
- **Screen title** (700, 32px, −0.04em): History, Totals, Settings, Activities.
- **Title** (700, 18px, −0.02em): day headers ("Mon 2 Nov"), card titles.
- **Body** (500, 15px): notes, row text, paragraphs.
- **Label** (600, 13px): metadata, times, buttons at small sizes.
- **Overline** (700, 11px, +0.08em, uppercase): field labels in sheets ("START · PST", "ACTIVITY").

### Named Rules
**The Tabular Time Rule.** Every clock time and duration uses tabular figures so columns of times align and live timers don't jitter.

## Layout

Phone screens use a 16px side gutter with 8px gaps between blocks and rows; cards pad 16px. The Today grid is three equal square columns. History is a two-column timeline: a 48px time gutter and the Record blocks. Every screen that shows a day shows its 00–24 strip, scaled to that Day's real length (21–27h on travel and DST days), with a white tick where the zone changed.

Bottom navigation: Today · History · Totals · Settings. The macOS popover is a 360px column: Lap panel, search, numbered list, undo bar. The watch uses a single centred column on a round face.

## Elevation & Depth

Flat, tonal only. No shadows anywhere. Depth reads from material: paper on Night, colour on paper. The only overlay is the bottom sheet, separated by a 70% black scrim.

### Named Rules
**The No-Shadow Rule.** Do not add box shadows, elevation tints or glows. If something needs to stand forward, put it on paper.

## Shapes

Big, friendly radii. Activity blocks 20px, cards 24px, the Lap panel's lower corners and sheets 28px, rows 16px, colour swatches 12px, key badges 6px. Every button is a full pill. Outline buttons use a 2px ink border on paper or a 1px Hairline border on Night.

## Components

### Buttons
- **Shape:** full pill (999px), 52px tall on phone, 44px in cards, 38px in the popover.
- **Primary:** ink fill, white text, 700 weight. On Night, the primary is white text on Night Card or lime for the single most important action.
- **Outline:** transparent, 2px ink border on paper.
- **Focus:** 2px lime focus ring offset 2px.

### Activity block
- **Style:** square, Activity colour, 20px radius, ink text: today's total top-left (600, 13px), name bottom-left (700, 16px).
- **Behaviour:** tap labels the open Lap. In Activities, a key badge (ink, 22px, 6px radius) shows the Mac number shortcut.

### Lap panel
Hatched Ledger Paper with 28px lower corners: date and logged total, lap title, lap timer, the 00–24 strip, then Split (outline) and "Same as last: <Activity>" (ink primary with an Activity-colour dot).

### Last logged row
Under the Lap panel on Today, while the latest tracked Record ended today: a Night Card row (16px radius) with an Activity-colour bar, overline "LAST LOGGED", and the name with its range and duration, or with its note once it has one. A pill on the right opens the note sheet for that Record: "Add note" (paper fill, ink text) or "Edit note" (Hairline outline). This keeps a one-off note one tap away after the undo bar is gone.

### Day strip
16px tall (10px in the popover), 4–8px radius. Records in Activity colours, Untracked hatched on Strip Track, the open Lap in ink, zone changes marked with a 2px tick. Always has a screen-reader label describing each span.

### Record block (History)
Full-width, Activity colour, 16px radius, name left and duration right, optional note below in 12px, then one chip per tag: 22px pill in 12% ink with an 8px swatch in the tag's colour (3px radius) and the name at 600, 11px. Chips wrap and are display only; the block stays the tap target. Untracked blocks are hatched paper with an ink "What was it?" pill. The open Lap is a Night block with a 2px lime outline and a live timer.

### Edit sheet
Ledger Paper bottom sheet, ordered by how often each part changes. Header: Activity swatch (44px, 14px radius) plus name in 30px, and an outline "Change" pill. Start and end steppers on Insert Paper, each with ± circle buttons, the zone, and which neighbour moves. Note field with People chips, then a Tags row of tag chips ending in "+ New tag". One row of Activity chips (selected = ink fill): the current one, up to three usually started around this time of day, and "All N". Three outline actions (Split…, Merge next, Untrack), then a full-width ink Save.

### Activity picker
Opened from "Change" or "All N" over the edit sheet. Back chevron, "Change Activity" and the times; a search field that opens the keyboard; "Around HH:mm" as three Activity blocks; then every Activity as 48px rows under its Category (Categories in their order, A–Z inside), a check on the current one. Picking stages it on the edit sheet; Save applies.

### Activity filter sheet
Ledger Paper bottom sheet at 70% height, opened from the magnifier in "What was it?". Header "Find an Activity" with the context line "Label 10:06 → now · 25m". Search field on Insert Paper with a clear × and an optional mic. Result rows are 48px tall with a 16px radius: 16px colour swatch (5px radius), name at 600, optional uppercase category, and today's total right-aligned in tabular figures. The empty state names the query and offers Clear and Manage Activities.

### Undo bar
Night Card, 16px radius: "Logged **Errands** 08:42–10:06" and a lime text button "Undo · 3" counting down.

### Navigation
Night background, no top border tint. Selected tab: a lime pill behind the icon, ink icon, white bold label. Unselected: Fog icon and label.

### Watch
Label screen on Night: overline "UNTRACKED · 10:06", the elapsed time, then Activity pills. Confirmation: full lime face with a check, Activity name and range, then the app finishes. Tile: hatched paper with elapsed time and three Activity squares.

## Do's and Don'ts

### Do:
- **Do** use the Activity's colour for its block, strip segment and swatch; ink text on top. Activities in a Category take that Category's colour, so one category reads as one colour.
- **Do** show every time in the zone it was lived in, and both zones when a Record crosses them.
- **Do** keep copy descriptive: "Logged Errands 08:42–10:06", "7h 27m a day", "Untracked · 20m".
- **Do** keep touch targets at least 48dp and give strips and blocks screen-reader labels.

### Don't:
- **Don't** use evaluative or framing words: habit, session, streak, goal, focus, productive, work, most active, score.
- **Don't** add shadows, gradients (other than hatching), glassmorphism or glow.
- **Don't** use hatching for anything but Untracked time and the open Lap.
- **Don't** load fonts from Google Fonts or any CDN; Space Grotesk ships in `assets/fonts`.
- **Don't** rank Activities or show "top" lists outside the watch tile's three slots.
