# Deploying TigerBeetle on FreeBSD

This guide covers building and running TigerBeetle on FreeBSD natively.

> **Status:** Tier 2 support. FreeBSD is not an official target of upstream TigerBeetle.
> This port is community-maintained and may have performance differences from the Linux
> version (see [I/O Model](#io-model) below).

## Prerequisites

| Requirement | Version |
|-------------|---------|
| FreeBSD | 14.0 or later |
| Zig | 0.14.1 |
| Architecture | x86_64 (amd64) or aarch64 (arm64) |

### Install Dependencies

```bash
# Install Zig 0.14.1
pkg install zig-0.14.1

# Verify
zig version  # must be 0.14.1

# Optional: install runtime tools
pkg install tmux htop
```

## Building

```bash
# Clone the FreeBSD port
git clone https://github.com/a3pelawi/tigerbeetle.git -b port-freebsd
cd tigerbeetle

# Build for your native architecture
zig build -Dtarget=$(zig version | head -1 && uname -m)-freebsd -Doptimize=ReleaseSafe

# Or using the convenience script
./scripts/build-freebsd.sh x86_64-freebsd ReleaseSafe

# Verify
file zig-out/bin/tigerbeetle
zig-out/bin/tigerbeetle version --verbose
```

## Quick Start

### Single-Node Cluster

```bash
# Format a data file
./zig-out/bin/tigerbeetle format \
    --cluster=0 \
    --replica=0 \
    --replica-count=1 \
    --development \
    ./0_0.tigerbeetle

# Start
./zig-out/bin/tigerbeetle start \
    --addresses=3000 \
    --development \
    ./0_0.tigerbeetle
```

### Connect with REPL

In another terminal:

```bash
./zig-out/bin/tigerbeetle repl \
    --cluster=0 \
    --addresses=3000
```

## Production Deployment

### ZFS Configuration

TigerBeetle benefits from ZFS features. Recommended pool settings:

```bash
# Create a dedicated dataset
zfs create -o mountpoint=/var/lib/tigerbeetle zroot/tigerbeetle

# Disable atime (reduces write amplification)
zfs set atime=off zroot/tigerbeetle

# Enable compression (ZSTD is fast and effective)
zfs set compression=zstd-3 zroot/tigerbeetle

# Set recordsize to match TigerBeetle's allocation unit
zfs set recordsize=1M zroot/tigerbeetle
```

### Jail Setup

```bash
# Create a jail
cat >> /etc/jail.conf << 'EOF'
tigerbeetle {
    host.hostname = "tigerbeetle.example.com";
    path = /usr/local/jails/tigerbeetle;
    ip4.addr = 192.168.1.100;
    exec.start = "/bin/sh /etc/rc";
    exec.stop = "/bin/sh /etc/rc.shutdown";
    mount.devfs;
    allow.raw_sockets;
}
EOF

# Create jail environment
bsdinstall jail /usr/local/jails/tigerbeetle

# Install TigerBeetle in jail
pkg -j tigerbeetle install zig-0.14.1

# Start jail
service jail start tigerbeetle
```

### rc.d Service

Create `/usr/local/etc/rc.d/tigerbeetle`:

```bash
#!/bin/sh

# PROVIDE: tigerbeetle
# REQUIRE: LOGIN NETWORK
# KEYWORD: shutdown

. /etc/rc.subr

name="tigerbeetle"
rcvar="tigerbeetle_enable"

load_rc_config $name

: ${tigerbeetle_enable:="NO"}
: ${tigerbeetle_cluster:="0"}
: ${tigerbeetle_replica:="0"}
: ${tigerbeetle_replica_count:="1"}
: ${tigerbeetle_addresses:="3000"}
: ${tigerbeetle_data_dir:="/var/db/tigerbeetle"}
: ${tigerbeetle_user:="tigerbeetle"}

command="/usr/local/bin/tigerbeetle"
pidfile="/var/run/tigerbeetle.pid"

start_cmd="tigerbeetle_start"
stop_cmd="tigerbeetle_stop"

tigerbeetle_start() {
    local data_file="${tigerbeetle_data_dir}/${tigerbeetle_cluster}_${tigerbeetle_replica}.tigerbeetle"

    if [ ! -f "${data_file}" ]; then
        mkdir -p "${tigerbeetle_data_dir}"
        ${command} format \
            --cluster="${tigerbeetle_cluster}" \
            --replica="${tigerbeetle_replica}" \
            --replica-count="${tigerbeetle_replica_count}" \
            --development \
            "${data_file}"
    fi

    ${command} start \
        --addresses="${tigerbeetle_addresses}" \
        "${data_file}" &
    echo $! > "${pidfile}"
}

tigerbeetle_stop() {
    if [ -f "${pidfile}" ]; then
        kill $(cat "${pidfile}")
        rm -f "${pidfile}"
    fi
}

run_rc_command "$1"
```

Enable the service:

```bash
chmod +x /usr/local/etc/rc.d/tigerbeetle
sysrc tigerbeetle_enable=YES
service tigerbeetle start
```

## Multi-Node Cluster

For a 3-replica cluster across FreeBSD jails or machines:

```bash
# On each node (replica 0, 1, 2):
./zig-out/bin/tigerbeetle format \
    --cluster=0 \
    --replica=<INDEX> \
    --replica-count=3 \
    --development \
    ./<CLUSTER>_<REPLICA>.tigerbeetle

# Start each node:
./zig-out/bin/tigerbeetle start \
    --addresses=3001,3002,3003 \
    --development \
    ./0_<INDEX>.tigerbeetle
```

## I/O Model

The FreeBSD port uses **kqueue** for network I/O (similar to macOS) and
**synchronous file I/O** (pread/pwrite). This is the same approach used by the
Darwin/macOS backend.

The key difference from the Linux (io_uring) backend:

| Aspect | Linux (io_uring) | FreeBSD (kqueue + sync file) |
|--------|:----------------:|:----------------------------:|
| Network I/O | Async (io_uring) | Async (kqueue) |
| File I/O | Async (io_uring) | Synchronous (pwrite/pread) |
| Batching | Single syscall per batch | Per-operation syscall |
| Peak throughput | ~100k-300k ops/sec | ~10k-50k ops/sec* |

*\* Estimated; varies by workload and hardware.*

### IOR Integration (Future)

For improved performance, the [IOR library](https://github.com/libior/ior) provides
a userspace io_uring-compatible API on FreeBSD. Integration roadmap:

- [ ] Add IOR as a vendored dependency
- [ ] Create `src/io/freebsd_ior.zig` backend
- [ ] Implement SQE/CQE ring buffer adapters
- [ ] Add IOPS-based thread pool for file operations
- [ ] Benchmark against Linux backend

## Known Limitations

| Issue | Status | Workaround |
|-------|--------|------------|
| File I/O synchronous | Design constraint | Use IOR library for better performance |
| No `unshare` namespaces | Linux-only feature | Use FreeBSD jail for isolation |
| No transparent huge pages | Linux-only (MADV_HUGEPAGE) | Use ZFS ARC + larger cache |
| Block device support | Not implemented | Use regular files on ZFS volume |
| Multiversion binary format | Partial — ELF only | Same as Linux; no .macho needed |
| Vortex/chaos testing | Not supported | Test on Linux for fault injection |
| Precompiled client libraries | Not available | Build from source (zig build clients:c) |

## Performance Tuning

### sysctl Settings

```bash
# Increase network buffer sizes
sysctl net.inet.tcp.sendbuf_max=4194304
sysctl net.inet.tcp.recvbuf_max=4194304

# Reduce TIME_WAIT for high connection rates
sysctl net.inet.tcp.msl=1500

# Pin TigerBeetle to a dedicated core
sysctl kern.sched.affinity=1
# Then use: cpuset -l <core> -p <pid>
```

### Kernel Tuning

```bash
# Add to /boot/loader.conf
kern.ipc.maxsockbuf="8388608"
kern.maxfiles="100000"
kern.maxfilesperproc="100000"
```

## Troubleshooting

### `mlockall` Permission Error

FreeBSD requires `CAP_IPC_LOCK` or root to lock memory:

```bash
# Grant capability to the binary
cat >> /etc/login.conf << 'EOF'
tigerbeetle:\
    :memorylocked=unlimited:\
    :tc=default:
EOF

pwd_mkdb /etc/master.passwd
```

### `kevent: Operation not permitted`

Increase kernel event queue limits:

```bash
sysctl kern.kq_calloutmax=4096
```
