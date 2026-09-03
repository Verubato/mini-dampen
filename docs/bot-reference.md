# MiniDampen reference

## What it does

Shows a team alive-count, the current dampening percentage, and (in solo shuffle) your
round record, while you are in an arena. One draggable display, stacked top to bottom: a
counts row (or the round record), a solo shuffle round line, then a dampening row. Each row
draws a single string, centred as a unit.

## Facts

| Item | Value |
| --- | --- |
| Version | 1.0.3 |
| Author | Verz |
| Interface version (TOC) | 120100 (retail only) |
| Saved variables | MiniDampenDB |
| Slash commands | /minidampen, /mdampen, /md (see Slash commands below) |
| Options location | Game options -> AddOns -> MiniDampen |
| Bundled libraries | MiniFramework |

## How it works

- Runs only in an arena: `IsInInstance` reports `"arena"` and the active match state is not
  `Inactive`, so the display stays up over the results screen. Leaving the arena unregisters
  every event and cancels the poll ticker. A small bootstrap frame stays permanently registered for
  `PLAYER_ENTERING_WORLD`, `ZONE_CHANGED_NEW_AREA`, and `PVP_MATCH_STATE_CHANGED`, everywhere
  including the open world, a battleground, or a raid, purely to re-check whether to open the
  gate; nothing else about the addon runs outside an arena.
- Polls twice a second for alive/dead (`UnitIsDeadOrGhost` on `player`, `party1`, `party2`,
  `arena1`, `arena2`, `arena3`) and the dampening aura (spell 110310). An opponent counts as
  hidden, not dead, 1.5 seconds after an `ARENA_OPPONENT_UPDATE` "unseen" for it, unless a
  "seen" arrives first; the alive count itself only ever moves on an actual death.
- Solo shuffle round record: the record comes off the two top-center UI widgets the client
  already draws, one carrying `Round: X/Y` and one carrying `Wins: N`. Read on
  `UPDATE_UI_WIDGET`, `PVP_MATCH_STATE_CHANGED`, and `PVP_MATCH_COMPLETE`, and only while the
  client calls the match a solo shuffle. Widgets are matched on the shape of their text rather
  than their id, since ids move between patches, and only widgets Blizzard is actually showing
  are considered. Where two widgets share a shape, the ids the pair was captured under decide;
  where they cannot, the whole reading is refused and the last accepted record stays on screen.
- Every round but the last comes off the widgets: rounds finished is the higher of `round - 1`
  and the wins count, so a win credited before the round number moves is never counted twice and
  the loss count is never negative. The wins widget never takes the final round, since a match
  that completes has no post-round window for it to update in, so that round is booked from the
  server's own scoreboard instead. The board is asked for once, at the first `Complete` reading,
  and read whatever arrives, either right away or once `UPDATE_BATTLEFIELD_SCORE` brings it; it is
  never asked for twice. A board that will not read, or whose whole total does not add up to the
  rounds the widgets say were played, leaves the final round unbooked, and the record holds at the
  five-round figure rather than guessing at the split. A match somebody left part way through never
  reaches the board at all; it counts only the rounds that were actually played.
- Nothing about the record is saved between sessions. After a `/reload` it is read back off the
  widgets, the same way it was read the first time.
- Dims Blizzard's own top-center arena widgets while in scope, restoring exactly the alpha
  it found beforehand rather than always setting 1.
- `Enabled = false` keeps the whole feature dormant, including while already in an arena.

### Positioning

- Drag the display with the left mouse button to move it; every row moves together and none can
  be positioned separately. Click Test in the settings panel to show it everywhere with sample
  data and unlock dragging, for positioning it outside a match.
- The display is only draggable while test mode is on; clicking Test again locks it back down.
- While testing, the counts row alternates every 10 seconds between the alive counts and a
  sample solo shuffle round record, so both can be previewed outside the match type that
  produces them.
- While testing every row is drawn regardless, and the dampening row reads a fixed 50%, so
  the display is positioned at the full size it can reach.
- The dampening row hides itself whenever there is nothing readable to show, leaving no gap
  behind it.

### Slash commands

- `/minidampen`, `/mdampen`, `/md`: opens the settings panel.
- `/minidampen dampening <percent>`: forces the dampening row to a bracket-marked value
  from 0 to 999, out of range clamped rather than rejected, until cleared. Ignored the
  moment a real match is in scope, so a forgotten preview can never be mistaken for what a
  live match is actually reading.
- `/minidampen dampening clear`: clears a forced value.
- `/minidampen debug`: prints every value the rows are built from to chat, in or out
  of combat and in or out of an arena. See the Troubleshooting table below for when this is
  the right tool.
- `/minidampen probe`: prints the raw client data behind those values, in or out of an
  arena.
- `/minidampen log on`, `/minidampen log off`: turns the match log on or off, off by default.
  With it on, every accepted or refused record reading and every match state change is printed
  to chat as it happens, which is the field capture to ask a user for. `/minidampen log` alone
  reports where the setting stands.

### Display

Each row is centred independently on the display:

```
     3 vs 3
Dampening 10%
```

The counts row colours each side by who it is rather than by how many are left: your team's
count always reads green, the enemy's always red.

Solo shuffle swaps the top row for the round record, with the round line below it. The win
count is drawn green, the loss count red. The round line's own `6/6` reads yellow, apart from
its "Round" label. The record row carries no fraction of its own, since a shuffle is always
six rounds and the win/loss count alone already says enough.

```
  2W - 3L
 Round 6/6
Dampening 30%
```

## Settings

Single options panel. Panel description reads "Shows a team alive-count, the current
dampening percentage, and your solo shuffle round record in arena."

| Setting | Type | Default | Notes |
| --- | --- | --- | --- |
| Enabled | checkbox | on | Master switch. Off means the gate never opens. |
| Hide Blizzard | checkbox | on | Dims Blizzard's own top-center arena widgets while in scope. |
| Font size | slider | 16 | 10-24, applies to every row. |
| Font | dropdown | Game Default | The face every row draws in. Lists the client's own faces plus anything another addon has registered with LibSharedMedia-3.0. |
| Outline | dropdown | Outline | None, Outline, or Thick outline. |

The panel header also carries two buttons: Test toggles test mode (sample data, draggable),
and Reset to Defaults restores every setting above and the display's position, after a
confirmation prompt.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Nothing shows in an arena | Check "Enabled". Click Test briefly to confirm the rows exist and draw with sample data. |
| Dampening row is missing entirely | The dampening aura was unreadable this session (absent, secret, or not a number); the row hides rather than showing a blank or a zero. |
| Enemy alive count seems to skip an opponent | Either it has been continuously out of sight for 1.5 seconds, drawn hidden without changing the count, or it disconnected or left and Blizzard cleared its visibility override, drawn the same way but this time subtracted from the count and marked with `?` since it can no longer be confirmed alive. A departed ally is handled the same way. |
| Round record is missing in a solo shuffle | Either the client has not called the match a shuffle yet, or the two widgets could not be read. `/minidampen debug` shows `isSoloShuffle`, `rawIsSoloShuffle`, and a `record` line naming the reading or the reason it was refused, with the text of every live widget it saw. Both recover on their own once the client answers. |
| Record is stuck one round short at the results screen | The board refused to book the final round, most often because it had not yet been credited when it was read. `/minidampen debug` shows `settled` and `asked` on the `isSoloShuffle=` line: `asked=true settled=false` means the request went out but nothing usable came back, and the record holds at the five-round figure rather than guessing at the split. |
| Cannot move the display | Test mode is off. Click Test in the settings panel first. |
| Blizzard's own arena widgets are gone | Expected while "Hide Blizzard" is on and you are in scope; they return to whatever alpha MiniDampen found them at on leaving, so they can come back dimmed if another addon had already dimmed them. |
| Need to see the raw values behind any of the above | `/minidampen debug` prints them all to chat, including mid-fight where `/dump` itself is refused. See Slash commands above. |
