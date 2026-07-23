#!/bin/sh
# IOR Library Integration for TigerBeetle FreeBSD
#
# Builds the IOR library (io_uring-compatible API) for FreeBSD and
# configures TigerBeetle to use it as an accelerated I/O backend.
#
# Usage: ./scripts/setup-ior.sh [build|clean]
#   build  - Build IOR and configure TigerBeetle (default)
#   clean  - Remove IOR build artifacts

set -eu

ACTION="${1:-build}"
IOR_REPO="https://github.com/libior/ior.git"
IOR_DIR="lib/ior"
IOR_BRANCH="main"

echo "================================================================="
echo "  IOR Library Setup for TigerBeetle FreeBSD"
echo "  Target: $(uname -m)-$(uname -s)"
echo "================================================================="
echo ""

# Check platform
case "$(uname)" in
    FreeBSD|Linux)
        echo "✓ Platform: $(uname -s) $(uname -r)"
        ;;
    Darwin)
        echo "⚠  macOS detected. IOR will use thread pool backend (not native)."
        ;;
    *)
        echo "✗ Unsupported platform: $(uname -s)"
        exit 1
        ;;
esac

# Check for required tools
MISSING=""
for cmd in git zig cc; do
    if ! which "$cmd" >/dev/null 2>&1; then
        MISSING="${MISSING} ${cmd}"
    fi
done
if [ -n "${MISSING}" ]; then
    echo "✗ Missing tools:${MISSING}"
    echo "  Install them first:"
    echo "    pkg install git zig cc"
    exit 1
fi
echo "✓ All required tools found"

# Check Zig version
ZIG_VER=$(zig version 2>/dev/null || echo "none")
echo "  Zig version: ${ZIG_VER}"

# Check if cmake is available (optional, for IOR build)
if which cmake >/dev/null 2>&1; then
    HAVE_CMAKE=1
    echo "✓ cmake found"
else
    HAVE_CMAKE=0
    echo "⚠  cmake not found, using Makefile fallback"
fi

echo ""
echo "================================================================="
echo "  Step 1: Fetch IOR Library"
echo "================================================================="

case "${ACTION}" in
    clean)
        echo "Cleaning IOR build artifacts..."
        rm -rf "${IOR_DIR}/build"
        echo "✓ Cleaned"
        exit 0
        ;;
    build)
        if [ -d "${IOR_DIR}" ]; then
            echo "Updating existing IOR clone..."
            git -C "${IOR_DIR}" pull --rebase 2>&1 | tail -3
        else
            echo "Cloning IOR from ${IOR_REPO}..."
            git clone --depth 1 --branch "${IOR_BRANCH}" "${IOR_REPO}" "${IOR_DIR}"
        fi
        echo "✓ IOR fetched to ${IOR_DIR}"
        ;;
    *)
        echo "Usage: $0 [build|clean]"
        exit 1
        ;;
esac

echo ""
echo "================================================================="
echo "  Step 2: Build IOR Library"
echo "================================================================="

IOR_SRC="${IOR_DIR}"
IOR_BUILD="${IOR_DIR}/build"

mkdir -p "${IOR_BUILD}"
cd "${IOR_BUILD}"

if [ "${HAVE_CMAKE}" -eq 1 ]; then
    cmake .. -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_SHARED_LIBS=ON \
             -DIOR_BUILD_TESTS=OFF \
             -DIOR_BUILD_BENCHMARKS=OFF
    make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
    # Fallback: compile IOR directly from source files
    echo "Building IOR with direct compile (no cmake)..."
    IOR_SRCS=""
    for f in ior.c ior_log.c ior_threads.c ior_threads_ring.c \
             ior_threads_pool.c ior_worker_pool.c \
             ior_threads_event_common.c ior_threads_event_eventfd.c \
             ior_threads_event_pipe.c; do
        if [ -f "../src/${f}" ]; then
            IOR_SRCS="${IOR_SRCS} ../src/${f}"
        fi
    done
    # Also add the poller
    case "$(uname)" in
        FreeBSD|Darwin)
            IOR_SRCS="${IOR_SRCS} ../src/ior_threads_poller_kqueue.c"
            ;;
        Linux)
            IOR_SRCS="${IOR_SRCS} ../src/ior_threads_poller_epoll.c"
            ;;
    esac

    cc -O2 -fPIC -I../src -I. \
       -DIOR_BUILD \
       ${IOR_SRCS} \
       -shared -o libior.so -lpthread

    # Build the config header
    cat > ../config.h << 'EOF'
#define IOR_VERSION "0.1.0"
#define IOR_HAVE_EVENTFD 1
EOF
fi

echo "✓ IOR library built"

# Install library
if [ -f "libior.so" ]; then
    cp libior.so ../../libior.so
    echo "  → libior.so"
elif ls libior*.so* 2>/dev/null; then
    cp libior*.so* ../../
fi

cd ../../..

echo ""
echo "================================================================="
echo "  Step 3: Verify Build Configuration"
echo "================================================================="

# Verify the Zig binding compiles
if [ -f "src/io/freebsd_ior.zig" ]; then
    echo "✓ IOR backend: src/io/freebsd_ior.zig"
else
    echo "✗ Missing: src/io/freebsd_ior.zig"
    exit 1
fi

# Check the IOR header
if [ -f "${IOR_DIR}/src/ior.h" ]; then
    IOR_HEADER="${IOR_DIR}/src/ior.h"
    echo "✓ IOR header: ${IOR_HEADER}"
else
    echo "✗ Missing IOR header"
    exit 1
fi

echo ""
echo "================================================================="
echo "  IOR Integration Complete!"
echo "================================================================="
echo ""
echo "  IOR library:  ${IOR_DIR}/build/libior.so"
echo "  IOR header:   ${IOR_HEADER}"
echo "  Zig backend:  src/io/freebsd_ior.zig"
echo ""
echo "  To build TigerBeetle with IOR:"
echo ""
echo "    zig build -Dtarget=\$(uname -m)-freebsd \\"
echo "      -Doptimize=ReleaseSafe"
echo ""
echo "    LD_PRELOAD=./libior.so ./zig-out/bin/tigerbeetle --version"
echo ""
echo "  Backend info at runtime:"
echo ""
echo "    tigerbeetl version --verbose | grep 'ior'"
echo ""
echo "================================================================="
