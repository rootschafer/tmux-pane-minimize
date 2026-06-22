# shellcheck shell=bash
# Shared helpers for the test suites. Source me.
#
# Bash 3.2 compatible (macOS /bin/bash). No associative arrays, no `local x=$(...)`
# under set -u on a single declare line, POSIX awk/sort/tr only.

PASS=0
FAIL=0
FAILLOG=""

# ok MESSAGE   -- record a pass (quiet unless $VERBOSE)
ok() {
  PASS=$((PASS + 1))
  [ "${VERBOSE:-0}" = 1 ] && printf 'ok   %s\n' "$1"
  return 0
}

# bad MESSAGE  -- record a failure (always printed)
bad() {
  FAIL=$((FAIL + 1))
  FAILLOG="$FAILLOG
FAIL $1"
  printf 'FAIL %s\n' "$1" >&2
  return 0
}

# summary NAME -- print totals; exit nonzero if any failure
summary() {
  printf '\n%s: %d passed, %d failed\n' "${1:-suite}" "$PASS" "$FAIL"
  if [ "$FAIL" -ne 0 ]; then
    printf '%s\n' "$FAILLOG" >&2
    return 1
  fi
  return 0
}
