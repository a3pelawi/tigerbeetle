#!/bin/sh
# Build TigerBeetle for FreeBSD
#
# Usage: ./scripts/build-freebsd.sh [target] [mode]
#   target: x86_64-freebsd (default) or aarch64-freebsd
#   mode:   Debug (default), ReleaseSafe, ReleaseFast, ReleaseSmall

set -eu

TARGET="${1:-x86_64-freebsd}"
MODE="${2:-Debug}"

echo "==> TigerBeetle FreeBSD Build Script"
echo "    Target: ${TARGET}"
echo "    Mode:   ${MODE}"
echo ""

# Check zig version
ZIG_VERSION=$(zig version 2>/dev/null || echo "none")
if [ "${ZIG_VERSION}" != "0.14.1" ]; then
    echo "!! Zig 0.14.1 required, found: ${ZIG_VERSION}"
    echo "   Install with: pkg install zig-0.14.1"
    echo "   Or build from source: https://ziglang.org/download/0.14.1/"
    exit 1
fi
echo "✓ Zig ${ZIG_VERSION} found"

# Build
echo ""
echo "==> Building tigerbeetle for ${TARGET}..."
zig build \
    -Dtarget="${TARGET}" \
    -Doptimize="${MODE}" \
    2>&1

echo ""
echo "✓ Build complete!"
echo "  Binary: zig-out/bin/tigerbeetle"
file zig-out/bin/tigerbeetle 2>/dev/null || true
echo ""
echo "  Run with:"
echo "    ./zig-out/bin/tigerbeetle version"
echo "    ./zig-out/bin/tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development ./0_0.tigerbeetle"
echo "    ./zig-out/bin/tigerbeetle start --addresses=3000 --development ./0_0.tigerbeetle"
