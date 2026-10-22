#!/usr/bin/env sh
# Runs the tests with the Zig code under ThreadSanitizer, Linux only
set -eu
cd "$(dirname "$0")/.."
# TSan cannot map its shadow memory under the address randomization of recent kernels
TSAN_OPTIONS="suppressions=$(pwd)/tools/tsan.supp ${TSAN_OPTIONS:-}" \
    setarch "$(uname -m)" -R zig build test -Doptimize=ReleaseSafe -Dsanitize-thread=true "$@"
