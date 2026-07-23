const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

const IO_Linux = @import("io/linux.zig").IO;
const IO_Darwin = @import("io/darwin.zig").IO;
const IO_Windows = @import("io/windows.zig").IO;
const IO_FreeBSD = @import("io/freebsd.zig").IO;

// To use the IOR-based backend on FreeBSD (improves file I/O performance):
//   1. Run ./scripts/setup-ior.sh to build the IOR library
//   2. Uncomment the line below:
//
//       const IO_FreeBSD_IOR = @import("io/freebsd_ior.zig").IO;
//
//   3. Change this line:
//
//       .freebsd => IO_FreeBSD_IOR,
//
//   The IOR backend uses a thread pool + kqueue for async file operations,
//   while the default kqueue backend uses synchronous pwrite/pread.
const use_ior_backend = false;

pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Linux,
    .windows => IO_Windows,
    .macos, .tvos, .watchos, .ios => IO_Darwin,
    .freebsd => IO_FreeBSD,
    else => @compileError("IO is not supported for platform"),
};

pub const DirectIO = enum {
    direct_io_required,
    direct_io_optional,
    direct_io_disabled,
};

pub fn buffer_limit(buffer_len: usize) usize {
    // Linux limits how much may be written in a `pwrite()/pread()` call, which is `0x7ffff000` on
    // both 64-bit and 32-bit systems, due to using a signed C int as the return value, as well as
    // stuffing the errno codes into the last `4096` values.
    // Darwin limits writes to `0x7fffffff` bytes, more than that returns `EINVAL`.
    // The corresponding POSIX limit is `std.math.maxInt(isize)`.
    const limit = switch (builtin.target.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    return @min(limit, buffer_len);
}
