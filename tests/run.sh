#!/usr/bin/env bash
# Run the whole test harness. Always runs the offline suites; runs the live suite
# only when tmux is available. Honours the macOS bash 3.2 constraint by invoking
# every suite through /bin/bash.
#
#   tests/run.sh            # offline + live
#   QUICK=1 tests/run.sh    # offline: skip the WPANE/WVAL inner sweep (fast)
#
# Exit nonzero if any suite fails.

set -u
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BASH32=/bin/bash
[ -x "$BASH32" ] || BASH32="$(command -v bash)"

rc=0

echo "### bash syntax check"
for f in "$RUN_DIR"/../scripts/tmux-min.sh "$RUN_DIR"/../pane-minimize.tmux "$RUN_DIR"/*.sh; do
  "$BASH32" -n "$f" || { echo "SYNTAX FAIL: $f"; rc=1; }
done

echo
echo "### offline property suite"
"$BASH32" "$RUN_DIR/transform_props.sh" || rc=1

echo
echo "### live sequence + fuzz + race suite"
if command -v tmux >/dev/null 2>&1; then
  "$BASH32" "$RUN_DIR/live_sequences.sh" || rc=1
else
  echo "tmux not found — skipping live suite"
fi

echo
if [ "$rc" -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "SUITE FAILURES (see above)"; fi
exit "$rc"
