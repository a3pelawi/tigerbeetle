//! I/O backend using the IOR library (io_uring-compatible API).
//!
//! IOR provides a cross-platform io_uring-like API that uses:
//! - Linux: Native io_uring
//! - FreeBSD: Thread pool + kqueue poller
//! - Windows: IOCP
//!
//! This backend is designed specifically for FreeBSD but can also be used
//! on Linux (as an alternative to the raw io_uring backend) and Windows.
//!
//! Architecture:
//!   Operations are submitted as Submission Queue Entries (SQEs) via ior_get_sqe().
//!   Batches are flushed via ior_submit().
//!   Completions are collected via ior_peek_batch_cqe() / ior_wait_cqe().
//!
//! IOR operations used:
//!   - READ/WRITE:       File I/O (via thread pool on FreeBSD)
//!   - SEND/RECV:        Network I/O (via kqueue poller on FreeBSD)
//!   - TIMEOUT:          Timer events
//!   - POLL:             Socket readiness notification
//!   - WORK:             Arbitrary blocking work (fsync, openat, etc.)
//!
//! Operations dispatched to inline POSIX calls (not through IOR):
//!   - close():    Fast, no async needed
//!   - connect():  Non-blocking connect + POLL for completion
//!   - accept():   POLL on listen socket + accept() call

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const assert = std.debug.assert;
const log = std.log.scoped(.io);

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const common = @import("./common.zig");
const QueueType = @import("../queue.zig").QueueType;
const TimeOS = @import("../time.zig").TimeOS;
const buffer_limit = @import("../io.zig").buffer_limit;
const DirectIO = @import("../io.zig").DirectIO;

// IOR foreign function interface
const ior = struct {
    const Op = enum(c_uint) {
        nop = 0,
        read = 1,
        write = 2,
        timer = 3,
        splice = 4,
        accept = 5, // reserved
        connect = 6, // reserved
        listen = 7, // reserved
        bind = 8, // reserved
        send = 9,
        recv = 10,
        link_timeout = 11,
        work = 12,
        poll = 13,
    };

    const SqeFlags = enum(c_uint) {
        fixed_file = 0x1,
        io_drain = 0x2,
        io_link = 0x4,
        @"async" = 0x8,
    };

    const PollEvents = enum(c_ushort) {
        @"in" = 0x001,
        out = 0x004,
        err = 0x008,
        hup = 0x010,
        nval = 0x020,
    };

    const BackendType = enum(c_int) {
        auto_ = 0,
        iouring,
        threads,
        iocp,
    };

    const SetupFlags = enum(c_uint) {
        sqpoll = 0x1,
        iopoll = 0x2,
        @"defer" = 0x4,
    };

    const Features = enum(c_uint) {
        native_async = 0x1,
        splice = 0x2,
        fixed_file = 0x4,
        poll_add = 0x8,
        sqpoll = 0x10,
        work = 0x20,
    };

    const TimeoutFlags = enum(c_uint) {
        @"abs" = 0x1,
    };

    const Timespec = extern struct {
        sec: i64,
        nsec: c_longlong,
    };

    const Params = extern struct {
        sq_entries: c_uint,
        cq_entries: c_uint,
        flags: c_uint,
        sq_thread_cpu: c_uint,
        sq_thread_idle: c_uint,
        features: c_uint,
        backend: BackendType,
    };

    // Opaque types
    const Context = opaque {};
    const Sqe = opaque {};
    const Cqe = opaque {};

    // IOR function declarations
    extern "c" fn ior_queue_init(entries: c_uint, ctx: **Context) callconv(.C) c_int;
    extern "c" fn ior_queue_init_params(
        entries: c_uint,
        ctx: **Context,
        params: *Params,
    ) callconv(.C) c_int;
    extern "c" fn ior_queue_exit(ctx: *Context) callconv(.C) void;

    extern "c" fn ior_get_sqe(ctx: *Context) callconv(.C) ?*Sqe;
    extern "c" fn ior_submit(ctx: *Context) callconv(.C) c_int;
    extern "c" fn ior_submit_and_wait(ctx: *Context, wait_nr: c_uint) callconv(.C) c_int;

    extern "c" fn ior_peek_cqe(ctx: *Context, cqe_out: **Cqe) callconv(.C) c_int;
    extern "c" fn ior_wait_cqe(ctx: *Context, cqe_out: **Cqe) callconv(.C) c_int;
    extern "c" fn ior_wait_cqe_timeout(
        ctx: *Context,
        cqe_out: **Cqe,
        timeout: *Timespec,
    ) callconv(.C) c_int;
    extern "c" fn ior_cqe_seen(ctx: *Context, cqe: *Cqe) callconv(.C) void;
    extern "c" fn ior_peek_batch_cqe(ctx: *Context, cqes: **Cqe, max: c_uint) callconv(.C) c_uint;
    extern "c" fn ior_cq_advance(ctx: *Context, nr: c_uint) callconv(.C) void;

    extern "c" fn ior_prep_nop(ctx: *Context, sqe: *Sqe) callconv(.C) void;
    extern "c" fn ior_prep_read(
        ctx: *Context,
        sqe: *Sqe,
        fd: c_int,
        buf: *anyopaque,
        nbytes: c_uint,
        offset: u64,
    ) callconv(.C) void;
    extern "c" fn ior_prep_write(
        ctx: *Context,
        sqe: *Sqe,
        fd: c_int,
        buf: *const anyopaque,
        nbytes: c_uint,
        offset: u64,
    ) callconv(.C) void;
    extern "c" fn ior_prep_send(
        ctx: *Context,
        sqe: *Sqe,
        sockfd: c_int,
        buf: *const anyopaque,
        nbytes: c_uint,
        flags: c_int,
    ) callconv(.C) void;
    extern "c" fn ior_prep_recv(
        ctx: *Context,
        sqe: *Sqe,
        sockfd: c_int,
        buf: *anyopaque,
        nbytes: c_uint,
        flags: c_int,
    ) callconv(.C) void;
    extern "c" fn ior_prep_timeout(
        ctx: *Context,
        sqe: *Sqe,
        ts: *Timespec,
        count: c_uint,
        flags: c_uint,
    ) callconv(.C) void;
    extern "c" fn ior_prep_poll_add(
        ctx: *Context,
        sqe: *Sqe,
        fd: c_int,
        poll_mask: c_ushort,
    ) callconv(.C) void;
    extern "c" fn ior_prep_work(
        ctx: *Context,
        sqe: *Sqe,
        work_fn: *const fn (*anyopaque, ?*anyopaque) callconv(.C) c_int,
        arg: ?*anyopaque,
    ) callconv(.C) void;
    extern "c" fn ior_prep_link_timeout(
        ctx: *Context,
        sqe: *Sqe,
        ts: *Timespec,
        flags: c_uint,
    ) callconv(.C) void;
    extern "c" fn ior_prep_splice(
        ctx: *Context,
        sqe: *Sqe,
        fd_in: c_int,
        off_in: u64,
        fd_out: c_int,
        off_out: u64,
        nbytes: c_uint,
        flags: c_uint,
    ) callconv(.C) void;

    extern "c" fn ior_sqe_set_data(ctx: *Context, sqe: *Sqe, data: *anyopaque) callconv(.C) void;
    extern "c" fn ior_sqe_set_flags(ctx: *Context, sqe: *Sqe, flags: u8) callconv(.C) void;
    extern "c" fn ior_cqe_get_data(ctx: *Context, cqe: *Cqe) callconv(.C) ?*anyopaque;
    extern "c" fn ior_cqe_get_res(ctx: *Context, cqe: *Cqe) callconv(.C) c_int;
    extern "c" fn ior_cqe_get_flags(ctx: *Context, cqe: *Cqe) callconv(.C) c_uint;

    extern "c" fn ior_get_backend_type(ctx: *Context) callconv(.C) BackendType;
    extern "c" fn ior_get_backend_name(ctx: *Context) callconv(.C) [*:0]const u8;
    extern "c" fn ior_get_features(ctx: *Context) callconv(.C) c_uint;

    /// Work function type for IOR_OP_WORK operations.
    /// Returns 0 on success, negative errno on error.
    const WorkFunction = *const fn (token: ?*anyopaque, arg: ?*anyopaque) callconv(.C) c_int;
};

pub const IO = struct {
    pub const TCPOptions = common.TCPOptions;
    pub const ListenOptions = common.ListenOptions;
    pub const Stats = common.Stats;
    pub const NextTickSource = common.NextTickSource;

    ctx: *ior.Context,

    time: TimeOS = .{},
    io_inflight: usize = 0,
    timeouts: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_timeouts" }),
    completed: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_completed" }),
    io_pending: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_pending" }),
    run_for_ns_active: bool = false,

    stats: common.Stats = .{},
    entries: u12,

    pub fn init(entries: u12, flags: u32) !IO {
        _ = flags;

        var params = ior.Params{
            .sq_entries = entries,
            .cq_entries = entries,
            .flags = 0,
            .sq_thread_cpu = 0,
            .sq_thread_idle = 0,
            .features = 0,
            .backend = .auto_,
        };

        var ctx: *ior.Context = undefined;
        const rc = ior.ior_queue_init_params(entries, &ctx, &params);
        if (rc != 0) {
            log.err("ior_queue_init_params failed: {}", .{rc});
            return error.SystemResources;
        }

        const backend_name = ior.ior_get_backend_name(ctx);
        log.info("IOR backend initialized: {s} (entries={})", .{ backend_name, entries });

        return IO{
            .ctx = ctx,
            .entries = entries,
        };
    }

    pub fn deinit(self: *IO) void {
        ior.ior_queue_exit(self.ctx);
        self.ctx = undefined;
    }

    /// Pass all queued submissions to the kernel and peek for completions.
    pub fn run(self: *IO) !void {
        assert(!self.run_for_ns_active);
        return self.flush();
    }

    /// Pass all queued submissions and run for `nanoseconds`.
    pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
        assert(!self.run_for_ns_active);
        self.run_for_ns_active = true;
        defer {
            assert(self.run_for_ns_active);
            self.run_for_ns_active = false;
        }
        defer self.stats.trace();

        const timer = self.time.monotonic();
        defer self.stats.window.time_run_for_ns.ns +=
            timer.elapsed(self.time.monotonic()).ns;

        var timed_out = false;
        var completion: Completion = undefined;
        const on_timeout = struct {
            fn callback(
                timed_out_ptr: *bool,
                _completion: *Completion,
                result: TimeoutError!void,
            ) void {
                _ = _completion;
                _ = result catch unreachable;
                timed_out_ptr.* = true;
            }
        }.callback;

        // Submit a timeout which sets timed_out to true.
        self.timeout(
            *bool,
            &timed_out,
            on_timeout,
            &completion,
            nanoseconds,
        );

        while (!timed_out) {
            try self.flush();
        }
    }

    fn flush(self: *IO) !void {
        // 1. Process timeouts and collect IO events
        self.flush_timeouts();

        // 2. Submit any pending I/O events to the IOR queue
        const submitted = self.submit_io();
        if (submitted > 0) {
            const rc = ior.ior_submit(self.ctx);
            if (rc < 0) {
                log.err("ior_submit failed: {}", .{rc});
                return error.SystemResources;
            }
            self.io_inflight += submitted;
        }

        // 3. Collect completions via peek (avoids opaque pointer arithmetic).
        while (true) {
            var cqe: *ior.Cqe = undefined;
            const rc = ior.ior_peek_cqe(self.ctx, &cqe);
            if (rc != 0) break;

            const completion: *Completion = @ptrCast(@alignCast(
                ior.ior_cqe_get_data(self.ctx, cqe).?,
            ));
            const res = ior.ior_cqe_get_res(self.ctx, cqe);
            ior.ior_cqe_seen(self.ctx, cqe);
            self.commit_completion(completion, res);
            self.io_inflight -= 1;
        }

        // 4. Drain completion callbacks
        const drain_timer = self.time.monotonic();
        while (self.completed.pop()) |completion| {
            (completion.callback)(self, completion);
        }
        const elapsed = drain_timer.elapsed(self.time.monotonic());
        self.stats.window.time_callbacks.ns += elapsed.ns;
    }

    fn submit_io(self: *IO) usize {
        var count: usize = 0;
        while (self.io_pending.pop()) |completion| {
            const sqe = ior.ior_get_sqe(self.ctx) orelse {
                // Queue full -- push back and submit later
                self.io_pending.push(completion);
                break;
            };

            const sqe_flags: u8 = @intFromEnum(ior.SqeFlags.io_drain);

            switch (completion.operation) {
                .accept => |op| {
                    // Accept via IOR POLL on listen socket + inline accept
                    ior.ior_prep_poll_add(
                        self.ctx,
                        sqe,
                        op.socket,
                        @intFromEnum(ior.PollEvents.in),
                    );
                    ior.ior_sqe_set_flags(self.ctx, sqe, sqe_flags);
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .connect => |op| {
                    // Connect via IOR POLL for OUT event
                    ior.ior_prep_poll_add(
                        self.ctx,
                        sqe,
                        op.socket,
                        @intFromEnum(ior.PollEvents.out),
                    );
                    ior.ior_sqe_set_flags(self.ctx, sqe, sqe_flags);
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .close => |op| {
                    // Close is synchronous - complete immediately
                    completion.result = .{ .close = switch (posix.errno(posix.system.close(op.fd))) {
                        .SUCCESS => {},
                        .BADF => error.FileDescriptorInvalid,
                        .INTR => {},
                        .IO => error.InputOutput,
                        else => |errno| stdx.unexpected_errno("close", errno),
                    } };
                    self.completed.push(completion);
                    continue;
                },
                .fsync => {
                    // Fsync via IOR WORK (executed in thread pool)
                    const Wrapper = struct {
                        fn work(_: ?*anyopaque, arg: ?*anyopaque) callconv(.C) c_int {
                            const completion_ptr: *Completion = @ptrCast(@alignCast(arg.?));
                            const fd = completion_ptr.operation.fsync.fd;
                            return switch (posix.errno(posix.system.fsync(fd))) {
                                .SUCCESS => 0,
                                else => |e| @as(c_int, @intFromEnum(e)),
                            };
                        }
                    };

                    ior.ior_prep_work(self.ctx, sqe, Wrapper.work, completion);
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .openat => {
                    // Openat via IOR WORK
                    const Wrapper = struct {
                        fn work(_: ?*anyopaque, arg: ?*anyopaque) callconv(.C) c_int {
                            const completion_ptr: *Completion = @ptrCast(@alignCast(arg.?));
                            const op_data = &completion_ptr.operation.openat;
                            while (true) {
                                const rc = posix.system.openat(
                                    op_data.dir_fd, op_data.file_path, op_data.flags, op_data.mode,
                                );
                                switch (posix.errno(rc)) {
                                    .SUCCESS => return @as(c_int, @intCast(rc)),
                                    .INTR => continue,
                                    .FAULT, .INVAL, .BADF => return @as(c_int, -@intFromEnum(posix.E.INVAL)),
                                    else => |e| return -@as(c_int, @intCast(@intFromEnum(e))),
                                }
                            }
                        }
                    };
                    ior.ior_prep_work(self.ctx, sqe, Wrapper.work, completion);
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .read => |op| {
                    ior.ior_prep_read(
                        self.ctx,
                        sqe,
                        op.fd,
                        op.buf,
                        op.len,
                        op.offset,
                    );
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .recv => |op| {
                    ior.ior_prep_recv(
                        self.ctx,
                        sqe,
                        op.socket,
                        op.buf,
                        op.len,
                        0,
                    );
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .send => |op| {
                    ior.ior_prep_send(
                        self.ctx,
                        sqe,
                        op.socket,
                        op.buf,
                        op.len,
                        0,
                    );
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .timeout => |op| {
                    var ts = ior.Timespec{
                        .sec = @intCast(op.expires / std.time.ns_per_s),
                        .nsec = @intCast(op.expires % std.time.ns_per_s),
                    };
                    ior.ior_prep_timeout(self.ctx, sqe, &ts, 0, 0);
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .write => |op| {
                    ior.ior_prep_write(
                        self.ctx,
                        sqe,
                        op.fd,
                        op.buf,
                        op.len,
                        op.offset,
                    );
                    ior.ior_sqe_set_data(self.ctx, sqe, completion);
                },
                .next_tick => {
                    // next_tick is handled directly, never queued to io_pending
                    unreachable;
                },
            }
            count += 1;
        }
        return count;
    }

    fn commit_completion(self: *IO, completion: *Completion, res: c_int) void {
        switch (completion.operation) {
            .accept => {
                const result: AcceptError!socket_t = if (res >= 0) blk: {
                    // POLL indicated socket is ready -- now accept
                    const op = &completion.operation.accept;
                    break :blk posix.accept(
                        op.socket, null, null,
                        posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
                    ) catch |err| err;
                } else error.WouldBlock;

                completion.result = .{ .accept = result };
                self.completed.push(completion);
            },
            .connect => {
                const result: ConnectError!void = if (res >= 0) blk: {
                    // POLL indicated connect completed
                    const op = &completion.operation.connect;
                    break :blk posix.getsockoptError(op.socket);
                } else error.WouldBlock;
                completion.result = .{ .connect = result };
                self.completed.push(completion);
            },
            .close => {
                // Already handled inline in submit_io
            },
            .fsync => {
                const result: FsyncError!void = if (res >= 0) {} else error.InputOutput;
                completion.result = .{ .fsync = result };
                self.completed.push(completion);
            },
            .openat => {
                const result: OpenatError!fd_t = if (res >= 0) @intCast(res)
                else error.FileNotFound;
                completion.result = .{ .openat = result };
                self.completed.push(completion);
            },
            .read => {
                const result: ReadError!usize = if (res >= 0)
                    @intCast(res)
                else switch (res) {
                    -@intFromEnum(posix.E.AGAIN),
                    -@intFromEnum(posix.E.INTR),
                    => error.WouldBlock,
                    -@intFromEnum(posix.E.BADF) => error.NotOpenForReading,
                    -@intFromEnum(posix.E.CONNRESET) => error.ConnectionResetByPeer,
                    -@intFromEnum(posix.E.INVAL) => error.Alignment,
                    -@intFromEnum(posix.E.IO) => error.InputOutput,
                    -@intFromEnum(posix.E.ISDIR) => error.IsDir,
                    -@intFromEnum(posix.E.NOMEM) => error.SystemResources,
                    -@intFromEnum(posix.E.SPIPE) => error.Unseekable,
                    else => error.SystemResources,
                };
                completion.result = .{ .read = result };
                self.completed.push(completion);
            },
            .recv => {
                const result: RecvError!usize = if (res >= 0) @intCast(res)
                else error.WouldBlock;
                completion.result = .{ .recv = result };
                self.completed.push(completion);
            },
            .send => {
                const result: SendError!usize = if (res >= 0) @intCast(res)
                else error.WouldBlock;
                completion.result = .{ .send = result };
                self.completed.push(completion);
            },
            .timeout => {
                const result: TimeoutError!void = {};
                completion.result = .{ .timeout = result };
                self.completed.push(completion);
            },
            .write => {
                const result: WriteError!usize = if (res >= 0) @intCast(res)
                else error.InputOutput;
                completion.result = .{ .write = result };
                self.completed.push(completion);
            },
            .next_tick => unreachable,
        }
    }

    fn flush_timeouts(self: *IO) void {
        var min_timeout: ?u64 = null;
        var it = self.timeouts.iterate();
        while (it.next()) |completion| {
            const now = self.time.monotonic().ns;
            const expires = completion.operation.timeout.expires;
            if (now >= expires) {
                self.timeouts.remove(completion);
                self.completed.push(completion);
                continue;
            }
            const timeout_ns = expires - now;
            if (min_timeout) |min_ns| {
                min_timeout = @min(min_ns, timeout_ns);
            } else {
                min_timeout = timeout_ns;
            }
        }
    }

    pub const Completion = struct {
        link: QueueType(Completion).Link = .{},
        context: ?*anyopaque,
        callback: *const fn (*IO, *Completion) void,
        operation: Operation,
        result: ResultUnion = undefined,

        const ResultUnion = union {
            accept: AcceptError!socket_t,
            close: CloseError!void,
            connect: ConnectError!void,
            fsync: FsyncError!void,
            openat: OpenatError!fd_t,
            read: ReadError!usize,
            recv: RecvError!usize,
            send: SendError!usize,
            timeout: TimeoutError!void,
            write: WriteError!usize,
            next_tick: NextTickResult,
        };
    };

    const Operation = union(enum) {
        accept: struct {
            socket: socket_t,
            flags: u32,
        },
        close: struct {
            fd: fd_t,
        },
        connect: struct {
            socket: socket_t,
            address: std.net.Address,
            flags: u32,
        },
        fsync: struct {
            fd: fd_t,
        },
        openat: struct {
            dir_fd: fd_t,
            file_path: [*:0]const u8,
            flags: posix.O,
            mode: posix.mode_t,
        },
        read: struct {
            fd: fd_t,
            buf: [*]u8,
            len: u32,
            offset: u64,
        },
        recv: struct {
            socket: socket_t,
            buf: [*]u8,
            len: u32,
        },
        send: struct {
            socket: socket_t,
            buf: [*]const u8,
            len: u32,
        },
        timeout: struct {
            expires: u64,
        },
        write: struct {
            fd: fd_t,
            buf: [*]const u8,
            len: u32,
            offset: u64,
        },
        next_tick: struct {
            source: NextTickSource,
        },
    };

    fn submit(
        self: *IO,
        context: anytype,
        comptime callback: anytype,
        completion: *Completion,
        comptime operation_tag: std.meta.Tag(Operation),
        operation_data: std.meta.TagPayload(Operation, operation_tag),
    ) void {
        const on_complete_fn = struct {
            fn on_complete(_: *IO, _completion: *Completion) void {
                const result = switch (operation_tag) {
                    .accept => _completion.result.accept,
                    .close => _completion.result.close,
                    .connect => _completion.result.connect,
                    .fsync => _completion.result.fsync,
                    .openat => _completion.result.openat,
                    .read => _completion.result.read,
                    .recv => _completion.result.recv,
                    .send => _completion.result.send,
                    .timeout => _completion.result.timeout,
                    .write => _completion.result.write,
                    .next_tick => _completion.result.next_tick,
                };
                return callback(
                    @ptrCast(@alignCast(_completion.context)),
                    _completion,
                    result,
                );
            }
        }.on_complete;

        completion.* = .{
            .link = .{},
            .context = context,
            .callback = on_complete_fn,
            .operation = @unionInit(Operation, @tagName(operation_tag), operation_data),
        };

        switch (operation_tag) {
            .timeout => self.timeouts.push(completion),
            else => self.io_pending.push(completion),
        }
    }

    pub const AcceptError = posix.AcceptError || posix.SetSockOptError;

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!socket_t,
        ) void,
        completion: *Completion,
        socket: socket_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .accept,
            .{ .socket = socket, .flags = 0 },
        );
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .close,
            .{ .fd = fd },
        );
    }

    pub const ConnectError = posix.ConnectError;

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        socket: socket_t,
        address: stdx.SocketAddress,
    ) void {
        // Non-blocking connect. Use raw syscall to avoid error-set differences
        // between platforms in Zig's posix wrapper.
        const rc = posix.system.connect(
            socket,
            &address.to_std().any,
            address.to_std().getOsSockLen(),
        );
        const err = posix.errno(rc);
        switch (err) {
            .SUCCESS, .INPROGRESS, .AGAIN, .ALREADY => {
                // Connection is pending — submit POLL to wait for completion.
                self.submit(
                    context,
                    callback,
                    completion,
                    .connect,
                    .{ .socket = socket, .address = address.to_std(), .flags = 0 },
                );
            },
            else => {
                // Connection failed — complete immediately.
                const result: ConnectError!void = switch (err) {
                    .ACCES => error.AccessDenied,
                    .ADDRINUSE => error.AddressInUse,
                    .ADDRNOTAVAIL => error.AddressNotAvailable,
                    .AFNOSUPPORT => error.AddressFamilyNotSupported,
                    .AGAIN => error.WouldBlock,
                    .ALREADY => error.OpenAlreadyInProgress,
                    .BADF => error.FileDescriptorInvalid,
                    .CONNREFUSED => error.ConnectionRefused,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .FAULT => unreachable,
                    .INTR => unreachable,
                    .ISCONN => error.AlreadyConnected,
                    .NETUNREACH => error.NetworkUnreachable,
                    .NOTSOCK => error.FileDescriptorNotASocket,
                    .PERM => error.PermissionDenied,
                    .PROTOTYPE => error.ProtocolNotSupported,
                    .TIMEDOUT => error.ConnectionTimedOut,
                    .HOSTUNREACH => error.HostUnreachable,
                    .INVAL => unreachable,
                    .NOENT => error.FileNotFound,
                    else => |e| stdx.unexpected_errno("connect", e),
                };
                completion.* = .{
                    .link = .{},
                    .context = context,
                    .callback = struct {
                        fn call(io: *IO, c: *Completion) void {
                            _ = io;
                            callback(@ptrCast(@alignCast(c.context)), c, c.result.connect);
                        }
                    }.call,
                    .operation = .{ .connect = .{
                        .socket = socket,
                        .address = address.to_std(),
                        .flags = 0,
                    } },
                    .result = .{ .connect = result },
                };
                self.completed.push(completion);
            },
        }
    }

    pub const FsyncError = posix.SyncError || posix.UnexpectedError;

    pub fn fsync(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: FsyncError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .fsync,
            .{ .fd = fd },
        );
    }

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub fn openat(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: OpenatError!fd_t,
        ) void,
        completion: *Completion,
        dir_fd: fd_t,
        file_path: [*:0]const u8,
        flags: posix.O,
        mode: posix.mode_t,
    ) void {
        var new_flags = flags;
        new_flags.CLOEXEC = true;

        self.submit(
            context,
            callback,
            completion,
            .openat,
            .{
                .dir_fd = dir_fd,
                .file_path = file_path,
                .flags = new_flags,
                .mode = mode,
            },
        );
    }

    pub const ReadError = error{
        WouldBlock,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        ConnectionTimedOut,
    } || posix.UnexpectedError;

    pub fn read(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .read,
            .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
                .offset = offset,
            },
        );
    }

    pub const RecvError = posix.RecvFromError;

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .recv,
            .{
                .socket = socket,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
            },
        );
    }

    pub const SendError = error{ConnectionRefused} || posix.SendError;

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []const u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .send,
            .{
                .socket = socket,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
            },
        );
    }

    pub fn send_now(_: *IO, _: socket_t, _: []const u8) ?usize {
        return null;
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        assert(nanoseconds > 0);
        self.submit(
            context,
            callback,
            completion,
            .timeout,
            .{ .expires = self.time.monotonic().ns + nanoseconds },
        );
    }

    pub const NextTickResult = void;

    pub fn next_tick(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: NextTickResult,
        ) void,
        completion: *Completion,
        source: NextTickSource,
    ) void {
        completion.* = .{
            .link = .{},
            .context = context,
            .operation = .{ .next_tick = .{ .source = source } },
            .callback = struct {
                fn on_complete(_: *IO, _completion: *Completion) void {
                    callback(@ptrCast(@alignCast(_completion.context)), _completion, {});
                }
            }.on_complete,
            .result = .{ .next_tick = {} },
        };
        self.completed.push(completion);
    }

    pub fn reset_next_tick(self: *IO, source: NextTickSource) void {
        var completed = self.completed;
        self.completed.reset();
        while (completed.pop()) |completion| {
            if (completion.operation == .next_tick and
                completion.operation.next_tick.source == source)
            {
                continue;
            }
            self.completed.push(completion);
        }
    }

    pub const WriteError = posix.PWriteError;

    pub fn write(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []const u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .write,
            .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
                .offset = offset,
            },
        );
    }

    pub const Event = usize;
    pub const INVALID_EVENT: Event = 0;

    pub fn open_event(self: *IO) !Event {
        _ = self;
        // Use eventfd on FreeBSD (available since FreeBSD 13)
        const event_fd = posix.eventfd(0, 0) catch |err| switch (err) {
            error.SystemResources,
            error.SystemFdQuotaExceeded,
            error.ProcessFdQuotaExceeded,
            => return error.SystemResources,
            error.Unexpected => return error.Unexpected,
        };
        assert(event_fd != INVALID_EVENT);
        errdefer posix.close(event_fd);
        return @intCast(event_fd);
    }

    pub fn event_listen(
        self: *IO,
        event: Event,
        completion: *Completion,
        comptime on_event: fn (*Completion) void,
    ) void {
        assert(event != INVALID_EVENT);
        const Context = struct {
            const Ctx = @This();
            var buffer: u64 = undefined;

            fn on_read(
                _: *void,
                _completion: *Completion,
                result: ReadError!usize,
            ) void {
                _ = result catch unreachable;
                on_event(_completion);
            }
        };
        self.read(
            *void,
            @constCast(&{}),
            Context.on_read,
            completion,
            @as(fd_t, @intCast(event)),
            std.mem.asBytes(&Context.buffer),
            0,
        );
    }

    pub fn event_trigger(self: *IO, event: Event, completion: *Completion) void {
        _ = self;
        _ = completion;
        const value: u64 = 1;
        const bytes = posix.write(@as(fd_t, @intCast(event)), std.mem.asBytes(&value)) catch unreachable;
        assert(bytes == @sizeOf(u64));
    }

    pub fn close_event(self: *IO, event: Event) void {
        _ = self;
        posix.close(@as(fd_t, @intCast(event)));
    }

    pub const socket_t = posix.socket_t;

    pub fn open_socket_tcp(
        self: *IO,
        family: stdx.IPAddress.Family,
        options: TCPOptions,
    ) !socket_t {
        const fd = try self.open_socket(
            family.to_std(),
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer self.close_socket(fd);
        try common.tcp_options(fd, options);
        return fd;
    }

    pub fn open_socket_udp(self: *IO, family: stdx.IPAddress.Family) !socket_t {
        return try self.open_socket(
            family.to_std(),
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.UDP,
        );
    }

    fn open_socket(self: *IO, family: u32, sock_type: u32, protocol: u32) !socket_t {
        const fd = try posix.socket(
            family,
            sock_type | posix.SOCK.NONBLOCK,
            protocol,
        );
        errdefer self.close_socket(fd);
        _ = try posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
        try common.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, 1);
        return fd;
    }

    pub fn close_socket(self: *IO, socket: socket_t) void {
        _ = self;
        posix.close(socket);
    }

    pub fn listen(
        _: *IO,
        fd: socket_t,
        address: stdx.SocketAddress,
        options: ListenOptions,
    ) !stdx.SocketAddress {
        return common.listen(fd, address, options);
    }

    pub fn shutdown(_: *IO, socket: socket_t, how: posix.ShutdownHow) posix.ShutdownError!void {
        return posix.shutdown(socket, how);
    }

    pub fn open_dir(dir_path: []const u8) !fd_t {
        return posix.open(dir_path, .{ .CLOEXEC = true, .ACCMODE = .RDONLY }, 0);
    }

    pub const fd_t = posix.fd_t;
    pub const INVALID_FILE: fd_t = -1;

    pub const OpenDataFilePurpose = enum { format, open, inspect };

    pub fn open_data_file(
        self: *IO,
        dir_fd: fd_t,
        relative_path: []const u8,
        size: u64,
        purpose: OpenDataFilePurpose,
        direct_io: DirectIO,
    ) !fd_t {
        _ = self;
        assert(relative_path.len > 0);
        assert(size % constants.sector_size == 0);

        var flags: posix.O = .{
            .CLOEXEC = true,
            .ACCMODE = if (purpose == .inspect) .RDONLY else .RDWR,
            .DSYNC = true,
        };
        var mode: posix.mode_t = 0;

        if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;

        switch (purpose) {
            .format => {
                flags.CREAT = true;
                flags.EXCL = true;
                mode = 0o600;
            },
            .open, .inspect => {},
        }

        assert(flags.DSYNC);
        assert(!std.fs.path.isAbsolute(relative_path));

        if (direct_io != .direct_io_disabled) {
            flags.DIRECT = true;
        }

        const fd = try posix.openat(dir_fd, relative_path, flags, mode);
        errdefer posix.close(fd);

        posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => {
                if (purpose == .inspect) {
                    log.warn("another process holds the data file lock", .{});
                } else {
                    @panic("another process holds the data file lock");
                }
            },
            else => return err,
        };

        if (purpose == .format) try fs_allocate(fd, size);
        try posix.fsync(fd);
        try posix.fsync(dir_fd);

        const stat = try posix.fstat(fd);
        if (stat.size < size) @panic("data file inode size was truncated or corrupted");

        return fd;
    }

    fn fs_sync(fd: fd_t) !void {
        try posix.fsync(fd);
    }

    fn fs_allocate(fd: fd_t, size: u64) !void {
        log.info("allocating {}...", .{std.fmt.fmtIntSizeBin(size)});
        posix.ftruncate(fd, @intCast(size)) catch |err| switch (err) {
            error.AccessDenied => return error.PermissionDenied,
            else => |e| return e,
        };
    }

    pub const PReadError = posix.PReadError;

    pub fn aof_blocking_write_all(_: *IO, fd: fd_t, buffer: []const u8) posix.WriteError!void {
        return common.aof_blocking_write_all(fd, buffer);
    }

    pub fn aof_blocking_pread_all(_: *IO, fd: fd_t, buffer: []u8, offset: u64) PReadError!usize {
        return common.aof_blocking_pread_all(fd, buffer, offset);
    }

    pub fn aof_blocking_close(_: *IO, fd: fd_t) void {
        return common.aof_blocking_close(fd);
    }

    pub fn aof_blocking_stat(_: *IO, path: []const u8) std.fs.Dir.StatFileError!std.fs.File.Stat {
        return common.aof_blocking_stat(path);
    }

    pub fn aof_blocking_fstat(_: *IO, fd: fd_t) std.fs.Dir.StatError!std.fs.File.Stat {
        return common.aof_blocking_fstat(fd);
    }

    pub fn aof_blocking_open(io: *IO, path: []const u8) !fd_t {
        stdx.maybe(std.fs.path.isAbsolute(path));
        const dir_path = std.fs.path.dirname(path) orelse ".";
        const dir_fd = try IO.open_dir(dir_path);
        defer io.aof_blocking_close(dir_fd);
        const file_path = std.fs.path.basename(path);
        return common.aof_blocking_open(dir_fd, file_path);
    }
};
