# FreeBSD Port — Architecture & Status

## Overview

TigerBeetle FreeBSD port adds native FreeBSD kernel support (kqueue for network I/O,
synchronous file I/O) alongside the existing Linux (io_uring), Darwin/macOS (kqueue),
and Windows (IOCP) backends.

## Architecture

```
src/io.zig
  ├── .linux       → IO_Linux     (src/io/linux.zig)      — io_uring
  ├── .windows     → IO_Windows   (src/io/windows.zig)    — IOCP
  ├── .macos       → IO_Darwin    (src/io/darwin.zig)     — kqueue
  ├── .freebsd     → IO_FreeBSD   (src/io/freebsd.zig)    — kqueue (NEW)
  └── else         → @compileError
```

## File Manifest

| File | Purpose | Lines |
|------|---------|:-----:|
| `src/io/freebsd.zig` | I/O backend (kqueue + sync file I/O) | 1149 |
| `build.zig` | Target triples: +x86_64-freebsd, +aarch64-freebsd | 8 |
| `src/io.zig` | Route `.freebsd` → IO_FreeBSD | 2 |
| `src/tigerbeetle.zig` | Main compile guard includes freebsd | 8 |
| `src/time.zig` | monotonic_freebsd() via CLOCK_MONOTONIC | 19 |
| `src/multiversion.zig` | 7 switch blocks for FreeBSD (ELF, file-based exec) | 16 |
| `src/build_multiversion.zig` | Target union includes freebsd | 13 |
| `src/repl/terminal.zig` | termios support | 2 |
| `src/stdx/mlock.zig` | Skip mlockall on FreeBSD | 2 |
| `src/stdx/testing/time.zig` | benchmark_monotonic for FreeBSD | 10 |
| `src/vortex.zig` | Explicit rejection (Linux namespaces) | 6 |
| `src/docs_website/build.zig` | OS target support | 4 |

## Key Differences from Linux Backend

### Memory Management
- **FreeBSD:** No huge page support (MADV_HUGEPAGE is Linux-specific). No mlockall()
  (uses mlock() with limited scope). Falls back to page allocator without THP hint.
- **Impact:** TLB pressure may be slightly higher. Memory locking requires
  CAP_IPC_LOCK privilege.

### File I/O
- **FreeBSD:** Synchronous pwrite/pread with per-operation syscall.
  O_DSYNC is used for synchronous metadata, with explicit fsync() for durability.
- **Linux:** Fully async via io_uring's submission/completion queue.
  Single syscall batches hundreds of operations.
- **Impact:** Lower throughput for write-heavy workloads. Sufficient for moderate
  loads (< 50k ops/sec).

### Network I/O
- **FreeBSD:** kqueue-based kevent() loop. Same architecture as macOS/Darwin.
- **Linux:** io_uring handles network + file I/O uniformly.
- **Impact:** Network performance is comparable. kqueue is mature and efficient.

### Threading & Isolation
- **FreeBSD:** Jail is the isolation primitive (no Linux unshare syscall).
- **Linux:** Namespaces + unshare for process/network isolation.

## IOR Integration Roadmap

The [IOR library](https://github.com/libior/ior) provides a userspace io_uring-compatible
API that could significantly improve FreeBSD file I/O performance.

### Phase 1: Vendored Dependency
- [ ] Add IOR as a git submodule or vendored source
- [ ] Write Zig bindings for IOR's C API
- [ ] Verify IOR compiles on FreeBSD 14

### Phase 2: Basic Backend
- [ ] Create `src/io/freebsd_ior.zig`
- [ ] Implement SQE/CQE ring via IOR's thread pool backend
- [ ] Map file operations (read, write, fsync, openat)
- [ ] Map network operations (accept, connect, recv, send)

### Phase 3: Optimization
- [ ] Benchmark IOR backend vs. synchronous backend
- [ ] Tune IOR thread pool size
- [ ] Add IOPS-based flow control
- [ ] Profile with real TigerBeetle workloads

### Phase 4: Production Readiness
- [ ] Pass TigerBeetle unit tests
- [ ] Run VOPR simulation (single-node)
- [ ] Performance parity with io_uring backend (within 80%)
- [ ] Documentation and migration guide

## Known Issues

1. **Direct I/O with ZFS:** ZFS does not support O_DIRECT in the same way as
   UFS or Linux ext4/XFS. The FreeBSD backend uses O_DIRECT with regular files.
2. **Block devices:** Block device ioctl (BLKGETSIZE64, BLKDISCARD) is not
   implemented for FreeBSD. Regular files only.
3. **Multiversion upgrade polling:** Binary change detection via statx/io_uring
   is Linux-only. Manual restart required for upgrades on FreeBSD.

## Testing Status

| Test | Status | Notes |
|------|--------|-------|
| `zig build check` | ✅ Pass (x86_64 & aarch64) | Compile-time only |
| `zig build` (actual) | ⚠️ Needs FreeBSD host | Cross-compile from macOS needs FreeBSD libc |
| Unit tests | ⚠️ Pending | Need to resolve test dependencies |
| Single-node smoke | ⚠️ Pending | Needs FreeBSD host with Zig 0.14.1 |
| Multi-node cluster | ❌ Not tested |  |
| VOPR simulation | ❌ Not supported |  |

## How to Build on FreeBSD

```bash
# On a FreeBSD 14+ system:
pkg install zig-0.14.1 git
git clone https://github.com/a3pelawi/tigerbeetle.git -b port-freebsd
cd tigerbeetle
zig build -Dtarget=$(uname -m)-freebsd -Doptimize=ReleaseSafe
```
