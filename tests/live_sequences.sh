#!/usr/bin/env bash
# Live suite — isolated tmux server, real engine + real hooks.
#
# Uses `tmux -L <sock> -f /dev/null` so it never touches your live session, and a
# socket-patched copy of the engine/plugin so the real code paths drive the sandbox.
#
#   Part 1  scripted regressions  — fixed op sequences, invariants after EACH op
#   Part 2  deterministic fuzz    — fixed enumerated sequences (no $RANDOM)
#   Part 3  race exposer          — rapid focus ping-pong with the real -b hooks
#
# Run under /bin/bash to honour the macOS bash 3.2 constraint:
#     /bin/bash tests/live_sequences.sh
#
# Skips cleanly (exit 0) if tmux is not installed.

set -u
LS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$LS_DIR/assert_layout.sh"
# shellcheck source=/dev/null
. "$LS_DIR/lib.sh"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found — skipping live suite"
  exit 0
fi

# The engine now shells out to the compiled Rust transform (engine-rs/tmux-min-transform).
# The socket-patched mirror below has no engine-rs/ dir, so build the binary once and point
# the patched engine at it via TMUX_MIN_TRANSFORM. Exporting it here (before the test server
# starts) means both the direct `bash "$ENGINE" …` calls and the run-shell hook children
# (peekin/peekout/dragend/repin) inherit it.
# A pre-set TMUX_MIN_TRANSFORM (CI, or a container without cargo) is honoured as-is.
if [ -n "${TMUX_MIN_TRANSFORM:-}" ] && [ -x "${TMUX_MIN_TRANSFORM:-}" ]; then
  :
elif ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found — skipping live suite (needs the Rust engine)"
  exit 0
else
  RUST_BIN="$LS_DIR/../target/release/tmux-min-transform"
  ( cd "$LS_DIR/.." && cargo build --release >/dev/null 2>&1 ) || {
    echo "cargo build failed — skipping live suite"; exit 0; }
  export TMUX_MIN_TRANSFORM="$RUST_BIN"
fi

SOCK="tmin_test_$$"
# A socket-patched MIRROR of the repo (with a scripts/ subdir) so every relative `source`
# inside the engine/plugin — tmux-min.sh -> transform.sh, pane-minimize.tmux -> marker.sh —
# resolves exactly as in the real tree, just driving our sandbox server.
WORKDIR="/tmp/tmin-$SOCK"
ENGINE="$WORKDIR/scripts/tmux-min.sh"
PLUGIN="$WORKDIR/pane-minimize.tmux"

T() { tmux -L "$SOCK" "$@"; }

# Restart the sandbox server. kill-server immediately followed by new-session RACES on
# some tmux versions (seen on 3.4/Linux): the new client connects to the dying server's
# still-present socket, reports "server exited unexpectedly", and no server starts —
# which is exactly how the old CI runs died mid-suite. Retry until the new server is up.
# `-f /dev/null` matters HERE, not just on the first server: new-session is what boots
# each fresh server, and without it the server reads the developer's real tmux config
# (~/.config/tmux/tmux.conf) — e.g. a `pane-border-status top` there flips the engine's
# edge-bonus and skews every height assertion. CI was blind to this (no user config).
fresh_server() {  # new-session args (e.g. -x 222 -y 61 [\; set -g ...])
  T kill-server >/dev/null 2>&1
  local i=0
  while ! tmux -L "$SOCK" -f /dev/null new-session -d "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then tmux -L "$SOCK" -f /dev/null new-session -d "$@"; return; fi   # surface the real error
    sleep 0.1
  done
}

cleanup() { tmux -L "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

# Socket-patch every script (bare `tmux ` -> `tmux -L $SOCK `) into the mirror, and point
# the plugin's SCRIPT at the patched engine so its hooks invoke our copy.
mkdir -p "$WORKDIR/scripts"
for f in "$LS_DIR"/../scripts/*.sh; do
  sed "s|tmux |tmux -L $SOCK |g" "$f" > "$WORKDIR/scripts/$(basename "$f")"
done
sed -e "s|tmux |tmux -L $SOCK |g" -e "s|^SCRIPT=.*|SCRIPT=\"$ENGINE\"|" \
    "$LS_DIR/../pane-minimize.tmux" > "$PLUGIN"

# --- assertions against the live server -------------------------------------
# assert_live DESC : read the current window_layout and validate; also defend in
# depth by scanning list-panes for any literal 0 dimension.
assert_live() {
  local desc="$1" lay z
  lay=$(T display-message -p '#{window_layout}')
  # AL_ERR is set by check_layout in the sourced assert_layout.sh
  # shellcheck disable=SC2154
  if check_layout "$lay"; then ok "$desc"; else bad "$desc :: $AL_ERR :: $lay"; fi
  z=$(T list-panes -F '#{pane_width} #{pane_height} #{pane_id}' | awk '$1<1 || $2<1 {print}')
  [ -n "$z" ] && bad "$desc :: ZERO-DIM pane(s): $z :: $lay"
  return 0
}

# Build the canonical bug shape: a left pane beside a right 2-stack -> h(L, v(L,L)).
# Returns pane ids in globals P_LEFT P_RTOP P_RBOT.
build_bugshape() {
  fresh_server -x 222 -y 61
  T split-window -h -t 0
  T split-window -v -t 1
  P_LEFT=$(T list-panes -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  # right column: the two panes with the larger pane_left, top first
  P_RTOP=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -2 | head -1 | awk '{print $3}')
  P_RBOT=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -1 | awk '{print $3}')
}

mini() { bash "$ENGINE" toggle "$1"; }   # toggle minimize via the patched engine

# --- Part 1: scripted regressions -------------------------------------------
part1() {
  build_bugshape
  assert_live "p1 initial h(L,v(L,L))"

  mini "$P_RTOP"; assert_live "p1 min right-top"
  mini "$P_RBOT"; assert_live "p1 min right-bot (right column fully min -> narrow)"
  # All panes minimized -> exercises the all-columns-fixed width path (the bug I fixed).
  mini "$P_LEFT"; assert_live "p1 min left (ALL minimized -> allfix width path)"
  mini "$P_LEFT"; assert_live "p1 un-min left"
  mini "$P_RTOP"; assert_live "p1 un-min right-top"
  mini "$P_RBOT"; assert_live "p1 un-min right-bot (back to start)"

  # repin and a manual resize must keep invariants.
  bash "$ENGINE" repin "$(T display-message -p '#{window_id}')"
  assert_live "p1 repin"
  T resize-pane -t "$P_LEFT" -x 40 >/dev/null 2>&1
  assert_live "p1 resize left -x40"

  # Two stacks side by side, all minimized (the exact offline-found failure shape).
  fresh_server -x 222 -y 61
  T split-window -h -t 0
  T split-window -v -t 0
  T split-window -v -t 2
  local p
  for p in $(T list-panes -F '#{pane_id}'); do mini "$p"; done
  assert_live "p1 two 2-stacks, ALL minimized"
}

# --- Part 1b: stale-saved-dimension regression ------------------------------
# Real-world path to a squished pane: minimize a pane (saves its height/width),
# SHRINK the window, then un-minimize -> the engine pins it to a saved size that no
# longer fits. reconcile must keep the layout valid instead of squishing a sibling.
part1_stale() {
  fresh_server -x 80 -y 40
  T split-window -v -t 0
  local top
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  mini "$top"                        # minimize top (records @minimize_saved)
  assert_live "p1b minimize top (tall window)"
  # Simulate the window having been much taller when saved: force a stale large height.
  T set-option -t "$top" -p @minimize_saved 35 >/dev/null 2>&1
  T set-option -t "$top" -p @minimize_saved_w 200 >/dev/null 2>&1
  T resize-window -t "$top" -y 10 -x 24 >/dev/null 2>&1   # shrink hard
  assert_live "p1b after shrink to 24x10"
  mini "$top"                        # un-minimize -> pins to stale saved 35 in a 10-row window
  assert_live "p1b un-minimize with stale saved height (35 in 10 rows)"
}

# --- Part 2: deterministic fuzz ---------------------------------------------
# Fixed, enumerated op sequences (indexed; NO $RANDOM) over the bug shape.
part2() {
  local seqs i op panes p idx
  # each line: space-separated ops; m<n>=toggle pane n (1=left 2=rtop 3=rbot),
  # r=repin, z=resize left, s<n>=select-pane n
  seqs='m2 m3 m1 m1 m3 m2
m1 m2 m3 r m3 m2 m1
m2 s1 s2 m2 r z
m3 m2 m1 z r m1 m2 m3
s2 s3 s1 m2 s2 s1 r'
  idx=0
  printf '%s\n' "$seqs" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    idx=$((idx + 1))
    build_bugshape
    panes=" $P_LEFT $P_RTOP $P_RBOT"   # index 1,2,3
    i=0
    for op in $line; do
      i=$((i + 1))
      case "$op" in
        m1) mini "$P_LEFT" ;;
        m2) mini "$P_RTOP" ;;
        m3) mini "$P_RBOT" ;;
        s1) T select-pane -t "$P_LEFT" ;;
        s2) T select-pane -t "$P_RTOP" ;;
        s3) T select-pane -t "$P_RBOT" ;;
        r)  bash "$ENGINE" repin "$(T display-message -p '#{window_id}')" ;;
        z)  T resize-pane -t "$P_LEFT" -x 40 >/dev/null 2>&1 ;;
      esac
      assert_live "p2 seq$idx step$i ($op)"
    done
  done
  : "${panes:-}"  # documents the 1/2/3 index mapping; assigned in the subshell above
}

# --- Part 3: race exposer ---------------------------------------------------
# The focus/resize hooks invoke the engine with `run-shell -b`, so several copies can
# run at once. A headless server has no attached client, so real focus events never
# fire — instead we invoke the engine concurrently OURSELVES (exactly the interleaving
# the -b hooks produce) and assert the engine stays correct under it.
#
# We instrument an engine copy to log apply() enter/exit so we can also measure
# serialization. Assertions: after a heavy concurrent burst the layout is valid, no
# pane is ever 0, and applies are serialized (max concurrent ~1; before the mkdir lock
# this was dozens). The instrumentation log lines are short -> atomic appends, so the
# enter/exit ordering reflects real interleaving (modulo a 1-deep handoff artifact).
part3() {
  local eng2 busy coll win r
  local burst=16
  eng2="$WORKDIR/scripts/engine2.sh"   # in scripts/ so it still sources transform.sh
  busy="/tmp/tmin-busy-$SOCK"          # the mutual-exclusion marker dir
  coll="/tmp/tmin-coll-$SOCK"          # collision log
  : > "$coll"; rmdir "$busy" 2>/dev/null
  # TRUE overlap detector (not log-order sensitive): each apply mkdir's a shared marker
  # at entry; the mkdir can only FAIL if another apply already holds it -> a real
  # overlap. rmdir at the end of the critical section. With the per-window lock this
  # must never collide.
  # Release the busy marker at apply()'s REAL exit — the guard-clear (set-option -gu
  # @minimize_guard) — not at select-layout, because apply() has early-return paths (a no-op
  # layout, or a transform failure) that clear the guard without ever reaching select-layout.
  # Every apply() exit clears the guard, so this releases on all paths.
  awk -v busy="$busy" -v coll="$coll" '
    /^apply\(\) \{/ { print; getline; print; print "  mkdir \"" busy "\" 2>/dev/null || echo OVERLAP >> \"" coll "\""; next }
    /set-option -gu @minimize_guard/ { print; print "  rmdir \"" busy "\" 2>/dev/null"; next }
    { print }
  ' "$ENGINE" > "$eng2"

  build_bugshape
  win=$(T display-message -p '#{window_id}')
  bash "$eng2" toggle "$P_RTOP"        # minimize one pane
  assert_live "p3 pre-burst"

  # Realistic concurrent burst (focus/resize hooks are only a few deep in practice).
  r=0
  while [ "$r" -lt "$burst" ]; do bash "$eng2" repin "$win" & r=$((r + 1)); done
  wait
  T run-shell "true" >/dev/null 2>&1
  assert_live "p3 post-burst (race exposer: valid layout, no zero pane)"

  # The mkdir lock is best-effort serialization, and deliberately so: a dead holder is
  # reclaimed, and a ~20s safety valve lets a waiter proceed UNLOCKED rather than hang a
  # keystroke behind a wedged holder. On a CPU-starved machine (a busy CI runner) that valve
  # and the reclaim window do let a few applies overlap — that is the design working, not a
  # bug, and reconcile keeps every layout valid regardless. So this asserts the lock still
  # SERIALIZES, not that it is a perfect mutex.
  #
  # Measured on one CPU-starved container (`--cpus=0.5`), same burst, same machine:
  #   lock working  : 0-6 overlaps
  #   lock neutered : 11-15 overlaps  (i.e. essentially every apply in the burst)
  # Half the burst cleanly separates the two populations. The old `<=2` bound sat inside the
  # working range and flaked on CI; a real regression (the pre-mkdir global-guard race)
  # overlaps ~every apply and is still caught with room to spare.
  local n
  local tol=$(( burst / 2 ))
  n=$(grep -c OVERLAP "$coll" 2>/dev/null || true); : "${n:=0}"
  if [ "$n" -le "$tol" ]; then ok "p3 applies serialized ($n overlaps over $burst concurrent, <=$tol ok)"
  else bad "p3 NOT serialized: $n overlapping applies over $burst concurrent (>$tol — guard race regression?)"; fi

  rmdir "$busy" 2>/dev/null; rm -f "$eng2" "$coll"
}

# --- Part 4: per-pane minimized height --------------------------------------
# pane_h ID -> echoes the pane's current height
pane_h() { T display-message -p -t "$1" '#{pane_height}'; }

# Custom min height applies to a minimized pane that has a FLEXIBLE sibling (a fully
# minimized stack uses the proportional 'allmin' path instead). So build a 3-pane
# vertical stack and minimize only the TOP one; mid+bot stay flexible.
part_minh() {
  local top bot win h mh
  fresh_server -x 80 -y 40
  T split-window -v -t 0
  T split-window -v -t 0
  win=$(T display-message -p '#{window_id}')
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bot=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | tail -1 | awk '{print $2}')

  bash "$ENGINE" toggle "$top"       # minimize only the top pane
  T select-pane -t "$bot"            # top is now non-active
  assert_live "p4 3-stack, top minimized"
  h=$(pane_h "$top")
  if [ "$h" = 3 ]; then ok "p4 top at MIN_H(3)"; else bad "p4 top height=$h (expected 3)"; fi

  bash "$ENGINE" minh-set "$top" 10
  assert_live "p4 minh-set 10"
  h=$(pane_h "$top")
  if [ "$h" = 10 ]; then ok "p4 top height==10"; else bad "p4 top height=$h (expected 10)"; fi

  bash "$ENGINE" minh-grow "$top" 2;  h=$(pane_h "$top")
  if [ "$h" = 12 ]; then ok "p4 minh-grow ->12"; else bad "p4 grow height=$h (expected 12)"; fi
  bash "$ENGINE" minh-shrink "$top" 5; h=$(pane_h "$top")
  if [ "$h" = 7 ]; then ok "p4 minh-shrink ->7"; else bad "p4 shrink height=$h (expected 7)"; fi

  bash "$ENGINE" repin "$win"; h=$(pane_h "$top")
  if [ "$h" = 7 ]; then ok "p4 custom height survives repin"; else bad "p4 after repin height=$h (expected 7)"; fi

  bash "$ENGINE" minh-reset "$top"; h=$(pane_h "$top")
  if [ "$h" = 3 ]; then ok "p4 minh-reset -> MIN_H(3)"; else bad "p4 after reset height=$h (expected 3)"; fi
  assert_live "p4 after reset"

  # reset-each-time: set custom, un-minimize, re-minimize -> default again
  bash "$ENGINE" minh-set "$top" 9
  bash "$ENGINE" toggle "$top"       # un-minimize (clears @minimize_minh)
  bash "$ENGINE" toggle "$top"       # re-minimize
  T select-pane -t "$bot"
  h=$(pane_h "$top")
  if [ "$h" = 3 ]; then ok "p4 custom height reset after un/re-minimize"; else bad "p4 re-minimize height=$h (expected 3)"; fi

  # dragend path: simulate dragging the non-active minimized top taller, then dragend
  T set-option -g @minimize_guard 1
  T resize-pane -t "$top" -y 8 >/dev/null 2>&1
  T set-option -gu @minimize_guard
  bash "$ENGINE" dragend "$win"
  mh=$(T show-options -t "$top" -pqv @minimize_minh 2>/dev/null || true)
  if [ -n "$mh" ]; then ok "p4 dragend set @minimize_minh=$mh on non-active pane"; else bad "p4 dragend did not set @minimize_minh"; fi
  assert_live "p4 after dragend"
}

# --- Part 4b: custom minimized WIDTH via side-border drag on a fully-minimized group -------
# A vertical group that is ALL minimized and has NO active pane narrows to MIN_W; dragging its
# side border sets a custom @minimize_minw that persists (repin, and un/re-minimize).
part_minw() {
  local left rtop rbot win w mw
  fresh_server -x 200 -y 50
  T set-option -g @minimize-width 30
  T set-option -g @minimize-narrow on     # p4b exercises width-narrowing (opt-in since default is off)
  T split-window -h -t 0
  T split-window -v -t 1
  win=$(T display-message -p '#{window_id}')
  left=$(T list-panes -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  rtop=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -2 | head -1 | awk '{print $3}')
  rbot=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -1 | awk '{print $3}')

  bash "$ENGINE" toggle "$rtop"; bash "$ENGINE" toggle "$rbot"   # right group fully minimized
  T select-pane -t "$left"                                       # no group pane active
  assert_live "p4b right group fully minimized"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 30 ]; then ok "p4b group narrowed to MIN_W(30)"; else bad "p4b group width=$w (expected 30)"; fi

  # simulate a horizontal border drag widening the group to 60, then dragend
  T set-option -g @minimize_guard 1
  T resize-pane -t "$rtop" -x 60 >/dev/null 2>&1
  T set-option -gu @minimize_guard
  bash "$ENGINE" dragend "$win"
  mw=$(T show-options -t "$rtop" -pqv @minimize_minw 2>/dev/null || true)
  if [ "$mw" = 60 ]; then ok "p4b dragend set @minimize_minw=60"; else bad "p4b @minimize_minw=$mw (expected 60)"; fi
  mw=$(T show-options -t "$rbot" -pqv @minimize_minw 2>/dev/null || true)
  if [ "$mw" = 60 ]; then ok "p4b minw shared across the group"; else bad "p4b rbot @minimize_minw=$mw (expected 60)"; fi
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 60 ]; then ok "p4b group pinned to custom width 60"; else bad "p4b group width=$w (expected 60)"; fi
  assert_live "p4b after width drag"

  bash "$ENGINE" repin "$win"; w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 60 ]; then ok "p4b custom width survives repin"; else bad "p4b after repin width=$w (expected 60)"; fi

  # persist across un-minimize + re-minimize (the group reforms at its custom width)
  bash "$ENGINE" toggle "$rtop"; T select-pane -t "$left"
  bash "$ENGINE" toggle "$rtop"; T select-pane -t "$left"; bash "$ENGINE" repin "$win"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 60 ]; then ok "p4b custom width persists across un/re-minimize"; else bad "p4b after re-minimize width=$w (expected 60)"; fi
  assert_live "p4b after re-minimize"

  # minw-reset snaps the group back to MIN_W and clears @minimize_minw on every member
  bash "$ENGINE" minw-reset "$rtop"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 30 ]; then ok "p4b minw-reset -> MIN_W(30)"; else bad "p4b after minw-reset width=$w (expected 30)"; fi
  mw=$(T show-options -t "$rbot" -pqv @minimize_minw 2>/dev/null || true)
  if [ -z "$mw" ]; then ok "p4b minw-reset cleared @minimize_minw across the group"; else bad "p4b rbot still has @minimize_minw=$mw"; fi
  assert_live "p4b after minw-reset"
}

# --- Part 4c: @minimize-narrow opt-in + runtime toggle ----------------------
# Width-narrowing is opt-in (default off). This exercises three things:
#   (a) with narrow=off, minimizing an entire vertical stack does NOT narrow the column;
#   (b) `narrow-toggle` flips it on and re-pins, collapsing the stack to MIN_W;
#   (c) `narrow-toggle` again widens the group back to its saved pre-narrow width.
part_narrow_toggle() {
  local left rtop rbot win w0 w
  fresh_server -x 200 -y 50
  T set-option -g @minimize-width 30
  # NOTE: intentionally do NOT set @minimize-narrow — its absence is the default (off).
  T split-window -h -t 0
  T split-window -v -t 1
  win=$(T display-message -p '#{window_id}')
  left=$(T list-panes -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  rtop=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -2 | head -1 | awk '{print $3}')
  rbot=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -1 | awk '{print $3}')
  w0=$(T display-message -p -t "$rtop" '#{pane_width}')                     # pre-minimize width

  # (a) minimize the entire right stack with narrow=off (default). The column must NOT narrow.
  bash "$ENGINE" toggle "$rtop"; bash "$ENGINE" toggle "$rbot"
  T select-pane -t "$left"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = "$w0" ]; then ok "p4c narrow=off: fully-min stack keeps its width ($w)"; else bad "p4c narrow=off changed width $w0 -> $w"; fi
  assert_live "p4c after minimize with narrow=off"

  # (b) toggle narrow ON via the runtime command; the group must collapse to MIN_W(30).
  bash "$ENGINE" narrow-toggle
  local on; on=$(T show-option -gqv @minimize-narrow)
  if [ "$on" = on ]; then ok "p4c narrow-toggle set @minimize-narrow=on"; else bad "p4c narrow-toggle -> @minimize-narrow=$on (expected on)"; fi
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 30 ]; then ok "p4c narrow-toggle on -> collapsed to MIN_W(30)"; else bad "p4c after toggle-on width=$w (expected 30)"; fi
  assert_live "p4c after narrow-toggle on"

  # (c) toggle narrow OFF again; the group must widen back to its saved pre-narrow width.
  bash "$ENGINE" narrow-toggle
  local off; off=$(T show-option -gqv @minimize-narrow)
  if [ "$off" = off ]; then ok "p4c narrow-toggle set @minimize-narrow=off"; else bad "p4c narrow-toggle -> @minimize-narrow=$off (expected off)"; fi
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = "$w0" ]; then ok "p4c narrow-toggle off -> widened back to $w0"; else bad "p4c after toggle-off width=$w (expected $w0)"; fi
  assert_live "p4c after narrow-toggle off"
}

# --- Part 4d: narrow=off must never pin a fully-min stack's width ------------
# Regression tests for the width snap-back bug: with @minimize-narrow off (the
# default), a fully-minimized vertical stack's width was pinned to the panes'
# @minimize_saved_w on every apply — so a user's border drag snapped back on
# release (dragend), and a peekin/peekout round trip "randomly" resized the
# column. @minimize_saved_w is the NARROW feature's memory (the width to widen
# back to): it must exist only while narrowing is on.
part_narrow_off_widths() {
  local left rtop rbot win w sw
  fresh_server -x 200 -y 50
  # NOTE: @minimize-narrow deliberately unset — off is the default under test.
  T split-window -h -t 0
  T split-window -v -t 1
  win=$(T display-message -p '#{window_id}')
  left=$(T list-panes -F '#{pane_left} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  rtop=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -2 | head -1 | awk '{print $3}')
  rbot=$(T list-panes -F '#{pane_left} #{pane_top} #{pane_id}' | sort -k1,1n -k2,2n | tail -1 | awk '{print $3}')
  bash "$ENGINE" toggle "$rtop"; bash "$ENGINE" toggle "$rbot"
  T select-pane -t "$left"          # the fully-min stack has NO active pane

  # (a) minimizing with narrow=off must not record a saved width at all
  sw=$(T show-options -t "$rtop" -pqv @minimize_saved_w 2>/dev/null || true)
  if [ -z "$sw" ]; then ok "p4d narrow=off: no @minimize_saved_w recorded"; else bad "p4d narrow=off recorded @minimize_saved_w=$sw"; fi

  # (b) drag the shared border (widen left to 130 -> stack 69) and release: must stick
  T resize-pane -t "$left" -x 130
  bash "$ENGINE" dragend "$win"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 69 ]; then ok "p4d drag sticks through dragend (stack=69)"; else bad "p4d dragend snapped the stack back (w=$w, expected 69)"; fi
  assert_live "p4d after dragend"

  # (c) a peek round trip must not change widths
  T select-pane -t "$rtop"; bash "$ENGINE" peekin "$rtop" "$win"
  T select-pane -t "$left"; bash "$ENGINE" peekout "$rtop" "$win"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 69 ]; then ok "p4d peek round trip keeps width (69)"; else bad "p4d peekout resized the stack (w=$w, expected 69)"; fi
  assert_live "p4d after peek round trip"

  # (d) stale @minimize_saved_w (pre-fix session, or narrow flipped off via config
  # reload): the next drag must stick anyway and clear the stale option (self-heal).
  T set-option -t "$rtop" -p @minimize_saved_w 99
  T set-option -t "$rbot" -p @minimize_saved_w 99
  T resize-pane -t "$left" -x 120
  bash "$ENGINE" dragend "$win"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 79 ]; then ok "p4d drag sticks despite stale saved_w (stack=79)"; else bad "p4d stale saved_w snapped the stack (w=$w, expected 79)"; fi
  sw=$(T show-options -t "$rtop" -pqv @minimize_saved_w 2>/dev/null || true)
  if [ -z "$sw" ]; then ok "p4d stale saved_w cleared by drag"; else bad "p4d stale saved_w survived the drag ($sw)"; fi

  # (e) narrow on->off round trip: toggle-off widens back to the width the stack had
  # when narrowing came ON (79), consumes saved_w, and later drags stick again.
  bash "$ENGINE" narrow-toggle      # on  -> stack collapses to MIN_W
  bash "$ENGINE" narrow-toggle      # off -> widens back
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 79 ]; then ok "p4d narrow round trip restores width (79)"; else bad "p4d narrow round trip width=$w (expected 79)"; fi
  sw=$(T show-options -t "$rtop" -pqv @minimize_saved_w 2>/dev/null || true)
  if [ -z "$sw" ]; then ok "p4d toggle-off consumed saved_w"; else bad "p4d saved_w lingers after toggle-off ($sw)"; fi
  T resize-pane -t "$left" -x 150
  bash "$ENGINE" dragend "$win"
  w=$(T display-message -p -t "$rtop" '#{pane_width}')
  if [ "$w" = 49 ]; then ok "p4d drag after narrow round trip sticks (49)"; else bad "p4d post-round-trip drag snapped back (w=$w, expected 49)"; fi
  assert_live "p4d final"
}

# --- Part 5: minimize-others (minimize all but active) ----------------------------
part_minimize_others() {
  local win act orig now nmin top bot dflag

  fresh_server -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0; T split-window -v -t 0   # 4 panes
  win=$(T display-message -p '#{window_id}')
  act=$(T list-panes -F '#{?pane_active,#{pane_id},}' | tr -d '\n ')
  orig=$(T display-message -p '#{window_layout}')
  assert_live "p5 initial 4 panes"

  bash "$ENGINE" minimize-others "$act"
  assert_live "p5 minimize-others entered"
  nmin=$(T list-panes -F '#{@minimize_active}' | grep -c 1 || true); : "${nmin:=0}"
  if [ "$nmin" = 3 ]; then ok "p5 3 non-active panes minimized"; else bad "p5 minimized count=$nmin (expected 3)"; fi

  bash "$ENGINE" minimize-others "$act"
  now=$(T display-message -p '#{window_layout}')
  if [ "$orig" = "$now" ]; then ok "p5 exact layout restore on exit"; else bad "p5 not restored:
    orig=$orig
    now =$now"; fi
  nmin=$(T list-panes -F '#{@minimize_active}' | grep -c 1 || true); : "${nmin:=0}"
  if [ "$nmin" = 0 ]; then ok "p5 all flags cleared on exit"; else bad "p5 $nmin panes still minimized after exit"; fi
  assert_live "p5 minimize-others exited"

  # A pane the user minimized BEFORE entering minimize-others must survive the round trip.
  fresh_server -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0                          # 3 panes
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bot=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | tail -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"           # user-minimize the top pane
  T select-pane -t "$bot"
  bash "$ENGINE" minimize-others "$bot"        # enter minimize-others from bottom
  dflag=$(T show-options -t "$top" -pqv @minimize_others 2>/dev/null || true)
  if [ -z "$dflag" ]; then ok "p5 pre-minimized pane not minimize-others-flagged"; else bad "p5 pre-min pane wrongly flagged"; fi
  bash "$ENGINE" minimize-others "$bot"        # exit minimize-others
  if [ "$(T display-message -p -t "$top" '#{?@minimize_active,1,0}')" = 1 ]; then
    ok "p5 pre-minimized pane still minimized after exit"
  else bad "p5 pre-minimized pane lost its minimized state"; fi
  assert_live "p5 pre-minimized preserved"

  # Zoom is preserved across a minimize-others round trip: the verbatim restore goes through
  # _rezoom (shared with apply()), so zooming the active pane inside the minimize-others view
  # and then exiting must keep the window zoomed.
  fresh_server -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0                          # 3 panes
  act=$(T list-panes -F '#{?pane_active,#{pane_id},}' | tr -d '\n ')
  bash "$ENGINE" minimize-others "$act"        # enter minimize-others
  T resize-pane -Z -t "$act"             # zoom the active pane while in the minimize-others view
  [ "$(T display-message -p '#{window_zoomed_flag}')" = 1 ] || bad "p5 setup: zoom did not take"
  bash "$ENGINE" minimize-others "$act"        # exit minimize-others -> should re-zoom
  if [ "$(T display-message -p '#{window_zoomed_flag}')" = 1 ]; then
    ok "p5 zoom preserved across minimize-others round trip"
  else bad "p5 lost zoom on minimize-others exit"; fi
}

# --- Part 5b: dragend must not mistake a group's remainder for a dragged height ------
# When EVERY pane in a vertical group is minimized the group must still fill its column, so
# the engine hands one pane (the bottom-most) whatever space is left over. That height is
# engine-assigned, not user-chosen — dragend used to see it differ from @minimize-height and
# record it as that pane's custom minimized height, which then stuck for the rest of the
# minimize session (and got persisted by resurrect).
part_dragend_absorber() {
  local win left ids bot mh p
  fresh_server -x 200 -y 50
  T set-option -g @minimize-height 4
  win=$(T display-message -p '#{window_id}')
  T split-window -h -t 0; T split-window -v -t 1; T split-window -v -t 1
  ids=$(T list-panes -F '#{pane_left}_#{pane_id}' | awk -F_ '$1>0{print $2}')
  printf '%s\n' "$ids" | while read -r p; do [ -n "$p" ] && bash "$ENGINE" toggle "$p"; done
  left=$(T list-panes -F '#{pane_left}_#{pane_id}' | awk -F_ '$1==0{print $2}')
  T select-pane -t "$left"                       # the minimized group has no active pane
  bash "$ENGINE" repin "$win"
  bot=$(T list-panes -F '#{pane_left}_#{pane_top}_#{pane_id}' | awk -F_ '$1>0' | sort -t_ -k2,2n | tail -1 | awk -F_ '{print $3}')
  bash "$ENGINE" dragend "$win"                  # a border drag anywhere rescans every pane
  mh=$(T show-options -t "$bot" -pqv @minimize_minh 2>/dev/null || true)
  if [ -z "$mh" ]; then ok "p5b remainder-holding pane keeps no custom minimized height"; else bad "p5b dragend invented @minimize_minh=$mh for the group's remainder pane"; fi
  assert_live "p5b after dragend on a fully-minimized group"
}

# --- Part 6: tmux-resurrect persistence (save-state/restore-state) -----------
part_resurrect() {
  local top bot state a minh p
  state="/tmp/tmin-state-$SOCK"
  fresh_server -s rs -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bot=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | tail -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"           # minimize top
  bash "$ENGINE" minh-set "$top" 8       # with a custom height
  T select-pane -t "$bot"

  bash "$ENGINE" save-state "$state"
  if [ -s "$state" ]; then ok "p6 state saved to sidecar"; else bad "p6 empty/missing state file"; fi

  # simulate a restart: resurrect would restore the window_layout (so geometry is back),
  # but the @minimize_* options are gone. Clear them to model that.
  for p in $(T list-panes -F '#{pane_id}'); do
    T set-option -t "$p" -pu @minimize_active
    T set-option -t "$p" -pu @minimize_saved
    T set-option -t "$p" -pu @minimize_minh
  done

  bash "$ENGINE" restore-state "$state"
  a=$(T display-message -p -t "$top" '#{?@minimize_active,1,0}')
  minh=$(T show-options -t "$top" -pqv @minimize_minh 2>/dev/null || true)
  if [ "$a" = 1 ]; then ok "p6 minimized flag restored"; else bad "p6 minimized flag not restored"; fi
  if [ "$minh" = 8 ]; then ok "p6 custom minh restored"; else bad "p6 minh=$minh (expected 8)"; fi
  if [ "$(pane_h "$top")" = 8 ]; then ok "p6 geometry repinned to custom height"; else bad "p6 top h=$(pane_h "$top") (expected 8)"; fi
  assert_live "p6 after restore-state"

  # restore-state on a missing/empty file must be a harmless no-op.
  bash "$ENGINE" restore-state "/tmp/does-not-exist-$SOCK" && ok "p6 restore of missing file is a no-op"
  rm -f "$state"

  # @minimize_saved_set (was this peek/restore height DELIBERATELY chosen by the user?) must
  # survive a save/restore too — otherwise a height you sized by hand silently degrades to a
  # hint after a restart and the pane stops restoring to it.
  fresh_server -s rs -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bot=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | tail -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"
  T select-pane -t "$top"; bash "$ENGINE" peekin "$top"
  T set-option -g @minimize_guard 1
  T resize-pane -t "$top" -y 17 >/dev/null 2>&1        # deliberately size the peeked pane
  T set-option -gu @minimize_guard
  bash "$ENGINE" dragend "$(T display-message -p '#{window_id}')"
  T select-pane -t "$bot"; bash "$ENGINE" peekout "$top"
  if [ "$(T show-options -t "$top" -pqv @minimize_saved_set 2>/dev/null || true)" = 1 ]; then
    ok "p6 deliberate peek height marks @minimize_saved_set"
  else bad "p6 dragend did not mark @minimize_saved_set"; fi
  bash "$ENGINE" save-state "$state"
  for p in $(T list-panes -F '#{pane_id}'); do
    T set-option -t "$p" -pu @minimize_active; T set-option -t "$p" -pu @minimize_saved
    T set-option -t "$p" -pu @minimize_saved_set
  done
  bash "$ENGINE" restore-state "$state"
  if [ "$(T show-options -t "$top" -pqv @minimize_saved_set 2>/dev/null || true)" = 1 ]; then
    ok "p6 @minimize_saved_set survives save/restore"
  else bad "p6 @minimize_saved_set lost across save/restore"; fi
  rm -f "$state"

  # A sidecar written by an older version has no saved_set field. It must still restore
  # (losing only the flag) instead of being skipped — that would drop the minimized state.
  fresh_server -s rs -x 80 -y 40
  T split-window -v -t 0
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  printf '%s\n' "0|0|19|80|7||rs" > "$state"       # pre-flag format: ...|minw|session
  bash "$ENGINE" restore-state "$state"
  if [ "$(T display-message -p -t "$top" '#{?@minimize_active,1,0}')" = 1 ]; then
    ok "p6 legacy (pre-saved_set) sidecar still restores"
  else bad "p6 legacy sidecar line was dropped"; fi
  if [ "$(T show-options -t "$top" -pqv @minimize_minh 2>/dev/null || true)" = 7 ]; then
    ok "p6 legacy sidecar fields land in the right columns"
  else bad "p6 legacy sidecar misparsed (minh=$(T show-options -t "$top" -pqv @minimize_minh 2>/dev/null || true), expected 7)"; fi
  rm -f "$state"

  # A session name may contain '|' — the sidecar's field separator. Both the saved line
  # (session last) and the live pane lookup must keep such a name intact, or the session's
  # minimized panes are silently skipped on restore.
  fresh_server -s 'a|b' -x 80 -y 40
  T split-window -v -t 0
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"
  bash "$ENGINE" minh-set "$top" 6
  bash "$ENGINE" save-state "$state"
  for p in $(T list-panes -F '#{pane_id}'); do
    T set-option -t "$p" -pu @minimize_active; T set-option -t "$p" -pu @minimize_minh
  done
  bash "$ENGINE" restore-state "$state"
  if [ "$(T display-message -p -t "$top" '#{?@minimize_active,1,0}')" = 1 ]; then
    ok "p6 session name containing '|' round-trips"
  else bad "p6 session name with '|' lost its minimized state on restore"; fi
  if [ "$(T show-options -t "$top" -pqv @minimize_minh 2>/dev/null || true)" = 6 ]; then
    ok "p6 piped-session sidecar fields land in the right columns"
  else bad "p6 piped-session sidecar misparsed"; fi
  rm -f "$state"
}

# --- Part 8: peek-on-focus (peekin/peekout) + resize-while-peeked save ------
part_peek() {
  local top bot h saved
  fresh_server -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bot=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | tail -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"                 # minimize top (records its prior height)
  saved=$(T show-options -t "$top" -pqv @minimize_saved 2>/dev/null || true)

  T select-pane -t "$top"                      # focus it -> eligible to peek
  bash "$ENGINE" peekin "$top"
  h=$(pane_h "$top")
  if [ "$h" -gt 3 ]; then ok "p8 peekin expands the minimized pane (h=$h)"; else bad "p8 peekin did not expand (h=$h)"; fi
  if [ "$(T show-options -t "$top" -pqv @minimize_peek 2>/dev/null || true)" = 1 ]; then ok "p8 peek flag set"; else bad "p8 peek flag not set"; fi
  assert_live "p8 after peekin"

  # resize while peeked, then dragend remembers the new height as the saved/peek size
  T set-option -g @minimize_guard 1
  T resize-pane -t "$top" -y 16 >/dev/null 2>&1
  T set-option -gu @minimize_guard
  bash "$ENGINE" dragend "$(T display-message -p '#{window_id}')"
  saved=$(T show-options -t "$top" -pqv @minimize_saved 2>/dev/null || true)
  if [ "${saved:-0}" -ge 14 ]; then ok "p8 dragend saved resize-while-peeked height ($saved)"; else bad "p8 peeked resize not saved (saved=$saved)"; fi

  T select-pane -t "$bot"                      # focus away
  bash "$ENGINE" peekout "$top"
  h=$(pane_h "$top")
  if [ "$h" = 3 ]; then ok "p8 peekout re-collapses to MIN_H"; else bad "p8 peekout h=$h (expected 3)"; fi
  assert_live "p8 after peekout"
}

# --- Part 8b: a peeked pane must not starve its minimized siblings below MIN_H ------
# Regression for the "inflated saved height" bug. @minimize_saved (a pane's peek/restore
# target) is captured as the pane's height at minimize time — which can be far larger than
# the pane could ever occupy in its current stack. The worst offender: minimizing a pane
# while it is ALONE in its column (only an h-split neighbour, so it can't shrink) records
# its FULL column height; a later vertical split makes it one of several stacked panes, but
# the stale full-height saved persists. Peeking it then pins it to nearly the whole column
# and reconcile shaves every other minimized pane to the ABS_MIN_H(1) crowding floor — even
# though the column has dozens of spare rows. A non-active minimized pane must keep MIN_H
# whenever the column has room for it.
part_peek_floor() {
  local win B top mid bot h
  fresh_server -x 200 -y 50
  T set-option -g @minimize-height 4
  win=$(T display-message -p '#{window_id}')
  T split-window -h -t 0                        # A | B  (B alone in the right column)
  B=$(T list-panes -F '#{pane_left}_#{pane_id}' | awk -F_ '$1>0{print $2}')
  bash "$ENGINE" toggle "$B"                     # minimize B while alone -> saved = full height
  T split-window -v -t "$B"                      # split B: a second pane below it
  T split-window -v -t "$B"                      # and a third -> right column is a 3-stack
  top=$(T list-panes -F '#{pane_left}_#{pane_top}_#{pane_id}' | awk -F_ '$1>0' | sort -t_ -k2,2n | head -1  | awk -F_ '{print $3}')
  mid=$(T list-panes -F '#{pane_left}_#{pane_top}_#{pane_id}' | awk -F_ '$1>0' | sort -t_ -k2,2n | sed -n 2p | awk -F_ '{print $3}')
  bot=$(T list-panes -F '#{pane_left}_#{pane_top}_#{pane_id}' | awk -F_ '$1>0' | sort -t_ -k2,2n | tail -1  | awk -F_ '{print $3}')
  bash "$ENGINE" toggle "$mid"; bash "$ENGINE" toggle "$bot"   # minimize the two fresh panes
  bash "$ENGINE" repin "$win"
  T select-pane -t "$top"; bash "$ENGINE" peekin "$top"        # peek the stale-saved top pane
  h=$(pane_h "$mid")
  if [ "$h" -ge 4 ]; then ok "p8b peeked-stack sibling (mid) keeps MIN_H (h=$h)"; else bad "p8b mid starved to h=$h (< MIN_H 4) with a mostly-empty column"; fi
  h=$(pane_h "$bot")
  if [ "$h" -ge 4 ]; then ok "p8b peeked-stack sibling (bot) keeps MIN_H (h=$h)"; else bad "p8b bot starved to h=$h (< MIN_H 4) with a mostly-empty column"; fi
  assert_live "p8b after peeking a stale-saved stacked pane"
}

# --- Part 9: after-resize-window repins minimized panes ---------------------
# The hook firing on resize is tmux's guarantee; we deterministically verify (a) the
# hook is wired to repin, and (b) repin re-pins a pane that a window resize rescaled.
part_resize_window() {
  local top h hook
  fresh_server -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0
  bash "$PLUGIN"
  hook=$(T show-hooks -g 2>/dev/null | grep after-resize-window || true)
  if printf '%s' "$hook" | grep -q 'repin'; then ok "p9 after-resize-window hook wired to repin"; else bad "p9 hook missing/incorrect: [$hook]"; fi

  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"
  T resize-window -y 44 >/dev/null 2>&1                          # rescales panes proportionally
  if [ "$(pane_h "$top")" != 3 ]; then ok "p9 resize rescaled the minimized pane (pre-repin)"; else ok "p9 (resize kept size)"; fi
  bash "$ENGINE" repin "$(T display-message -p '#{window_id}')"  # what the hook fires
  h=$(pane_h "$top")
  if [ "$h" = 3 ]; then ok "p9 repin re-pins minimized pane to MIN_H after resize"; else bad "p9 not repinned (h=$h)"; fi
  assert_live "p9 after resize + repin"
}

# --- Part M: marker is a good citizen (augments pane-border-format, never clobbers) -----
part_marker() {
  local fmt
  fresh_server -x 80 -y 24
  # Fresh marker state (the host's /etc/tmux.conf may have loaded the real plugin already
  # AND set @minimize-marker-* options — the isolated server still reads /etc/tmux.conf, so
  # clear everything we depend on), then simulate a user with their OWN custom border.
  T set -gu @minimize_marker_installed; T set -gu @minimize_orig_format
  T set -gu @minimize-marker-left-format; T set -gu @minimize-marker-position
  T set -g pane-border-status bottom
  T set -g pane-border-format 'MYTITLE#{pane_index}'
  bash "$PLUGIN"
  fmt=$(T show-option -gqv pane-border-format)
  case "$fmt" in *MYTITLE*) ok "pM custom pane-border-format preserved (augmented, not clobbered)" ;; *) bad "pM clobbered custom format: [$fmt]" ;; esac
  case "$fmt" in *@minimize_active*) ok "pM marker appended for minimized panes" ;; *) bad "pM marker not appended: [$fmt]" ;; esac
  if [ "$(T show-option -gqv pane-border-status)" = bottom ]; then ok "pM existing border position respected (not forced to top)"; else bad "pM forced border position"; fi
  bash "$PLUGIN"   # reload must be idempotent — no doubled title/marker
  fmt=$(T show-option -gqv pane-border-format)
  if [ "$(printf '%s' "$fmt" | grep -o MYTITLE | wc -l | tr -d ' ')" = 1 ] && \
     [ "$(printf '%s' "$fmt" | grep -o @minimize_active | wc -l | tr -d ' ')" = 1 ]; then
    ok "pM reload idempotent (marker not doubled)"
  else bad "pM reload doubled the marker: [$fmt]"; fi
}

# --- Part X: exotic setups (zoom, single pane, base-index, deep nesting) ----
part_exotic() {
  local act top p
  # ZOOM: minimizing a background pane must NOT kick you out of zoom; minimizing the
  # zoomed pane itself SHOULD unzoom.
  fresh_server -x 80 -y 40; T split-window -v -t 0; T split-window -v -t 0
  act=$(T list-panes -F '#{?pane_active,#{pane_id},}' | tr -d '\n ')
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  T resize-pane -Z -t "$act"
  bash "$ENGINE" toggle "$top"
  if [ "$(T display-message -p '#{window_zoomed_flag}')" = 1 ]; then ok "pX zoom preserved minimizing a background pane"; else bad "pX lost zoom on background minimize"; fi
  bash "$ENGINE" toggle "$top"
  T resize-pane -Z -t "$act"
  bash "$ENGINE" toggle "$act"
  if [ "$(T display-message -p '#{window_zoomed_flag}')" = 0 ]; then ok "pX unzoomed minimizing the zoomed pane"; else bad "pX stayed zoomed minimizing the zoomed pane"; fi
  assert_live "pX after zoom cases"

  # SINGLE-PANE window: toggling the only pane must produce a valid (no-op-ish) layout.
  fresh_server -x 80 -y 40
  bash "$ENGINE" toggle "$(T list-panes -F '#{pane_id}')"
  assert_live "pX single-pane toggle valid"

  # base-index / pane-base-index non-zero (resurrect keying + general).
  fresh_server -x 80 -y 40 \; set -g base-index 1 \; set -g pane-base-index 1
  T split-window -v; T split-window -v
  bash "$ENGINE" toggle "$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')"
  assert_live "pX base-index toggle valid"

  # DEEP NEST / many panes.
  fresh_server -x 200 -y 60
  T split-window -h; T split-window -v; T split-window -h; T split-window -v; T split-window -h
  for p in $(T list-panes -F '#{pane_id}' | head -4); do bash "$ENGINE" toggle "$p"; done
  assert_live "pX deep-nest minimize valid"
}

# Locate a tmux-resurrect install (env override, common plugin dirs, or the nix store).
find_resurrect() {
  local d
  for d in "${RESURRECT_PATH:-}" \
           "$HOME/.tmux/plugins/tmux-resurrect" \
           "$HOME/.config/tmux/plugins/tmux-resurrect"; do
    [ -n "$d" ] && [ -f "$d/scripts/save.sh" ] && { printf '%s' "$d"; return 0; }
  done
  d=$(ls -d /nix/store/*tmuxplugin-resurrect*/share/tmux-plugins/resurrect 2>/dev/null | head -1)
  [ -n "$d" ] && [ -f "$d/scripts/save.sh" ] && { printf '%s' "$d"; return 0; }
  return 1
}

# --- Part 7: END-TO-END resurrect (drives the REAL resurrect save.sh) --------
# resurrect's restore.sh needs an attached client (it switch-clients / send-keys to
# respawn programs), so it can't run headless. We therefore drive the real save.sh
# (which runs headless and triggers our post-save hook), then reconstruct exactly what
# resurrect's restore PRODUCES — the same panes with the saved window_layout applied —
# and run our restore-state, asserting the minimized state is faithfully re-applied.
part_resurrect_e2e() {
  local res rdir rscripts state saved top f
  res=$(find_resurrect) || { ok "p7 e2e resurrect skipped (resurrect not installed)"; return 0; }

  rdir="/tmp/tmin-rdir-$SOCK"; rscripts="/tmp/tmin-rscripts-$SOCK"; state="/tmp/tmin-e2e-$SOCK"
  rm -rf "$rdir" "$rscripts" "$state"; mkdir -p "$rdir" "$rscripts"
  for f in "$res"/scripts/*.sh; do sed "s|tmux |tmux -L $SOCK |g" "$f" > "$rscripts/$(basename "$f")"; done
  chmod +x "$rscripts"/*.sh

  fresh_server -s work -x 80 -y 40
  T set-option -g @resurrect-dir "$rdir"
  T set-option -g @resurrect-hook-post-save-all "bash '$ENGINE' save-state '$state'"
  T split-window -v -t 0
  top=$(T list-panes -t work -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"
  bash "$ENGINE" minh-set "$top" 6
  saved=$(T display-message -p -t work '#{window_layout}')

  # REAL resurrect save -> writes its dump AND fires our post-save hook.
  bash "$rscripts/save.sh" >/dev/null 2>&1
  if ls "$rdir"/tmux_resurrect_*.txt >/dev/null 2>&1; then ok "p7 real resurrect save produced a dump"; else bad "p7 resurrect save produced no dump"; fi
  if [ -s "$state" ]; then ok "p7 post-save hook wrote our sidecar"; else bad "p7 post-save hook did not write sidecar"; fi

  # Restart: reconstruct what resurrect restore produces (panes + saved layout).
  fresh_server -s work -x 80 -y 40
  T split-window -v -t 0
  T select-layout -t work "$saved"
  bash "$ENGINE" restore-state "$state"

  local nmin; nmin=$(T list-panes -t work -F '#{@minimize_active}' | grep -c 1 || true); : "${nmin:=0}"
  if [ "$nmin" -ge 1 ]; then ok "p7 minimized state restored from real save dump"
  else bad "p7 minimized state NOT restored after e2e cycle"; fi
  local mh; mh=$(T list-panes -t work -F '#{@minimize_minh}' | tr -d '\n ' )
  if printf '%s' "$mh" | grep -q 6; then ok "p7 custom minh ($mh) restored e2e"; else bad "p7 custom minh not restored (got [$mh])"; fi
  assert_live "p7 e2e layout valid"

  rm -rf "$rdir" "$rscripts" "$state"
}

main() {
  part1
  part1_stale
  part2
  part3
  part_minh
  part_minw
  part_narrow_toggle
  part_narrow_off_widths
  part_minimize_others
  part_dragend_absorber
  part_peek
  part_peek_floor
  part_resize_window
  part_marker
  part_exotic
  part_resurrect
  part_resurrect_e2e
  summary "live_sequences"
}

main
