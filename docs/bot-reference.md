# MiniDampen reference

## What it does

Shows a team alive-count, the current dampening percentage, and (in solo shuffle) your
round record, while you are in an arena. Two independently positioned blocks: a top block
for counts or the round record, and a bottom block for dampening. Each is a left legend and
a right value.

## Facts

| Item | Value |
| --- | --- |
| Version | 1.0.0 |
| Author | Verz |
| Interface version (TOC) | 120100 (retail only) |
| Saved variables | MiniDampenDB |
| Slash commands | /minidampen, /mdampen (both open the settings panel) |
| Options location | Game options -> AddOns -> MiniDampen |
| Bundled libraries | MiniFramework |

## How it works

- Runs only in an arena: `IsInInstance` reports `"arena"` and the active match state is
  neither `Inactive` nor unreadable. Leaving the arena unregisters every event and cancels
  the poll ticker; nothing about the addon runs in the open world, a battleground, or a
  raid.
- Polls twice a second for alive/dead (`UnitIsDeadOrGhost` on `player`, `party1`, `party2`,
  `arena1`, `arena2`, `arena3`) and the dampening aura (spell 110310). An opponent counts as
  hidden, not dead, after 1.5 seconds without an `ARENA_OPPONENT_UPDATE` "seen" for it; the
  alive count itself only ever moves on an actual death.
- Solo shuffle round record: the round number starts at 1 on the first `StartUp` after
  entering, increments each `PostRound`, and caps at 6. A round's result comes from
  `C_PvP.GetActiveMatchWinner` where that answers a real faction; otherwise it falls back to
  whichever side had every member die at some point in the round, which reads as unknown
  when a departing opponent leaves that undecidable. The record survives a `/reload` as long
  as the same match is still running.
- Dims Blizzard's own top-center arena widgets while in scope, restoring exactly the alpha
  it found beforehand rather than always setting 1.
- `Enabled = false` keeps the whole feature dormant, including while already in an arena.

### Positioning

- Drag either block with the left mouse button to move it; each has its own saved position.
  Unlock to show both blocks everywhere with sample data for positioning them outside a
  match.
- The "Locked" option prevents dragging (and mouse interaction) on both blocks.

### Display styles

Numbers:

```
  Us vs Opponent      3 vs 3
  Dampening              10%
```

Solo shuffle swaps the top row for the round record:

```
  Rounds              (2)-4/6
  Dampening              30%
```

Lights replaces the value with shape-coded pips (solid = alive/won, small dot = hidden,
flatline = dead/lost, a larger solid pip = the round in progress). Shape carries the
meaning; colour is redundant, for colourblind readability.

## Settings

Single options panel. Panel description reads "Shows a team alive-count, the current
dampening percentage, and your solo shuffle round record in arena."

| Setting | Type | Default | Notes |
| --- | --- | --- | --- |
| Enabled | checkbox | on | Master switch. Off means the gate never opens. |
| Locked | checkbox | on | Unlock to preview both blocks with sample data and drag them. |
| Show counts | checkbox | on | Draws the alive-count block, or the round record in solo shuffle. |
| Show dampening | checkbox | on | Draws the dampening block. |
| Hide Blizzard widgets | checkbox | on | Dims Blizzard's own top-center arena widgets while in scope. |
| Display style | dropdown | Numbers | Numbers or Lights. |
| Font size | slider | 16 | 10-24, applies to both blocks. |

There is no reset-to-defaults button; settings live in MiniDampenDB.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Nothing shows in an arena | Check "Enabled". Unlock the frame briefly to confirm the blocks exist and draw with sample data; if they do, the gate simply has not opened yet (it only evaluates on entering the world or changing zone). |
| Dampening block is missing entirely | The dampening aura was unreadable this session (absent, secret, or not a number); the block hides rather than showing a blank or a zero. |
| Enemy alive count seems to skip an opponent | That opponent has been continuously out of sight for 1.5 seconds and is drawn hidden, not dead; hidden never changes the count itself. |
| Round record shows a `?` for the win count | At least one settled round could not be determined (usually an opponent left before dying), so the total is unknown rather than wrong. |
| Cannot move a block | "Locked" is checked. Unlock it first. |
| Blizzard's own arena widgets are gone | Expected while "Hide Blizzard widgets" is on and you are in scope; they return at alpha 1 on leaving, unless something else had already hidden them, in which case MiniDampen leaves that alone. |
