# Contributing / Development

Thanks for hacking on tmux-pane-minimize. This file covers the repo layout, how to run
the tests, and the techniques that make developing a tmux plugin tractable.

## Repo layout

```
pane-minimize.tmux       TPM entry point: reads @minimize-* options, binds keys, sets hooks
engine-rs/               the Rust port of the pure layer (THE engine): src/lib.rs (transform +
                         tree/parser/reconcile/checksum + cargo tests) + src/main.rs (thin CLI,
                         binary tmux-min-transform)
scripts/transform.sh     bash equivalent of the engine, kept ONLY as the differential test oracle
scripts/tmux-min.sh      the tmux-IO layer — shells out to tmux-min-transform; subcommands + apply
scripts/marker.sh        the border-marker builder (build_marker -> MARKER_FMT)
scripts/ensure-engine.sh installs the engine for non-Nix users: downloads the release prebuilt
                         (pinned + sha256-verified by scripts/engine.manifest), cargo fallback
scripts/engine.manifest  written by the release workflow: release tag + per-target sha256 pins
STATE.md                 the single state model — every @minimize-* / @minimize_* option
tests/                   the test harness (see tests/README.md)
.github/workflows/       ci.yml (macOS + ubuntu test matrix), release.yml (tag -> cross-built
                         binaries on the GitHub release + manifest pin committed to main)
```

The engine is split along its one real seam: the pure layout math vs the tmux IO. The pure
math is `transform()` — a **pure function** of `(layout, MINSET, SAVEDW, WPANE, WVAL, MINH)`
plus the `MIN_H/MIN_W/ABS_MIN_H/BORDER_POS` knobs — with no tmux, time, or randomness, which
is what makes the bulk of the tests exhaustive and deterministic. It now lives in Rust
(`engine-rs/`, binary **`tmux-min-transform`**); `scripts/transform.sh` is a byte-for-byte
bash equivalent kept ONLY as the test oracle the Rust engine is validated against (see
`tests/diff_test.sh`). `scripts/tmux-min.sh` is the thin orchestration layer: everything that
touches tmux (toggle/peek/minimize-others/save-state/…) reads state, calls the binary via its
`_transform()` wrapper, and applies the result with `select-layout`. It locates the binary via
`TMUX_MIN_TRANSFORM`, then `PATH`, then the `engine-rs/target/release` dev build, and hard-fails
if none is found (there is no bash fallback — `transform.sh` is the oracle only).

Build the engine with `cargo build --release` from the repo root (it's a cargo workspace whose
only member is `engine-rs/`, so no `--manifest-path` is needed and `target/` lives at the root;
the test harnesses build it for you). It has zero dependencies, so the build is fast and offline.

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

# the Rust engine
cargo test                            # native unit tests (oracle cases, no bash) — from repo root
cargo build --release                 # builds the engine-rs crate -> target/release/tmux-min-transform
/bin/bash tests/diff_test.sh           # differential: Rust binary vs bash oracle, byte-for-byte
QUICK=1 /bin/bash tests/diff_test.sh   # ... skip the WVAL inner sweep (fast)

# individual suites
/bin/bash tests/transform_props.sh     # offline property suite (~11k cases, deterministic)
/bin/bash tests/live_sequences.sh      # live isolated-server suite
/bin/bash tests/assert_layout.sh '<cs,geom>'   # check one layout string by hand

# lint
shellcheck -s bash -S warning scripts/*.sh pane-minimize.tmux tests/*.sh
```

The engine lives in `engine-rs/` as a library (`src/lib.rs`, the pure `transform()` + the
node tree, parser, reconcile, checksum) plus a thin CLI (`src/main.rs`). `cargo test` runs an
oracle table (in `lib.rs`) captured from the bash reference — a fast, bash-free regression set;
regenerate it with `tests/gen_oracle_cases.sh` after an intentional engine change. The
**`tests/diff_test.sh`** differential is the exhaustive check: it diffs the Rust binary against
`scripts/transform.sh` (the bash oracle) byte-for-byte across ~11k cases. The bash oracle is
also what the **offline** property suite (`transform_props.sh`) drives — it's pure and has
caught real bugs (the original zero-height bug fell out of it on the first run). When you change
engine behaviour, change `transform.sh` (the oracle) and the Rust together and keep the
differential at 100%.

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
`cargo test`, the Rust-vs-bash differential (`tests/diff_test.sh`), the offline property
suite, the ensure-engine install-path suite, and the live suite (with a tmux-resurrect
checkout). Keep it green; add coverage with each change.

## Releasing

Push a tag `vX.Y.Z` (usually on main). `.github/workflows/release.yml` then:

1. cross-builds `tmux-min-transform` for every supported target
   (linux x86_64/aarch64 as static musl, macOS arm64/x86_64), smoke-testing each
   binary on a native runner;
2. publishes them (plus `SHA256SUMS`) as the GitHub release for that tag;
3. commits `scripts/engine.manifest` — the release tag + per-target sha256 — to main.

That manifest commit is what rolls the engine out: TPM/manual users pick it up on their
next plugin update, and `ensure-engine.sh` re-fetches the pinned binary in the
background (verifying it against the committed sha256). Keep `engine-rs/Cargo.toml`'s
`version` in step with the tag so `tmux-min-transform --version` stays truthful.
