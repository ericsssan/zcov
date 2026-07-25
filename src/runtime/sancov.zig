//! SanitizerCoverage runtime callbacks for zig-cov.
//!
//! When a Zig test binary is compiled with:
//!   unit_tests.root_module.sanitize_coverage_trace_pc_guard = true;
//!
//! ...LLVM inserts calls to __sanitizer_cov_trace_pc_guard_init and
//! __sanitizer_cov_trace_pc_guard at every instrumented control-flow edge.
//!
//! This file provides those callbacks. On process exit it writes a .zcov
//! file containing the PC addresses of every edge that was executed.
//!
//! Environment variables:
//!   ZIG_COV_DIR   Output directory for .zcov files (default: current dir)
//!
//! Build integration: users add to their build.zig:
//!   const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
//!   const rt_path  = b.option([]const u8, "coverage-rt", "zig-cov-rt.a path") orelse null;
//!   if (coverage) {
//!       unit_tests.root_module.sanitize_coverage_trace_pc_guard = true;
//!       if (rt_path) |p| unit_tests.addObjectFile(.{ .cwd_relative = p });
//!   }

const builtin = @import("builtin");
const std = @import("std");
const zcov = @import("zcov_format.zig");

// ---------------------------------------------------------------------------
// Required SanitizerCoverage ABI symbols
// ---------------------------------------------------------------------------

/// LLVM's -fsanitize-coverage-trace-pc-guard instrumentation reads and writes
/// this thread-local variable to track the lowest stack pointer seen per thread
/// (used for stack-depth coverage). We provide the symbol to satisfy the linker;
/// zig-cov does not use its value.
export threadlocal var __sancov_lowest_stack: usize = std.math.maxInt(usize);

// ---------------------------------------------------------------------------
// Global state (lives in BSS; initialized to zero)
// ---------------------------------------------------------------------------

/// Maximum number of executed edges this runtime can record.
/// Each slot holds one PC (8 bytes). At 1M slots: 8 MB BSS, zero disk space.
/// Binaries that execute more than 1M distinct edges get a warning and truncated
/// output — vastly more capacity than any real project needs.
const MAX_EDGE_IDS: usize = 1 << 20; // 1 048 576

/// Compact list of PCs captured at runtime (one entry per executed edge).
/// Slots are allocated atomically by __sanitizer_cov_trace_pc_guard.
var hit_pcs: [MAX_EDGE_IDS]u64 = @splat(0);

/// Number of slots consumed so far. May exceed MAX_EDGE_IDS on overflow.
var hit_count: std.atomic.Value(u32) = .init(0);

/// Next available edge ID (1-based; guard value 0 means "already seen").
var next_id: std.atomic.Value(u32) = .init(1);

/// Whether atexit has been registered.
var atexit_registered: bool = false;

/// Protects atexit_registered and next_id initialization.
var init_mutex: std.atomic.Mutex = .unlocked;

// ---------------------------------------------------------------------------
// SanitizerCoverage callbacks
// ---------------------------------------------------------------------------

/// Called once per instrumented module at startup.
/// Assigns sequential IDs to each guard in [start, stop).
export fn __sanitizer_cov_trace_pc_guard_init(
    start: [*]u32,
    stop: [*]u32,
) callconv(.c) void {
    if (start == stop) return;
    // Check if already initialized (guard value != 0 means we already set it).
    if (start[0] != 0) return;

    while (!init_mutex.tryLock()) {}
    defer init_mutex.unlock();

    // Re-check under lock.
    if (start[0] != 0) return;

    var p = start;
    while (@intFromPtr(p) < @intFromPtr(stop)) : (p += 1) {
        // Assign a unique non-zero ID. All edges get a valid ID regardless of
        // count — overflow is handled at the hit_pcs level, not here.
        p[0] = next_id.fetchAdd(1, .monotonic);
    }

    // Register exit handler once.
    if (!atexit_registered) {
        _ = atexit(writeCoverageOnExit);
        atexit_registered = true;
    }
}

/// Called on every instrumented control-flow edge (if guard != 0).
/// Hot path: < 5ns target. After first hit, guard is zeroed to prevent
/// future calls (fast-path branch in generated code).
export fn __sanitizer_cov_trace_pc_guard(guard: *u32) callconv(.c) void {
    if (guard.* == 0) return;

    // Capture the return address (= the instrumented PC in the caller).
    const pc: u64 = @returnAddress();

    // Claim a slot in the compact hit list atomically.
    const slot = hit_count.fetchAdd(1, .monotonic);
    if (slot < MAX_EDGE_IDS) {
        hit_pcs[slot] = pc;
    }
    // If slot >= MAX_EDGE_IDS the PC is silently dropped — writeCoverage warns.

    // Zero the guard so the compiler's fast-path check prevents future calls.
    guard.* = 0;
}

// ---------------------------------------------------------------------------
// Exit handler
// ---------------------------------------------------------------------------

fn writeCoverageOnExit() callconv(.c) void {
    writeCoverage() catch |err| {
        std.debug.print("zig-cov: failed to write coverage: {}\n", .{err});
    };
}

fn writeCoverage() !void {
    const total = hit_count.load(.monotonic);
    if (total == 0) return;

    if (total > MAX_EDGE_IDS) {
        std.debug.print(
            "zig-cov: WARNING: {d} edges executed but only {d} PCs stored " ++
                "(coverage data is incomplete; increase MAX_EDGE_IDS in sancov.zig)\n",
            .{ total, MAX_EDGE_IDS },
        );
    }
    const valid: usize = @min(total, MAX_EDGE_IDS);

    // Determine the ASLR slide so the report generator can compute virtual addrs.
    const slide = getAslrSlide();

    // Get an Io instance from the global single-threaded runtime.
    const io = std.Io.Threaded.global_single_threaded.io();

    // Get our own executable path.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch 0;
    const bin_path: []const u8 = if (exe_len > 0) exe_buf[0..exe_len] else "<unknown>";

    // Determine output directory from env var.
    const out_dir_cstr = std.c.getenv("ZIG_COV_DIR");
    const out_dir: []const u8 = if (out_dir_cstr) |cstr| std.mem.span(cstr) else ".";

    // Build output file path: <dir>/coverage-<pid>.zcov (null-terminated for fopen)
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pid = std.c.getpid();
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/coverage-{d}.zcov", .{ out_dir, pid }, 0) catch |e| {
        std.debug.print("zig-cov: path too long: {}\n", .{e});
        return;
    };

    try zcov.write(path, slide, bin_path, hit_pcs[0..valid]);
}

/// Returns the ASLR slide for the current process.
/// The slide is subtracted from runtime PCs to get virtual addresses that
/// match the addresses stored in DWARF debug information.
fn getAslrSlide() i64 {
    // Use a known address in our own code as the "runtime address".
    // std.debug.SelfInfo can give us the corresponding virtual address.
    const runtime_addr: usize = @intFromPtr(&__sanitizer_cov_trace_pc_guard_init);
    const io = std.Io.Threaded.global_single_threaded.io();
    const si = std.debug.getSelfDebugInfo() catch return 0;
    const slide = si.getModuleSlide(io, runtime_addr) catch return 0;
    return @intCast(slide);
}

// ---------------------------------------------------------------------------
// Platform-specific helpers
// ---------------------------------------------------------------------------

extern fn atexit(callback: *const fn () callconv(.c) void) c_int;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "guard_init assigns sequential IDs" {
    // Reset state
    next_id.store(1, .monotonic);
    atexit_registered = false;

    var guards = [_]u32{ 0, 0, 0 };
    const gp: [*]u32 = @ptrCast(&guards);
    __sanitizer_cov_trace_pc_guard_init(gp, gp + guards.len);

    try std.testing.expect(guards[0] >= 1);
    try std.testing.expect(guards[1] == guards[0] + 1);
    try std.testing.expect(guards[2] == guards[1] + 1);
}

test "trace_pc_guard records PC and zeroes guard" {
    // Reset state
    hit_count.store(0, .monotonic);
    hit_pcs = @splat(0);

    var guard: u32 = 5; // pretend guard 5 was assigned
    __sanitizer_cov_trace_pc_guard(&guard);

    // Guard should be zeroed after first hit
    try std.testing.expectEqual(@as(u32, 0), guard);
    // Exactly one PC should have been recorded
    try std.testing.expectEqual(@as(u32, 1), hit_count.load(.monotonic));
    // Recorded PC should be non-zero
    try std.testing.expect(hit_pcs[0] != 0);
}

test "trace_pc_guard skips already-zeroed guard" {
    hit_count.store(0, .monotonic);

    var guard: u32 = 0; // already seen
    __sanitizer_cov_trace_pc_guard(&guard);

    // Nothing should have been recorded
    try std.testing.expectEqual(@as(u32, 0), hit_count.load(.monotonic));
}

// ---------------------------------------------------------------------------
// Regression tests
// ---------------------------------------------------------------------------

test "regression: guard_init assigns non-zero IDs beyond old MAX_EDGES limit" {
    // Old bug (fixed): when next_id >= (1 << 18), _init wrote 0 to the guard.
    // LLVM's inline check treats guard==0 as "already seen" and never calls
    // trace_pc_guard, silently dropping coverage for every edge past that limit.
    //
    // Fix: _init now assigns all guards unconditionally; overflow is handled
    // at the hit_pcs level, not here.
    const old_limit: u32 = 1 << 18;

    const saved_next_id = next_id.load(.monotonic);
    const saved_atexit = atexit_registered;
    defer next_id.store(saved_next_id, .monotonic);
    defer atexit_registered = saved_atexit;

    // Position next_id so the very first assignment crosses the old limit.
    next_id.store(old_limit - 1, .monotonic);
    atexit_registered = true; // suppress atexit registration side-effect

    var guards = [_]u32{ 0, 0, 0 };
    const gp: [*]u32 = @ptrCast(&guards);
    __sanitizer_cov_trace_pc_guard_init(gp, gp + guards.len);

    // All three guards must receive non-zero IDs — none silently dropped.
    try std.testing.expect(guards[0] != 0);
    try std.testing.expect(guards[1] != 0);
    try std.testing.expect(guards[2] != 0);
    // IDs must be sequential and start at old_limit - 1.
    try std.testing.expectEqual(old_limit - 1, guards[0]);
    try std.testing.expectEqual(old_limit, guards[1]);
    try std.testing.expectEqual(old_limit + 1, guards[2]);
}

test "regression: trace_pc_guard overflow increments hit_count without writing out of bounds" {
    // When hit_count reaches MAX_EDGE_IDS the hit_pcs array is full.
    // Further calls must NOT write past the array end, but must continue
    // incrementing hit_count so writeCoverage can detect and report the overflow.
    const cap: u32 = @intCast(MAX_EDGE_IDS);

    const saved_count = hit_count.load(.monotonic);
    const saved_last = hit_pcs[MAX_EDGE_IDS - 1];
    defer hit_count.store(saved_count, .monotonic);
    defer hit_pcs[MAX_EDGE_IDS - 1] = saved_last;

    // Position count at the last valid slot.
    hit_count.store(cap - 1, .monotonic);
    hit_pcs[MAX_EDGE_IDS - 1] = 0;

    // This call should fill the last slot.
    var guard1: u32 = 10;
    __sanitizer_cov_trace_pc_guard(&guard1);
    try std.testing.expectEqual(@as(u32, 0), guard1);
    try std.testing.expectEqual(cap, hit_count.load(.monotonic));
    try std.testing.expect(hit_pcs[MAX_EDGE_IDS - 1] != 0); // last slot written

    // This call exceeds capacity: count increments (detectable overflow) but
    // no out-of-bounds write occurs. If we regress, this crashes with a
    // safety-check failure in ReleaseSafe / Debug.
    var guard2: u32 = 11;
    __sanitizer_cov_trace_pc_guard(&guard2);
    try std.testing.expectEqual(@as(u32, 0), guard2);
    try std.testing.expectEqual(cap + 1, hit_count.load(.monotonic));
}
