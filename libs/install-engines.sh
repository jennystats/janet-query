#!/bin/bash
# install-engines.sh - build the three native libraries the query backends
# and their dependencies need: libduckdb (janet-duckdb), librayforce
# (janet-rayforce), and libjn.so (janet-num - janet-duckdb imports
# jennystats/num for the packed feeds). Runs each vendored/fetched
# installer; all are idempotent. Deps: curl, unzip, gcc, make (rayforce),
# tar.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/install-duckdb.sh"
bash "$DIR/install-rayforce.sh"

# janet-num's libjn.so: janet-duckdb imports jennystats/num, and num's
# kernels are a C library the jpm install does not carry. The C source is
# fetched at a pinned janet-num commit; the installer sha256-verifies it
# before compiling, so a drift upstream is a hard failure here.
JN_COMMIT="769b8390b518202d6860ccf32b58989fec461343"
JN_DIR="$(mktemp -d)"
trap 'rm -rf "$JN_DIR"' EXIT
curl -fsSLo "$JN_DIR/janet-num.c" \
  "https://raw.githubusercontent.com/jennystats/janet-num/${JN_COMMIT}/libs/janet-num.c"
curl -fsSLo "$JN_DIR/install-janet-num.sh" \
  "https://raw.githubusercontent.com/jennystats/janet-num/${JN_COMMIT}/libs/install-janet-num.sh"
bash "$JN_DIR/install-janet-num.sh"
