#!/bin/bash
# Unit tests for JSONFilter.m, run on Linux against GNUstep (no iPhone needed).
#
#   sudo apt-get install -y clang libgnustep-base-dev libblocksruntime-dev
#   tests/run.sh
#
# The tweak itself is never built from this folder (the Makefile only picks up
# top-level files).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:-$(dirname "$HERE")}
OUT=$(mktemp -d)
OBJCINC=$(dirname "$(dirname "$(find /usr/lib/gcc -name objc.h -path '*objc/objc.h' | head -1)")")
# GNUstep's runtime can't do object[@"key"] subscripting, so rewrite it first.
python3 -I "$HERE/desubscript.py" "$REPO/JSONFilter.m" > "$OUT/JSONFilter.m"
python3 -I "$HERE/desubscript.py" --int "$HERE/test_filter.m" > "$OUT/test_filter.m"
cp "$REPO/JSONFilter.h" "$REPO/DebugMenu.h" "$OUT/"
FLAGS="-include $HERE/shim/prelude.h $(gnustep-config --objc-flags) -I$OBJCINC -I$HERE/shim -fobjc-runtime=gcc -fblocks -w -O0 -g -DREDDITFILTER_DEBUG=0"
clang $FLAGS -I"$OUT" -c "$OUT/JSONFilter.m" -o "$OUT/JSONFilter.o"
clang $FLAGS -I"$OUT" -c "$OUT/test_filter.m" -o "$OUT/test_filter.o"
clang "$OUT/JSONFilter.o" "$OUT/test_filter.o" -o "$OUT/tests" $(gnustep-config --base-libs) -lBlocksRuntime
"$OUT/tests"
