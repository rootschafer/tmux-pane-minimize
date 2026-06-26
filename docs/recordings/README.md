# Recording shot-scripts

Silent screen-recording scripts for the README's demo gifs/videos — **no voiceover**. Each
file is a shot list you can follow on camera: it says exactly what to do, the text to overlay
on screen for each step, and what to highlight/circle. Anything under ~5s is meant to be an
inline looping gif and just has a `TODO(gif…)` note in the README instead of a file here;
these files are the longer ones.

## Conventions used in these scripts

- **SETUP** — the tmux state to start from (run before recording; not shown on camera).
- **`[t=…]`** — approximate timestamp / beat.
- **DO** — the action to perform on camera (keys, mouse).
- **SCREEN** — on-screen caption text to overlay in post for that beat (keep it ≤ ~6 words;
  bottom-center unless noted).
- **HIGHLIGHT** — what to circle/box/arrow (post-production annotation).
- Keep the terminal font large (≥ 18pt), the window ~120×35, and pause ~1s on each end state
  so the gif/video reads. Loop gifs; let videos rest 1s on the final frame.

## Recommended capture settings
- Use the [Recommended configuration](../../README.md#recommended-configuration) so the pill
  indicator + borders match the README.
- A clean shell prompt (no async git status spew) so the focus is the panes, not the text.
- Record at 2× then slow key-press beats in post if needed.

## Files
- `00-hero.md` — the headline demo (top of README).
- `02-minimize-others.md` — the "minimize others" focus toggle.
- `03-per-group-width.md` — per-group minimized width via side-border drag.
