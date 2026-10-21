#!/usr/bin/env sh
# Builds the patched libdatachannel that nethernet-zig needs into .deps/native
set -eu

cd "$(dirname "$0")/.."
commit=$(sed -n 's/.*nethernet-zig#\([0-9a-f]\{40\}\).*/\1/p' build.zig.zon)
test -n "$commit"
mkdir -p .deps

if [ ! -d .deps/nethernet-zig/.git ]; then
    git clone https://github.com/Bedrock-Phanatics/nethernet-zig.git .deps/nethernet-zig
fi
git -C .deps/nethernet-zig fetch --quiet origin
git -C .deps/nethernet-zig checkout --quiet "$commit"

sh .deps/nethernet-zig/tools/setup-native.sh "$@"
rm -rf .deps/native
cp -R .deps/nethernet-zig/.deps/native .deps/native
