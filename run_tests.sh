#!/bin/sh
# run_tests.sh - janet-query suite. SKIP semantics: absent engines skip,
# present-but-broken is a FAIL, never a skip. The core smoke is engine-free
# and always runs.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "$JANET_PATH" ] || export JANET_PATH="$HOME/.local/lib/janet"
export JANET_PATH="$DIR:$JANET_PATH"

has_duckdb() { [ -n "$DUCKDB_LIB" ] || [ -f "$HOME/.local/lib/duckdb/libduckdb.so" ] || ldconfig -p 2>/dev/null | grep -q libduckdb; }
has_rayforce() { [ -n "$RAYFORCE_LIB" ] || [ -f "$HOME/.local/lib/rayforce/librayforce.so" ]; }

fail=0
if janet "$DIR/test/smoke-query.janet" > /dev/null 2>&1; then
  echo "PASS smoke-query.janet (core, engine-free)"
else
  echo "FAIL smoke-query.janet"
  janet "$DIR/test/smoke-query.janet"
  fail=1
fi

if has_duckdb; then
  if janet "$DIR/test/smoke-query-duckdb.janet" > /dev/null 2>&1; then
    echo "PASS smoke-query-duckdb.janet"
  else
    echo "FAIL smoke-query-duckdb.janet"
    janet "$DIR/test/smoke-query-duckdb.janet"
    fail=1
  fi
else
  echo "SKIP smoke-query-duckdb.janet (no libduckdb - run libs/install-engines.sh)"
fi

if has_rayforce; then
  if janet "$DIR/test/smoke-query-rayforce.janet" > /dev/null 2>&1; then
    echo "PASS smoke-query-rayforce.janet"
  else
    echo "FAIL smoke-query-rayforce.janet"
    janet "$DIR/test/smoke-query-rayforce.janet"
    fail=1
  fi
else
  echo "SKIP smoke-query-rayforce.janet (no librayforce - run libs/install-engines.sh)"
fi

if has_duckdb && has_rayforce; then
  if (cd "$DIR" && janet test/suite-query-chinook.janet > /dev/null 2>&1); then
    echo "PASS suite-query-chinook.janet"
  else
    echo "FAIL suite-query-chinook.janet"
    (cd "$DIR" && janet test/suite-query-chinook.janet)
    fail=1
  fi
else
  echo "SKIP suite-query-chinook.janet (needs both engines - run libs/install-engines.sh)"
fi

if [ "$fail" -eq 0 ]; then echo "RESULT: pass"; else echo "RESULT: fail"; exit 1; fi
