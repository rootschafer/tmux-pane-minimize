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

SOCK="tmin_test_$$"
ENGINE="/tmp/tmin-engine-$SOCK.sh"
PLUGIN="/tmp/tmin-plugin-$SOCK.tmux"

T() { tmux -L "$SOCK" "$@"; }

cleanup() { tmux -L "$SOCK" kill-server >/dev/null 2>&1; rm -f "$ENGINE" "$PLUGIN"; }
trap cleanup EXIT INT TERM

# Socket-patch the engine and plugin so bare `tmux ` talks to our sandbox, and the
# plugin's hooks invoke the patched engine.
sed "s|tmux |tmux -L $SOCK |g" "$LS_DIR/../scripts/tmux-min.sh" > "$ENGINE"
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
  T kill-server >/dev/null 2>&1
  T new-session -d -x 222 -y 61
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
  T kill-server >/dev/null 2>&1
  T new-session -d -x 222 -y 61
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
  T kill-server >/dev/null 2>&1
  T new-session -d -x 80 -y 40
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
  : "$panes"  # silence unused in some shells
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
  local eng2 racelog win max
  eng2="/tmp/tmin-engine2-$SOCK.sh"
  racelog="/tmp/tmin-race-$SOCK.log"
  : > "$racelog"
  awk -v lf="$racelog" '
    /^apply\(\) \{/ { print; getline; print; print "  echo \"E $$\" >> \"" lf "\""; next }
    /select-layout -t "\$win" "\$new"/ {
      print "  echo \"S $$\" >> \"" lf "\""; print; print "  echo \"X $$\" >> \"" lf "\""; next
    }
    { print }
  ' "$ENGINE" > "$eng2"

  build_bugshape
  win=$(T display-message -p '#{window_id}')
  bash "$eng2" toggle "$P_RTOP"     # minimize one pane
  assert_live "p3 pre-burst"

  # Concurrent burst: many repin (each runs apply) racing on the same window.
  local r=0
  while [ "$r" -lt 50 ]; do bash "$eng2" repin "$win" & r=$((r + 1)); done
  wait
  T run-shell "true" >/dev/null 2>&1
  assert_live "p3 post-burst (race exposer: valid layout, no zero pane)"

  max=$(awk '$1=="E"{a++; if(a>m)m=a} $1=="X"{a--} END{print m+0}' "$racelog")
  if [ "$max" -le 3 ]; then ok "p3 applies serialized (max concurrent=$max)"
  else bad "p3 NOT serialized: max concurrent apply=$max (guard race?)"; fi

  rm -f "$eng2" "$racelog"
}

main() {
  part1
  part1_stale
  part2
  part3
  summary "live_sequences"
}

main
