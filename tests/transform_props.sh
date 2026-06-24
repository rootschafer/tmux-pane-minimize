#!/usr/bin/env bash
# Offline property suite — the bulk of coverage, 100% deterministic.
#
# transform() is a PURE function of (layout, MINSET, SAVEDW, WPANE, WVAL): no tmux,
# no RNG, no time. We exploit that:
#   for every generated layout
#     for every MINSET subset of its leaves
#       call transform with no restore pane            -> assert invariants
#       for every leaf as WPANE (un-minimize/peek target)
#         for every WVAL in {0,1,MIN_H,mid,overflow}   -> assert invariants
#
# "Assert invariants" = pipe the emitted layout through check_layout (assert_layout.sh):
# every box >=1 (FAIL on any 0), sums+borders==parent, contiguous, checksum valid.
#
# Run under /bin/bash to enforce the macOS bash 3.2 constraint:
#     /bin/bash tests/transform_props.sh
#
# Env knobs: VERBOSE=1 prints each ok; QUICK=1 skips the WPANE/WVAL inner sweep.

set -u
TP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source the PURE transform layer directly — it has no tmux calls, so this is hermetic
# by construction (no stub needed). Then pin MIN_H/MIN_W for deterministic geometry
# regardless of host config.
# shellcheck source=/dev/null
. "$TP_DIR/../scripts/transform.sh"
# MIN_H/MIN_W are consumed by transform() via globals.
# shellcheck disable=SC2034
MIN_H=3
# shellcheck disable=SC2034
MIN_W=15

# shellcheck source=/dev/null
. "$TP_DIR/assert_layout.sh"
# shellcheck source=/dev/null
. "$TP_DIR/lib.sh"

WVALS="0 1 3 9 1000"   # degenerate, min, MIN_H, mid, overflow(>any window H)

# check_one DESC LAYOUT MINSET SAVEDW WPANE WVAL [MINH]
check_one() {
  local desc="$1" layout="$2" minset="$3" savedw="$4" wpane="$5" wval="$6" minh="${7:- }" out
  out=$(transform "$layout" "$minset" "$savedw" "$wpane" "$wval" "$minh")
  if check_layout "$out"; then
    ok "$desc"
  else
    # AL_ERR is set by check_layout in the sourced assert_layout.sh
    # shellcheck disable=SC2154
    bad "$desc :: $AL_ERR
      in  : $layout
      min : [$minset] savedw=[$savedw] wpane=[$wpane] wval=$wval minh=[$minh]
      out : $out"
  fi
}

# Enumerate every subset of a space-delimited leaf list; emit each as " a b ".
# Bash 3.2: no associative arrays; iterate bitmask 0..2^k-1 (k<=4 -> <=16).
# run_subsets LAYOUT LEAVES [plain_only]
# plain_only=1 runs ONLY the plain-minimize subset check (used for the border-status
# edge-bonus passes, to keep that 3x multiplier cheap).
run_subsets() {
  local layout="$1" leaves="$2" plain_only="${3:-0}"
  local arr k mask i sub bit savedw wpane lo wv mh
  # shellcheck disable=SC2206
  arr=($leaves)
  k=${#arr[@]}
  mask=0
  while [ "$mask" -lt $((1 << k)) ]; do
    sub=" "; i=0
    while [ "$i" -lt "$k" ]; do
      bit=$((1 << i))
      [ $((mask & bit)) -ne 0 ] && sub="$sub${arr[$i]} "
      i=$((i + 1))
    done

    # 1) plain minimize, no restore pane
    check_one "subset[$sub] bp=$BORDER_POS" "$layout" "$sub" " " "" 0

    if [ "$plain_only" != 1 ]; then
      # 1b) per-pane custom minimized height: give each minimized pane in the subset a
      #     custom @minimize_minh over extremes {1, MIN_H, mid, overflow}. Bounded so it
      #     doesn't blow up runtime; reconcile must keep every result valid.
      for lo in "${arr[@]}"; do
        case " $sub " in *" $lo "*) ;; *) continue ;; esac   # only minimized panes
        for mh in 1 3 30 999; do
          check_one "subset[$sub] minh=$lo:$mh" "$layout" "$sub" " " "" 0 " ${lo}:${mh} "
        done
      done

      # 2) un-minimize/peek: every leaf as WPANE x every WVAL extreme.
      #    Also exercise a SAVEDW entry (saved pre-narrow width) for that pane.
      if [ "${QUICK:-0}" != 1 ]; then
        for lo in "${arr[@]}"; do
          savedw=" ${lo}:80 "
          for wv in $WVALS; do
            check_one "subset[$sub] wpane=$lo wval=$wv" "$layout" "$sub" "$savedw" "$lo" "$wv"
          done
        done
      fi
    fi
    mask=$((mask + 1))
  done
}

# Edge/robustness sweep: malformed or unusual layout strings must NOT crash the parser.
# Regression for the `NT[$id]: unbound variable` bug — when parse_cell met a cell whose
# next char was neither ',' nor '{'/'[' it left NT[$id] unset, and `${NT[$id]}` then
# CRASHED under `set -u` on bash 4.4+/5.x (bash 3.2 read it as empty, so it hid locally
# while CI on newer bash failed). We only assert no-crash (subshell exits 0) + non-empty
# output; the geometry of a degraded/malformed input may be imperfect, which reconcile +
# select-layout tolerate. transform() runs in the $(...) subshell, so a set -u abort exits
# THAT subshell (rc!=0 / empty out), not this script.
edge_cases() {
  local layout out rc
  for layout in \
    '0000,80x24,0,0' \
    '0000,80x24,0,0,' \
    '0000,1x1,0,0,1' \
    '0000,5x5,0,0[5x2,0,0,1,5x2,0,3,2]' \
    '0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}' ; do
    out=$(transform "$layout" " 1 2 " 2>/dev/null); rc=$?
    if [ "$rc" = 0 ] && [ -n "$out" ]; then ok "edge no-crash: $layout"
    else bad "edge CRASH (rc=$rc) under set -u on: $layout -> [$out]"; fi
  done
}

# Regression: a genuine flex pane (never minimized, and not the restore/peek pane) must keep
# a FAIR share when a restore pane has a large/stale saved height — it must not collapse below
# MIN_H while the window can afford it. This is the "non-minimized pane in a mostly-minimized
# column squished to ~1 row" bug. gen_layouts stops at 4 leaves, so 5+-pane columns (where it
# shows up) aren't otherwise exercised.
restore_fairness() {
  local L out h wval
  L="0000,100x50,0,0[100x10,0,0,0,100x9,0,11,1,100x9,0,21,2,100x9,0,31,3,100x9,0,41,4]"
  for wval in 6 20 40 1000; do
    out=$(transform "$L" " 0 1 3 " " " 4 "$wval" " ")    # 0,1,3 minimized; 2 flex; 4 = restore
    h=$(printf '%s' "$out" | grep -oE "100x[0-9]+,0,[0-9]+,2," | grep -oE "x[0-9]+" | tr -d x)
    if check_layout "$out" && [ -n "$h" ] && [ "$h" -ge "$MIN_H" ]; then
      ok "restore fairness: flex pane keeps >=MIN_H vs restore wval=$wval (h=$h)"
    else
      bad "restore fairness: flex pane collapsed (wval=$wval h=$h) :: $out"
    fi
  done
}

# Peek-expansion / floor model: in a column where every pane but the peeked one is minimized,
# the peek EXPANDS toward its saved height by shrinking the minimized panes toward ABS_MIN_H
# — but never below it, and the peek is capped once they all reach the floor. Also exercises
# the @minimize-absolute-min-height option (ABS_MIN_H) at 1 and 2.
peek_expansion() {
  local L out hpk lo abs
  local saveabs=$ABS_MIN_H
  BORDER_POS=off
  # 6-pane column, short window y=20 (content budget 15 after 5 borders); peek pane5 wants 100.
  L="0000,100x20,0,0[100x3,0,0,0,100x3,0,4,1,100x3,0,8,2,100x1,0,12,3,100x1,0,14,4,100x3,0,16,5]"
  for abs in 1 2; do
    ABS_MIN_H=$abs
    out=$(transform "$L" " 0 1 2 3 4 " " " 5 100 " ")
    lo=$(printf '%s' "$out" | grep -oE "100x[0-9]+,0,[0-9]+,[0-4]" | grep -oE "x[0-9]+" | tr -d x | sort -n | head -1)
    hpk=$(printf '%s' "$out" | grep -oE "100x[0-9]+,0,[0-9]+,5" | grep -oE "x[0-9]+" | tr -d x)
    if check_layout "$out" && [ -n "$lo" ] && [ "$lo" -ge "$abs" ] && [ -n "$hpk" ] && [ "$hpk" -gt "$abs" ]; then
      ok "peek expansion: ABS_MIN_H=$abs -> minimized floor held (min=$lo), peek expanded+capped (h=$hpk)"
    else
      bad "peek expansion ABS_MIN_H=$abs: min=$lo hpk=$hpk :: $out"
    fi
  done
  ABS_MIN_H=$saveabs
  # A modest saved height restores EXACTLY when the column has room.
  L="0000,100x50,0,0[100x10,0,0,0,100x9,0,11,1,100x9,0,21,2,100x9,0,31,3,100x9,0,41,4]"
  out=$(transform "$L" " 0 1 3 " " " 4 8 " ")
  hpk=$(printf '%s' "$out" | grep -oE "100x[0-9]+,0,[0-9]+,4" | grep -oE "x[0-9]+" | tr -d x)
  if check_layout "$out" && [ "$hpk" = 8 ]; then ok "peek expansion: modest saved height restores exactly (h=8)"
  else bad "peek expansion: modest restore not exact (h=$hpk)"; fi
}

main() {
  local lay leaves
  while IFS="$(printf '\t')" read -r lay leaves; do
    [ -z "$lay" ] && continue
    BORDER_POS=off; run_subsets "$lay" "$leaves"
    # Edge-bonus coverage: with the border-status line on, first/last minimized panes in
    # a vertical split get +1. Re-run the (cheap) plain-minimize subset sweep for each.
    BORDER_POS=top;    run_subsets "$lay" "$leaves" 1
    BORDER_POS=bottom; run_subsets "$lay" "$leaves" 1
  done < <(/bin/bash "$TP_DIR/gen_layouts.sh")
  BORDER_POS=off
  edge_cases
  restore_fairness
  peek_expansion
  summary "transform_props (offline)"
}

main
