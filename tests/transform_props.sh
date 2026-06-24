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
  summary "transform_props (offline)"
}

main
