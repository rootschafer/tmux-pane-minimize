#!/usr/bin/env bash
# Regenerate the native cargo-test oracle cases in engine-rs/src/lib.rs (the `CASES` table).
#
# Each case is run through the BASH oracle (scripts/transform.sh via transform_cli.sh) and
# emitted as a Rust tuple `((args...), "expected")`. Run this only after an INTENTIONAL change
# to the bash engine, then paste the output into the CASES table. The differential suite
# (tests/diff_test.sh) is the exhaustive check; these are a fast, bash-free regression set.
#
#   /bin/bash tests/gen_oracle_cases.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DRV="$DIR/transform_cli.sh"

SEL='02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}'
RF='0000,100x50,0,0[100x10,0,0,0,100x9,0,11,1,100x9,0,21,2,100x9,0,31,3,100x9,0,41,4]'
PE='0000,100x20,0,0[100x3,0,0,0,100x3,0,4,1,100x3,0,8,2,100x1,0,12,3,100x1,0,14,4,100x3,0,16,5]'

emit() {  # label  MIN_H MIN_W ABS_MIN_H BORDER_POS LAYOUT MINSET SAVEDW WPANE WVAL MINH
  local label="$1"; shift
  local out; out=$(/bin/bash "$DRV" "$@")
  printf '        // %s\n        ((%s, %s, %s, "%s", "%s", "%s", "%s", "%s", %s, "%s"), "%s"),\n' \
    "$label" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "$out"
}

emit "h-split, minimize pane 1"            3 15 1 off "0000,80x24,0,0{39x24,0,0,1,40x24,41,0,2}" " 1 " " " "" 0 " "
emit "v-split, minimize pane 1"            3 15 1 off "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]" " 1 " " " "" 0 " "
emit "empty minset (no-op reflow)"         3 15 1 off "0000,80x24,0,0{39x24,0,0,1,40x24,41,0,2}" " " " " "" 0 " "
emit "single leaf"                         3 15 1 off "0000,80x24,0,0,1" " 1 " " " "" 0 " "
emit "full v-stack min -> width collapse"  3 30 1 off "$SEL" " 96 98 97 " " " "" 0 " "
emit "height-only nested min (96,97)"      3 30 1 off "$SEL" " 96 97 " " " "" 0 " "
emit "per-pane custom minh 96:10"          3 30 1 off "$SEL" " 96 97 " " " "" 0 " 96:10 "
emit "border-pos top edge bonus"           3 15 1 top "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]" " 1 " " " "" 0 " "
emit "border-pos bottom edge bonus"        3 15 1 bottom "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]" " 2 " " " "" 0 " "
emit "peek/unminimize wval=10"             3 15 1 off "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]" " 1 2 " " 1:80 " 1 10 " "
emit "restore fairness wval=20"            3 15 1 off "$RF" " 0 1 3 " " " 4 20 " "
emit "peek expansion abs_min_h=2"          3 15 2 off "$PE" " 0 1 2 3 4 " " " 5 100 " "
emit "savedw width restore"                3 30 1 off "$SEL" " 96 98 97 " " 96:120 " "" 0 " "
emit "i32-overflow regression (vsplit)"    3 15 1 off "0000,60000x60000,0,0[60000x59996,0,0,1,60000x1,0,59997,2]" " " " " "" 0 " "
emit "i32-overflow regression (hsplit)"    3 15 1 off "0000,60000x60000,0,0{59996x60000,0,0,1,1x60000,59997,0,2}" " " " " "" 0 " "
emit "parse trailing-comma regression"     3 15 1 off "0000,10x10,0,0{5x10,0,0,1,5x10,6,0,2," " " " " "" 0 " "
emit "all-columns-minimized (no flex)"     3 15 1 off "0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}" " 1 2 " " " "" 0 " "
emit "tiny window degrade"                 3 15 1 off "0000,4x4,0,0[4x2,0,0,1,4x1,0,3,2]" " 1 2 " " " "" 0 " "
