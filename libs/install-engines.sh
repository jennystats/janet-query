#!/bin/bash
# install-engines.sh - build both native engines the query backends need:
# libduckdb (janet-duckdb) and librayforce (janet-rayforce). Runs each
# vendored installer; both are idempotent. Deps: curl, unzip, gcc, make
# (rayforce), tar.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/install-duckdb.sh"
bash "$DIR/install-rayforce.sh"
