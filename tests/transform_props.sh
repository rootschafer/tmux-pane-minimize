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

# Hermetic: stub tmux so sourcing the engine never touches a live server, then
# pin MIN_H/MIN_W for deterministic geometry regardless of host config.
tmux() { return 0; }
# shellcheck source=/dev/null
. "$TP_DIR/../scripts/tmux-min.sh"
unset -f tmux
# MIN_H/MIN_W are consumed by the sourced engine's transform() via globals.
# shellcheck disable=SC2034
MIN_H=3
# shellcheck disable=SC2034
MIN_W=15

# shellcheck source=/dev/null
. "$TP_DIR/assert_layout.sh"
# shellcheck source=/dev/null
. "$TP_DIR/lib.sh"

WVALS="0 1 3 9 1000"   # degenerate, min, MIN_H, mid, overflow(>any window H)

# check_one DESC LAYOUT MINSET SAVEDW WPANE WVAL
check_one() {
  local desc="$1" layout="$2" minset="$3" savedw="$4" wpane="$5" wval="$6" out
  out=$(transform "$layout" "$minset" "$savedw" "$wpane" "$wval")
  if check_layout "$out"; then
    ok "$desc"
  else
    # AL_ERR is set by check_layout in the sourced assert_layout.sh
    # shellcheck disable=SC2154
    bad "$desc :: $AL_ERR
      in  : $layout
      min : [$minset] savedw=[$savedw] wpane=[$wpane] wval=$wval
      out : $out"
  fi
}

# Enumerate every subset of a space-delimited leaf list; emit each as " a b ".
# Bash 3.2: no associative arrays; iterate bitmask 0..2^k-1 (k<=4 -> <=16).
run_subsets() {
  local layout="$1" leaves="$2"
  local arr k mask i sub bit savedw wpane lo wv
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
    check_one "subset[$sub]" "$layout" "$sub" " " "" 0

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
    mask=$((mask + 1))
  done
}

main() {
  local lay leaves
  while IFS="$(printf '\t')" read -r lay leaves; do
    [ -z "$lay" ] && continue
    run_subsets "$lay" "$leaves"
  done < <(/bin/bash "$TP_DIR/gen_layouts.sh")
  summary "transform_props (offline)"
}

main
