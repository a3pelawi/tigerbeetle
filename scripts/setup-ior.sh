#!/bin/sh
# IOR Library Integration for TigerBeetle FreeBSD
#
# This script fetches and builds the IOR library (io_uring-compatible API)
# and sets up the FreeBSD accelerated I/O backend.
#
# Usage: ./scripts/setup-ior.sh

set -eu

IOR_VERSION="0.1.0"
IOR_REPO="https://github.com/libior/ior"
IOR_DIR="lib/ior"

echo "==> IOR Library Setup for TigerBeetle FreeBSD"
echo ""

# Check platform
case "$(uname)" in
    FreeBSD) ;;
    *)
        echo "!! IOR integration is designed for FreeBSD."
        echo "   This script should be run on FreeBSD 14+."
        exit 1
        ;;
esac

# Check for required tools
for cmd in git zig cc make; do
    if ! which "$cmd" >/dev/null 2>&1; then
        echo "!! Missing: ${cmd}"
        exit 1
    fi
done
echo "✓ All tools found"

# Clone or update IOR
if [ -d "${IOR_DIR}" ]; then
    echo "Updating IOR..."
    git -C "${IOR_DIR}" pull
else
    echo "Cloning IOR..."
    git clone --depth 1 "${IOR_REPO}" "${IOR_DIR}"
fi
echo "✓ IOR library fetched"

# Build IOR
echo ""
echo "==> Building IOR..."
cd "${IOR_DIR}"
make -j$(sysctl -n hw.ncpu)
cd ../..
echo "✓ IOR built"

# Create Zig binding
echo ""
echo "==> Creating Zig IOR bindings..."
cat > src/io/freebsd_ior_bindings.zig << 'BINDINGS'
//! Zig bindings for the IOR library (io_uring-compatible API).
//! Generated for FreeBSD usage. Only the subset needed by TigerBeetle
//! is exposed.

pub const ior = struct {
    pub const ctx = opaque {};
    pub const sqe = opaque {};
    pub const cqe = opaque {};

    pub const Op = enum(c_uchar) {
        nop = 0,
        readv = 1,
        writev = 2,
        read = 3,
        write = 4,
        fsync = 5,
        poll_add = 6,
        poll_remove = 7,
        send = 8,
        recv = 9,
        accept = 10,
        connect = 11,
        close = 12,
        cancel = 13,
        timeout = 14,
        openat = 15,
        statx = 16,
        fallocate = 17,
    };

    pub const Flags = struct {
        pub const IO_LINK = 1 << 0;
        pub const IO_DRAIN = 1 << 1;
        pub const IO_HARDLINK = 1 << 2;
    };

    pub const Error = error{
        SetupFailed,
        SubmitFailed,
        WaitFailed,
        QueueFull,
        OperationNotSupported,
    };
};
BINDINGS
echo "✓ IOR bindings created"

# Show summary
echo ""
echo "==> IOR Integration Complete"
echo ""
echo "IOR library:    ${IOR_DIR}"
echo "IOR bindings:   src/io/freebsd_ior_bindings.zig"
echo ""
echo "Next steps:"
echo "  1. Test accelerated IO:   zig build test -Dtarget=\$(uname -m)-freebsd"
echo "  2. Benchmark comparison:  zig build bench -Dtarget=\$(uname -m)-freebsd"
echo "  3. Build production:      zig build -Dtarget=\$(uname -m)-freebsd -Doptimize=ReleaseSafe"
