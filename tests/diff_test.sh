#!/usr/bin/env bash
# Differential test between transform_cli.sh (bash) and tmux-min-transform (Rust)
set -eu

DT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BASH_DRIVER="$DT_DIR/transform_cli.sh"
RUST_BIN="$DT_DIR/../target/release/tmux-min-transform"

# Build Rust binary first (cargo workspace; build from the repo root)
(cd "$DT_DIR/.." && cargo build --release)

MIN_H=3
MIN_W=15
WVALS="0 1 3 9 1000"

PASSED=0
FAILED=0

# diff_one BORDER_POS ABS_MIN_H LAYOUT MINSET SAVEDW WPANE WVAL MINH [MINW]
diff_one() {
  local bp="$1" abs_min_h="$2" layout="$3" minset="$4" savedw="$5" wpane="$6" wval="$7" minh="$8" minw="${9:- }"

  # Run bash driver
  local out_bash
  out_bash=$("$BASH_DRIVER" "$MIN_H" "$MIN_W" "$abs_min_h" "$bp" "$layout" "$minset" "$savedw" "$wpane" "$wval" "$minh" "$minw")

  # Run rust binary
  local out_rust
  out_rust=$("$RUST_BIN" "$MIN_H" "$MIN_W" "$abs_min_h" "$bp" "$layout" "$minset" "$savedw" "$wpane" "$wval" "$minh" "$minw")
  
  if [ "$out_bash" = "$out_rust" ]; then
    PASSED=$((PASSED + 1))
    if [ "${VERBOSE:-0}" = 1 ]; then
      echo "OK: bp=$bp abs_min_h=$abs_min_h minset=[$minset] savedw=[$savedw] wpane=[$wpane] wval=$wval minh=[$minh] -> $out_bash"
    fi
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: bp=$bp abs_min_h=$abs_min_h minset=[$minset] savedw=[$savedw] wpane=[$wpane] wval=$wval minh=[$minh]"
    echo "  bash: $out_bash"
    echo "  rust: $out_rust"
    exit 1
  fi
}

run_subsets() {
  local layout="$1" leaves="$2" plain_only="${3:-0}" bp="$4" abs_min_h="$5"
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
    diff_one "$bp" "$abs_min_h" "$layout" "$sub" " " "" 0 " "

    if [ "$plain_only" != 1 ]; then
      # 1b) per-pane custom minimized height
      for lo in "${arr[@]}"; do
        case " $sub " in *" $lo "*) ;; *) continue ;; esac
        for mh in 1 3 30 999; do
          diff_one "$bp" "$abs_min_h" "$layout" "$sub" " " "" 0 " ${lo}:${mh} "
        done
      done

      # 2) un-minimize/peek
      if [ "${QUICK:-0}" != 1 ]; then
        for lo in "${arr[@]}"; do
          savedw=" ${lo}:80 "
          for wv in $WVALS; do
            diff_one "$bp" "$abs_min_h" "$layout" "$sub" "$savedw" "$lo" "$wv" " "
          done
        done
      fi
    fi
    mask=$((mask + 1))
  done
}

echo "Running differential testing..."

while IFS="$(printf '\t')" read -r lay leaves; do
  [ -z "$lay" ] && continue
  
  run_subsets "$lay" "$leaves" 0 off 1
  run_subsets "$lay" "$leaves" 1 top 1
  run_subsets "$lay" "$leaves" 1 bottom 1
done < <(/bin/bash "$DT_DIR/gen_layouts.sh")

# Run edge cases
echo "Running edge cases..."
for layout in \
  '0000,80x24,0,0' \
  '0000,80x24,0,0,' \
  '0000,1x1,0,0,1' \
  '0000,5x5,0,0[5x2,0,0,1,5x2,0,3,2]' \
  '0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}' ; do
  diff_one off 1 "$layout" " 1 2 " " " "" 0 " "
done

# Run restore fairness
echo "Running restore fairness..."
L="0000,100x50,0,0[100x10,0,0,0,100x9,0,11,1,100x9,0,21,2,100x9,0,31,3,100x9,0,41,4]"
for wval in 6 20 40 1000; do
  diff_one off 1 "$L" " 0 1 3 " " " 4 "$wval" " "
done

# Run peek expansion
echo "Running peek expansion..."
L="0000,100x20,0,0[100x3,0,0,0,100x3,0,4,1,100x3,0,8,2,100x1,0,12,3,100x1,0,14,4,100x3,0,16,5]"
for abs in 1 2; do
  diff_one off "$abs" "$L" " 0 1 2 3 4 " " " 5 100 " "
done
L="0000,100x50,0,0[100x10,0,0,0,100x9,0,11,1,100x9,0,21,2,100x9,0,31,3,100x9,0,41,4]"
diff_one off 1 "$L" " 0 1 3 " " " 4 8 " "

# Custom minimized group WIDTH (MINW, the 9th diff_one arg). A fully-minimized vertical
# stack in an h-split should narrow to the group's custom width instead of MIN_W; sweep
# several widths and confirm bash and Rust agree (and that a non-fully-min group ignores it).
echo "Running custom group width..."
WL="0000,200x60,0,0{120x60,0,0,0[120x20,0,0,1,120x19,0,21,2,120x19,0,41,3],79x60,121,0[79x30,121,0,4,79x29,121,31,5]}"
for mw in 10 25 50 99 200; do
  # right column (4,5) fully minimized -> narrows to custom width $mw
  diff_one off 1 "$WL" " 4 5 " " " "" 0 " " " 4:${mw} "
  # left column (1,2,3) fully minimized too -> both narrow
  diff_one off 1 "$WL" " 1 2 3 4 5 " " " "" 0 " " " 1:${mw} 4:${mw} "
  # not fully minimized -> custom width must be ignored
  diff_one off 1 "$WL" " 4 " " " "" 0 " " " 4:${mw} "
done
# two independent fully-minimized groups (col1=1,2 col2=3,4) beside a flexible leaf (0):
# each group narrows to its OWN custom width; the leaf absorbs the rest.
ML="0000,200x60,0,0{98x60,0,0,0,50x60,99,0[50x30,99,0,1,50x29,99,31,2],50x60,150,0[50x30,150,0,3,50x29,150,31,4]}"
diff_one off 1 "$ML" " 1 2 3 4 " " " "" 0 " " " 1:30 3:60 "
diff_one off 1 "$ML" " 1 2 3 4 " " " "" 0 " " " 1:60 3:20 "

echo "DIFFERENTIAL TESTS PASSED: $PASSED cases compared successfully."
