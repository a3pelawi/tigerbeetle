# tigerbeetle

*TigerBeetle is the financial transactions database designed for mission critical safety and performance to power the next 30 years of [OLTP](https://docs.tigerbeetle.com/concepts/oltp).*

## Documentation

* <https://docs.tigerbeetle.com>
* [The Primeagen](https://www.youtube.com/watch?v=sC1B3d9C_sI) video introduction to our
  design decisions regarding performance, safety, and debit/credit primitives.
* [Redesigning OLTP for a New Order of Magnitude (QCon SF)](https://www.infoq.com/presentations/redesign-oltp/)
  talk with a deeper dive into TigerBeetle's local storage engine and global consensus protocol.
* [TIGER_STYLE.md](./docs/TIGER_STYLE.md), the engineering methodology behind TigerBeetle.

## Start

Run a single-replica cluster:

```console
$ curl -Lo tigerbeetle.zip https://linux.tigerbeetle.com && unzip tigerbeetle.zip
$ ./tigerbeetle version
$ ./tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
$ ./tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle
```

Connect to the cluster and make a transfer:

```console
$ ./tigerbeetle repl --cluster=0 --addresses=3000
> create_accounts id=1 code=10 ledger=700, id=2 code=10 ledger=700;
{
  "timestamp": "1761605367595515148",
  "status": "tigerbeetle.CreateAccountStatus.created"
}
{
  "timestamp": "1761605367595515149",
  "status": "tigerbeetle.CreateAccountStatus.created"
}
> create_transfers id=1 debit_account_id=1 credit_account_id=2 amount=10 ledger=700 code=10;
{
  "timestamp": "1761605382476666870",
  "status": "tigerbeetle.CreateTransferStatus.created"
}
> lookup_accounts id=1, id=2;
{
  "id": "1",
  "user_data": "0",
  "ledger": "700",
  "code": "10",
  "flags": "",
  "debits_pending": "0",
  "debits_posted": "10",
  "credits_pending": "0",
  "credits_posted": "0"
}
{
  "id": "2",
  "user_data": "0",
  "ledger": "700",
  "code": "10",
  "flags": "",
  "debits_pending": "0",
  "debits_posted": "0",
  "credits_pending": "0",
  "credits_posted": "10"
}
```

## FreeBSD Port

TigerBeetle runs natively on FreeBSD 14+. Build from source:

```console
$ pkg install zig014 git
$ git clone https://github.com/a3pelawi/tigerbeetle.git -b port-freebsd
$ cd tigerbeetle
$ zig build --release=safe
$ ./zig-out/bin/tigerbeetle version --verbose
```

### Differences from Linux Build

| Aspect | Linux | FreeBSD |
|--------|-------|---------|
| I/O backend | io_uring | kqueue + POSIX |
| File I/O | Async (batch via io_uring) | Synchronous |
| Memory locking | mlockall (root) | No-op (CAP_IPC_LOCK required) |
| Huge pages | MADV_HUGEPAGE hint | Not supported |

A full I/O throughput comparison is tracked in the [IOR integration
roadmap](./docs/internals/freebsd-port.md#ior-integration-roadmap) — the IOR library
provides an io_uring-compatible API via thread pool for FreeBSD, which can
improve file I/O latency.

### What Was Changed

This port touches 18 files across the TigerBeetle source tree:

| File | Change |
|------|--------|
| `build.zig` | Added freebsd target triples; made target nullable for native FreeBSD build; added fetch_objcopy for FreeBSD host |
| `src/io.zig` | Route `.freebsd` to IO_FreeBSD backend |
| `src/io/freebsd.zig` | **New** — kqueue-based I/O backend (1196 lines) |
| `src/io/freebsd_ior.zig` | **New** — IOR library backend for accelerated async I/O (1532 lines) |
| `src/tigerbeetle.zig` | Main compile guard allows `.freebsd` |
| `src/time.zig` | Added `monotonic_freebsd()` via `clock_gettime(CLOCK_MONOTONIC)` |
| `src/multiversion.zig` | 7 switch blocks handle `.freebsd` (ELF binary, file-based exec) |
| `src/build_multiversion.zig` | Target union includes freebsd arch |
| `src/repl/terminal.zig` | FreeBSD termios support |
| `src/stdx/mlock.zig` | FreeBSD skip (no mlockall) |
| `src/stdx/testing/time.zig` | benchmark_monotonic for FreeBSD |
| `src/vortex.zig` | Explicit rejection (Linux namespaces) |
| `src/docs_website/build.zig` | OS target support |
| `Makefile.freebsd` | Build helpers with auto zig014 detection |
| `docs/internals/freebsd-port.md` | Architecture and IOR roadmap |
| `docs/operating/deploying/freebsd.md` | Deployment guide |

For more detail, see [docs/internals/freebsd-port.md](./docs/internals/freebsd-port.md)
and [docs/operating/deploying/freebsd.md](./docs/operating/deploying/freebsd.md).

---

Want to learn more? See <https://docs.tigerbeetle.com>.

---

If you discover a security vulnerability in TigerBeetle, please send the details to `security@tigerbeetle.com`.

---

*This FreeBSD port was built by [Claude Fable 5 (Anthropic)](https://www.anthropic.com) under the direction of a3pelawi. All original source code remains copyright TigerBeetleDB, Inc. under the terms of the project license.*
