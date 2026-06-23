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
  local eng2 busy coll win r
  eng2="/tmp/tmin-engine2-$SOCK.sh"
  busy="/tmp/tmin-busy-$SOCK"          # the mutual-exclusion marker dir
  coll="/tmp/tmin-coll-$SOCK"          # collision log
  : > "$coll"; rmdir "$busy" 2>/dev/null
  # TRUE overlap detector (not log-order sensitive): each apply mkdir's a shared marker
  # at entry; the mkdir can only FAIL if another apply already holds it -> a real
  # overlap. rmdir at the end of the critical section. With the per-window lock this
  # must never collide.
  awk -v busy="$busy" -v coll="$coll" '
    /^apply\(\) \{/ { print; getline; print; print "  mkdir \"" busy "\" 2>/dev/null || echo OVERLAP >> \"" coll "\""; next }
    /select-layout -t "\$win" "\$new"/ { print; print "  rmdir \"" busy "\" 2>/dev/null"; next }
    { print }
  ' "$ENGINE" > "$eng2"

  build_bugshape
  win=$(T display-message -p '#{window_id}')
  bash "$eng2" toggle "$P_RTOP"        # minimize one pane
  assert_live "p3 pre-burst"

  # Realistic concurrent burst (focus/resize hooks are only a few deep in practice).
  r=0
  while [ "$r" -lt 16 ]; do bash "$eng2" repin "$win" & r=$((r + 1)); done
  wait
  T run-shell "true" >/dev/null 2>&1
  assert_live "p3 post-burst (race exposer: valid layout, no zero pane)"

  # The mkdir lock is best-effort serialization (a killed holder is reclaimed; under
  # pathological contention a sub-millisecond reclaim window can still slip one through).
  # reconcile guarantees every layout is valid regardless, so the goal here is to catch a
  # REGRESSION to the old global-guard race (which overlapped dozens), not to prove a
  # perfect mutex. Tolerate up to 2; a broken lock produces far more.
  local n; n=$(grep -c OVERLAP "$coll" 2>/dev/null || true); : "${n:=0}"
  if [ "$n" -le 2 ]; then ok "p3 applies serialized ($n overlaps over 16 concurrent, <=2 ok)"
  else bad "p3 NOT serialized: $n overlapping applies (guard race regression?)"; fi

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
  T kill-server >/dev/null 2>&1
  T new-session -d -x 80 -y 40
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

# --- Part 5: dashboard (minimize all but active) ----------------------------
part_dashboard() {
  local win act orig now nmin top bot dflag

  T kill-server >/dev/null 2>&1
  T new-session -d -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0; T split-window -v -t 0   # 4 panes
  win=$(T display-message -p '#{window_id}')
  act=$(T list-panes -F '#{?pane_active,#{pane_id},}' | tr -d '\n ')
  orig=$(T display-message -p '#{window_layout}')
  assert_live "p5 initial 4 panes"

  bash "$ENGINE" dashboard "$act"
  assert_live "p5 dashboard entered"
  nmin=$(T list-panes -F '#{@minimize_active}' | grep -c 1 || true); : "${nmin:=0}"
  if [ "$nmin" = 3 ]; then ok "p5 3 non-active panes minimized"; else bad "p5 minimized count=$nmin (expected 3)"; fi

  bash "$ENGINE" dashboard "$act"
  now=$(T display-message -p '#{window_layout}')
  if [ "$orig" = "$now" ]; then ok "p5 exact layout restore on exit"; else bad "p5 not restored:
    orig=$orig
    now =$now"; fi
  nmin=$(T list-panes -F '#{@minimize_active}' | grep -c 1 || true); : "${nmin:=0}"
  if [ "$nmin" = 0 ]; then ok "p5 all flags cleared on exit"; else bad "p5 $nmin panes still minimized after exit"; fi
  assert_live "p5 dashboard exited"

  # A pane the user minimized BEFORE entering dashboard must survive the round trip.
  T kill-server >/dev/null 2>&1
  T new-session -d -x 80 -y 40
  T split-window -v -t 0; T split-window -v -t 0                          # 3 panes
  top=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | head -1 | awk '{print $2}')
  bot=$(T list-panes -F '#{pane_top} #{pane_id}' | sort -n | tail -1 | awk '{print $2}')
  bash "$ENGINE" toggle "$top"           # user-minimize the top pane
  T select-pane -t "$bot"
  bash "$ENGINE" dashboard "$bot"        # enter dashboard from bottom
  dflag=$(T show-options -t "$top" -pqv @minimize_dashboard 2>/dev/null || true)
  if [ -z "$dflag" ]; then ok "p5 pre-minimized pane not dashboard-flagged"; else bad "p5 pre-min pane wrongly flagged"; fi
  bash "$ENGINE" dashboard "$bot"        # exit dashboard
  if [ "$(T display-message -p -t "$top" '#{?@minimize_active,1,0}')" = 1 ]; then
    ok "p5 pre-minimized pane still minimized after exit"
  else bad "p5 pre-minimized pane lost its minimized state"; fi
  assert_live "p5 pre-minimized preserved"
}

# --- Part 6: tmux-resurrect persistence (save-state/restore-state) -----------
part_resurrect() {
  local top bot state a minh p
  state="/tmp/tmin-state-$SOCK"
  T kill-server >/dev/null 2>&1
  T new-session -d -s rs -x 80 -y 40
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
}

# --- Part 8: peek-on-focus (peekin/peekout) + resize-while-peeked save ------
part_peek() {
  local top bot h saved
  T kill-server >/dev/null 2>&1
  T new-session -d -x 80 -y 40
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

# --- Part 9: after-resize-window repins minimized panes ---------------------
# The hook firing on resize is tmux's guarantee; we deterministically verify (a) the
# hook is wired to repin, and (b) repin re-pins a pane that a window resize rescaled.
part_resize_window() {
  local top h hook
  T kill-server >/dev/null 2>&1
  T new-session -d -x 80 -y 40
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

  T kill-server >/dev/null 2>&1
  T new-session -d -s work -x 80 -y 40
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
  T kill-server >/dev/null 2>&1
  T new-session -d -s work -x 80 -y 40
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
  part_dashboard
  part_peek
  part_resize_window
  part_resurrect
  part_resurrect_e2e
  summary "live_sequences"
}

main
