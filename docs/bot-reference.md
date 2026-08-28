# MiniDampen - bot reference

Version 1.0.0. Interface version: 120100 (retail only). Saved variables:
MiniDampenDB (account-wide).

## What it does

Nothing visible yet. This is the scaffold for an arena and solo shuffle
readout: a team alive-count ("3 vs 3"), the dampening percentage, and in
solo shuffle a round record. The display itself has not been built.

## How it works

- Initialises MiniDampenDB from a defaults table on login, then swaps to a
  PLAYER_ENTERING_WORLD handler.
- The PLAYER_ENTERING_WORLD handler is a stub: it checks the Enabled flag
  and returns. No frames are created and nothing is shown.

## Settings

No options UI and no slash commands. The saved defaults describe the shape
the real display will use once it exists:

| Key | Default | Meaning |
|---|---|---|
| Enabled | true | Whether the addon is active. |
| DisplayStyle | "Numbers" | "Numbers" or "Lights"; how the alive-count will be drawn. |
| CountsAnchor | { point = "CENTER", x = 0, y = 200 } | Saved position of the alive-count block. |
| DampeningAnchor | { point = "CENTER", x = 0, y = 180 } | Saved position of the dampening block. |

## Troubleshooting

- "It doesn't show anything": expected. The display has not been
  implemented yet.
