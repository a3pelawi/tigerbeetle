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
ZIG_VER=$(zig version 2>/dev/null || echo "none")
case "${ZIG_VER}" in
    0.14.*|0.15.*|0.16.*) ;;
    none)
        echo "!! Zig not found. Install with: pkg install zig"
        exit 1
        ;;
    *)
        echo "!! Unsupported Zig version: ${ZIG_VER}"
        echo "   Supported: 0.14.x, 0.15.x, 0.16.x"
        echo "   Install with: pkg install zig  (for 0.16)"
        echo "              or: pkg install zig014 (for 0.14)"
        exit 1
        ;;
esac

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
