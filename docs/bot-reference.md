# MiniDampen reference

## What it does

Shows a team alive-count, the current dampening percentage, and (in solo shuffle) your
round record, while you are in an arena. One draggable display, stacked top to bottom: a
counts row (or the round record), a solo shuffle round line, then a dampening row. Each row
is an optional legend and a value, centred as a unit.

## Facts

| Item | Value |
| --- | --- |
| Version | 1.0.0 |
| Author | Verz |
| Interface version (TOC) | 120100 (retail only) |
| Saved variables | MiniDampenDB |
| Slash commands | /minidampen, /mdampen, /md (see Slash commands below) |
| Options location | Game options -> AddOns -> MiniDampen |
| Bundled libraries | MiniFramework |

## How it works

- Runs only in an arena: `IsInInstance` reports `"arena"` and the active match state is
  neither `Inactive` nor `Complete`. Leaving the arena unregisters every event and cancels
  the poll ticker. A small bootstrap frame stays permanently registered for
  `PLAYER_ENTERING_WORLD`, `ZONE_CHANGED_NEW_AREA`, and `PVP_MATCH_STATE_CHANGED`, everywhere
  including the open world, a battleground, or a raid, purely to re-check whether to open the
  gate; nothing else about the addon runs outside an arena.
- Polls twice a second for alive/dead (`UnitIsDeadOrGhost` on `player`, `party1`, `party2`,
  `arena1`, `arena2`, `arena3`) and the dampening aura (spell 110310). An opponent counts as
  hidden, not dead, 1.5 seconds after an `ARENA_OPPONENT_UPDATE` "unseen" for it, unless a
  "seen" arrives first; the alive count itself only ever moves on an actual death.
- Solo shuffle round record: the round number starts at 1 the first time a round moves from
  `StartUp` to `Engaged` after entering, increments on every later `StartUp` -> `Engaged`
  edge, and caps at 6. A round's result comes from `C_PvP.GetActiveMatchWinner` where that
  answers a real faction and agrees with the corpse latch; otherwise it falls back to
  whichever side had every member die at some point in the round, which reads as unknown
  when a departing opponent leaves that undecidable. The record survives a `/reload` as long
  as the same match is still running.
- Dims Blizzard's own top-center arena widgets while in scope, restoring exactly the alpha
  it found beforehand rather than always setting 1.
- `Enabled = false` keeps the whole feature dormant, including while already in an arena.

### Positioning

- Drag the display with the left mouse button to move it; every row moves together and none can
  be positioned separately. Unlock to show it everywhere with sample data, for positioning it
  outside a match.
- The "Locked" option prevents dragging (and mouse interaction) on the display.
- While unlocked, the counts row alternates every 10 seconds between the alive counts and a
  sample solo shuffle round record, so both can be previewed outside the match type that
  produces them.
- While unlocked every row is drawn regardless, and the dampening row reads a fixed 50%, so
  the display is positioned at the full size it can reach.
- The dampening row hides itself whenever there is nothing readable to show, leaving no gap
  behind it.

### Slash commands

- `/minidampen`, `/mdampen`, `/md`: opens the settings panel.
- `/minidampen lock`, `/minidampen unlock`: the same toggle as the "Locked" checkbox.
- `/minidampen dampening <percent>`: forces the dampening row to a bracket-marked value
  from 0 to 999, out of range clamped rather than rejected, until cleared. Ignored the
  moment a real match is in scope, so a forgotten preview can never be mistaken for what a
  live match is actually reading.
- `/minidampen dampening clear`: clears a forced value.
- `/minidampen debug`: prints every value the rows are built from to chat, in or out
  of combat and in or out of an arena. See the Troubleshooting table below for when this is
  the right tool.

### Display

Each row is centred independently on the display:

```
      3 vs 3
  Dampening  10%
```

Solo shuffle swaps the top row for the round record, with the round line below it. The win
count is drawn green, the loss count red. The round line's own `6/6` reads yellow, apart from
its "Round" label. The record row carries no fraction of its own, since a shuffle is always
six rounds and the win/loss count alone already says enough.

```
  2W - 3L
 Round 6/6
Dampening  30%
```

## Settings

Single options panel. Panel description reads "Shows a team alive-count, the current
dampening percentage, and your solo shuffle round record in arena."

| Setting | Type | Default | Notes |
| --- | --- | --- | --- |
| Enabled | checkbox | on | Master switch. Off means the gate never opens. |
| Locked | checkbox | on | Unlock to preview the display with sample data and drag it. |
| Hide Blizzard | checkbox | on | Dims Blizzard's own top-center arena widgets while in scope. |
| Font size | slider | 16 | 10-24, applies to every row. |
| Font | dropdown | Game Default | The face every row draws in. Lists the client's own faces plus anything another addon has registered with LibSharedMedia-3.0. |
| Outline | dropdown | Outline | None, Outline, or Thick outline. |

There is no reset-to-defaults button; settings live in MiniDampenDB.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Nothing shows in an arena | Check "Enabled". Unlock the frame briefly to confirm the rows exist and draw with sample data. |
| Dampening row is missing entirely | The dampening aura was unreadable this session (absent, secret, or not a number); the row hides rather than showing a blank or a zero. |
| Enemy alive count seems to skip an opponent | Either it has been continuously out of sight for 1.5 seconds, drawn hidden without changing the count, or it disconnected or left and Blizzard cleared its visibility override, drawn the same way but this time subtracted from the count and marked with `?` since it can no longer be confirmed alive. A departed ally is handled the same way. |
| Round record shows a trailing `?` | At least one settled round could not be determined (usually an opponent left before dying), so the total is unknown rather than wrong. |
| Cannot move the display | "Locked" is checked. Unlock it first. |
| Blizzard's own arena widgets are gone | Expected while "Hide Blizzard" is on and you are in scope; they return to whatever alpha MiniDampen found them at on leaving, so they can come back dimmed if another addon had already dimmed them. |
| Need to see the raw values behind any of the above | `/minidampen debug` prints them all to chat, including mid-fight where `/dump` itself is refused. See Slash commands above. |
