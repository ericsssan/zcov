//! Coverage runtime for zig-cov.
//!
//! When a Zig test binary is compiled with:
//!   unit_tests.root_module.fuzz = true;   // + use_llvm = true, link_libc = true
//!
//! ...LLVM emits inline 8-bit counters and a table of the program counters they
//! belong to, in two sections:
//!
//!   __sancov_cntrs   [*]u8     one byte per instrumented block, incremented in
//!                              line (no call), saturating
//!   __sancov_pcs1    [*]usize  the address of each block, index for index
//!
//! This runtime reads both at process exit and writes them to a .zcov file. It
//! defines no `__sanitizer_cov_*` callbacks, which is what lets it coexist with
//! Zig's own fuzzer runtime that `fuzz = true` also links in.
//!
//! Recording the whole table, not just what ran, is the point: a block with a
//! zero counter is a genuine miss, and the table's addresses mark block
//! boundaries so the reporter can expand an executed block across its lines.
//!
//! Environment variables:
//!   ZIG_COV_DIR     Output directory for .zcov files (default: current dir)
//!   ZIG_COV_DEBUG   Print what was recorded
//!
//! Build integration: users add to their build.zig:
//!   const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
//!   const rt_path  = b.option([]const u8, "coverage-rt", "zig-cov-rt.o path") orelse null;
//!   if (coverage) {
//!       unit_tests.use_llvm = true;
//!       unit_tests.root_module.fuzz = true;
//!       unit_tests.root_module.link_libc = true;
//!       if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
//!   }

const builtin = @import("builtin");
const std = @import("std");
const zcov = @import("zcov_format.zig");

// ---------------------------------------------------------------------------
// Instrumentation sections
// ---------------------------------------------------------------------------

/// The linker synthesises start/stop symbols for sections whose names are valid
/// C identifiers; Mach-O spells them differently from ELF.
const section_start_prefix = switch (builtin.object_format) {
    .elf => "__start_",
    .macho => "\x01section$start$__DATA$",
    else => "", // unsupported: bounds resolve empty and nothing is written
};
const section_end_prefix = switch (builtin.object_format) {
    .elf => "__stop_",
    .macho => "\x01section$end$__DATA$",
    else => "",
};

/// Bounds of a section, or an empty slice when the binary was not instrumented.
fn sectionBounds(comptime T: type, comptime name: []const u8) []T {
    if (section_start_prefix.len == 0) return &.{};
    const start = @extern([*]T, .{ .name = section_start_prefix ++ name, .linkage = .weak }) orelse return &.{};
    const end = @extern([*]T, .{ .name = section_end_prefix ++ name, .linkage = .weak }) orelse return &.{};
    const bytes = @intFromPtr(end) - @intFromPtr(start);
    return start[0 .. bytes / @sizeOf(T)];
}

/// One byte per instrumented block, incremented inline by the instrumentation.
fn counters() []const u8 {
    return sectionBounds(u8, "__sancov_cntrs");
}

/// Runtime address of each instrumented block, parallel to `counters()`.
fn blockPcs() []const usize {
    return sectionBounds(usize, "__sancov_pcs1");
}

// ---------------------------------------------------------------------------
// Exit handling
// ---------------------------------------------------------------------------

var registered: bool = false;

fn writeCoverageOnExit() callconv(.c) void {
    writeCoverage() catch |err| {
        std.debug.print("zig-cov: failed to write coverage: {}\n", .{err});
    };
}

fn writeCoverage() !void {
    const cntrs = counters();
    const pcs = blockPcs();
    if (cntrs.len == 0 or pcs.len == 0) return; // not instrumented

    if (cntrs.len != pcs.len) {
        std.debug.print(
            "zig-cov: counter/PC table length mismatch ({d} != {d}); skipping\n",
            .{ cntrs.len, pcs.len },
        );
        return;
    }

    const slide = getAslrSlide();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Our own executable path, so the reporter knows which binary's debug info
    // to resolve these addresses against.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch 0;
    const bin_path: []const u8 = if (exe_len > 0) exe_buf[0..exe_len] else "<unknown>";

    const out_dir_cstr = std.c.getenv("ZIG_COV_DIR");
    const out_dir: []const u8 = if (out_dir_cstr) |cstr| std.mem.span(cstr) else ".";

    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pid = std.c.getpid();
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/coverage-{d}.zcov", .{ out_dir, pid }, 0) catch |e| {
        std.debug.print("zig-cov: path too long: {}\n", .{e});
        return;
    };

    if (std.c.getenv("ZIG_COV_DEBUG") != null) {
        var hit: usize = 0;
        for (cntrs) |c| if (c != 0) {
            hit += 1;
        };
        std.debug.print(
            "zig-cov[debug]: {d}/{d} blocks executed; writing {s} (ZIG_COV_DIR={s})\n",
            .{ hit, cntrs.len, path, out_dir },
        );
    }

    // `pcs` is []const usize; the format stores u64. They are the same width on
    // the targets zig-cov supports, so the table can be passed through directly.
    try zcov.write(path, slide, bin_path, @ptrCast(pcs), cntrs);
}

/// Registered as an ELF `.init_array` / Mach-O `__mod_init_func` entry, which
/// the C runtime calls before main. Using a constructor rather than a
/// `__sanitizer_cov_*` callback avoids clashing with Zig's fuzzer runtime.
fn registerAtExit() callconv(.c) void {
    if (registered) return;
    registered = true;
    _ = atexit(&writeCoverageOnExit);
}

const ctor_section = switch (builtin.object_format) {
    .elf => ".init_array",
    .macho => "__DATA,__mod_init_func",
    else => ".init_array",
};

export const zig_cov_ctor: *const fn () callconv(.c) void linksection(ctor_section) = &registerAtExit;

/// Returns the ASLR slide for the current process.
/// The slide is subtracted from runtime PCs to get virtual addresses that
/// match the addresses stored in DWARF debug information.
fn getAslrSlide() i64 {
    const runtime_addr: usize = @intFromPtr(&registerAtExit);
    const io = std.Io.Threaded.global_single_threaded.io();
    const si = std.debug.getSelfDebugInfo() catch return 0;
    const slide = si.getModuleSlide(io, runtime_addr) catch return 0;
    return @intCast(slide);
}

extern fn atexit(callback: *const fn () callconv(.c) void) c_int;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "section bounds are empty when the binary is not instrumented" {
    // The test binary for this file is built without coverage, so the sancov
    // sections do not exist and the weak symbols resolve to null. The runtime
    // must treat that as "nothing to record" rather than misbehaving.
    try std.testing.expectEqual(@as(usize, 0), counters().len);
    try std.testing.expectEqual(@as(usize, 0), blockPcs().len);
}

test "writeCoverage is a no-op without instrumentation" {
    // Must not write a file or fail when there is no coverage data.
    try writeCoverage();
}

test "registerAtExit is idempotent" {
    const saved = registered;
    defer registered = saved;
    registered = false;
    registerAtExit();
    try std.testing.expect(registered);
    registerAtExit(); // must not register a second handler
    try std.testing.expect(registered);
}
