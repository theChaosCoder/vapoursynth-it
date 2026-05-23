#!/usr/bin/env bash
# Build the API-4-ported upstream reference plugin.
#
# Result: reference/vapoursynth-cpp-api4/libit.so
# Used by scripts/compare_upstream.py and tests/integration/test_upstream_compare.py.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/reference/vapoursynth-cpp-api4"

cd "$DIR"

# pkg-config from the project venv would inject API 3 headers under some
# distros — explicitly clear it so we pick up the system headers only.
unset PKG_CONFIG_PATH

./configure --c --cxx=clang++ --extra-cxxflags='-std=c++17' >/dev/null
make -s clean
make

echo "built: $DIR/libit.so"
