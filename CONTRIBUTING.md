# Contributing / Development

Thanks for hacking on tmux-pane-minimize. This file covers the repo layout, how to run
the tests, and the techniques that make developing a tmux plugin tractable.

## Repo layout

```
pane-minimize.tmux       TPM entry point: reads @minimize-* options, binds keys, sets hooks
engine-rs/               the Rust port of the pure layer — binary tmux-min-transform (THE engine)
scripts/transform.sh     bash equivalent of the engine, kept ONLY as the differential test oracle
scripts/tmux-min.sh      the tmux-IO layer — shells out to tmux-min-transform; subcommands + apply
scripts/marker.sh        the border-marker builder (build_marker -> MARKER_FMT)
STATE.md                 the single state model — every @minimize-* / @minimize_* option
tests/                   the test harness (see tests/README.md)
.github/workflows/ci.yml CI: macOS + ubuntu
```

The engine is split along its one real seam: the pure layout math vs the tmux IO. The pure
math is `transform()` — a **pure function** of `(layout, MINSET, SAVEDW, WPANE, WVAL, MINH)`
plus the `MIN_H/MIN_W/ABS_MIN_H/BORDER_POS` knobs — with no tmux, time, or randomness, which
is what makes the bulk of the tests exhaustive and deterministic. It now lives in Rust
(`engine-rs/`, binary **`tmux-min-transform`**); `scripts/transform.sh` is a byte-for-byte
bash equivalent kept ONLY as the test oracle the Rust engine is validated against (see
`tests/diff_test.sh`). `scripts/tmux-min.sh` is the thin orchestration layer: everything that
touches tmux (toggle/peek/dashboard/save-state/…) reads state, calls the binary via its
`_transform()` wrapper, and applies the result with `select-layout`. It locates the binary via
`TMUX_MIN_TRANSFORM`, then `PATH`, then the `engine-rs/target/release` dev build, and hard-fails
if none is found (there is no bash fallback — `transform.sh` is the oracle only).

Build the engine with `cargo build --release` in `engine-rs/` (the test harnesses do this for
you). It has zero dependencies, so the build is fast and offline.

See **STATE.md** for the option model (the `@minimize-*` config vs `@minimize_*` runtime
convention, and each option's scope/writer/reader/lifecycle).

## Hard constraint: macOS bash 3.2

macOS ships **bash 3.2**, and this plugin is sourced on machines that run it. So:

- No associative arrays; no `local a= b="${arr[$a]}"` on one line under `set -u`
  (split into separate `local` lines).
- POSIX `awk`/`sort`/`tr` only (no GNU-only flags).
- The test harness runs everything through `/bin/bash` (which is 3.2 on macOS) to
  enforce this — don't rely on your interactive bash/zsh.

## Running the tests

```sh
tests/run.sh            # bash -n + shellcheck-free syntax + offline + live
QUICK=1 tests/run.sh    # offline: skip the WPANE/WVAL inner sweep (fast iteration)
VERBOSE=1 tests/run.sh  # also print every passing assertion

# individual suites
/bin/bash tests/transform_props.sh     # offline property suite (~11k cases, deterministic)
/bin/bash tests/live_sequences.sh      # live isolated-server suite
/bin/bash tests/assert_layout.sh '<cs,geom>'   # check one layout string by hand

# lint
shellcheck -s bash -S warning scripts/*.sh pane-minimize.tmux tests/*.sh
```

The **offline** suite is the one to lean on: it's pure and fast-ish, and it has caught
real bugs (the original zero-height bug fell out of it on the first run). Add cases there
whenever you touch the transform.

The **live** suite spins up throwaway `tmux -L … -f /dev/null` servers. The end-to-end
resurrect test wants a tmux-resurrect checkout — point `RESURRECT_PATH` at one (or it's
auto-found in the Nix store); it skips cleanly if absent.

## tmux plugin debugging techniques

These are the things that make tmux development not-miserable (and they're how the test
harness works under the hood):

1. **Never test against your live session.** Use an isolated server on its own socket
   with no config and a fixed size so geometry is reproducible:
   ```sh
   tmux -L test -f /dev/null new-session -d -x 200 -y 50
   tmux -L test split-window -h -t 0
   tmux -L test kill-server   # always clean up
   ```
2. **Socket-patch a script** so it drives your test server instead of the default one:
   ```sh
   sed "s/tmux /tmux -L test /g" scripts/tmux-min.sh > /tmp/engine.sh
   ```
3. **`run-shell` reports a non-zero exit by dumping the command into the pane.** Pipelines
   and `if/elif` with no matching branch return non-zero — end hook commands with `; : ok`.
4. **Format-expansion timing:** `run-shell "...#{x}..."` expands `#{x}` *before* the shell
   runs; double the hash (`##{x}`) to defer to a nested tmux call.
5. **Apply changes live without a reload:** `bash pane-minimize.tmux` re-applies all the
   bindings/hooks to the running server.
6. **Headless limits:** a detached server has no attached client, so `pane-focus-in/out`
   never fire and tmux-resurrect's `restore.sh` can't run (it needs a client). The live
   suite calls the focus handlers directly to model what the hooks would do.

## Style

Match the surrounding code: terse, comment the *why* (the engine is dense; comments
explain the geometry decisions, not the syntax). Keep `transform` pure. Anything that can
go wrong silently in tmux (a malformed layout `select-layout` accepts and squishes a pane
to zero) must be guarded — the `reconcile()` pass exists for exactly that.

## CI

`.github/workflows/ci.yml` runs on macOS + ubuntu: `bash -n`, shellcheck (warning sev),
the offline property suite, and the live suite (with a tmux-resurrect checkout). Keep it
green; add coverage with each change.
