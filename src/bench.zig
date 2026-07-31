//! Synthetic benchmarks for zig-cov.
//!
//! Measures the two paths zig-cov actually owns. The instrumentation hot path
//! is not benchmarked because zig-cov has no code on it: LLVM emits an inline
//! byte increment per block, and the runtime only reads the counters once, at
//! process exit.
//!
//!   bench 2 — coverage.Builder.recordHit throughput
//!             (1 000 files × 100 lines = 100 000 calls)
//!
//!   bench 3 — report generation throughput
//!             (10 000 files × 10 lines → LCOV + summary write)
//!
//! Performance targets (from the design doc):
//!   recordHit                ≤ 10 000 ms total for 100 K calls (generous)
//!   LCOV write (10 K files)  ≤ 5 000 ms
//!   summary write            ≤ 1 000 ms

const std = @import("std");
const coverage = @import("coverage.zig");
const lcov_report = @import("report/lcov.zig");
const summary_report = @import("report/summary.zig");

// ---------------------------------------------------------------------------
// Global state: keeps large arrays out of stack frames.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    std.debug.print("\n=== zig-cov synthetic benchmarks ===\n", .{});
    std.debug.print("(lower is better; WARN = above target)\n\n", .{});

    try benchCoverageModel(io, gpa);
    try benchReportGeneration(io, gpa);
}

// ---------------------------------------------------------------------------
// Helper: current monotonic nanosecond timestamp
// ---------------------------------------------------------------------------

inline fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

// ---------------------------------------------------------------------------
// Bench 2: coverage.Builder.recordHit throughput
// ---------------------------------------------------------------------------
//
// Simulates processing a .zcov file with many PC hits spread across many files.
// Two phases are timed separately:
//   recordHit  — hash-map insert/update (dominates report-gen time in practice)
//   build()    — sort + finalise into CoverageData

fn benchCoverageModel(io: std.Io, gpa: std.mem.Allocator) !void {
    const N_FILES: usize = 1_000;
    const N_LINES: usize = 100;
    const N_TOTAL: usize = N_FILES * N_LINES;

    // Pre-build path strings so string allocation is not measured.
    const paths = try gpa.alloc([]u8, N_FILES);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
    for (paths, 0..) |*p, i| {
        p.* = try std.fmt.allocPrint(gpa, "/src/file_{d:0>4}.zig", .{i});
    }

    var builder = coverage.Builder.init(gpa);
    defer builder.deinit();

    const t0 = nowNs(io);

    for (0..N_FILES) |fi| {
        for (0..N_LINES) |li| {
            try builder.recordHit(paths[fi], @intCast(li + 1));
        }
    }

    const t1 = nowNs(io);

    var cov_data = try builder.build();
    defer cov_data.deinit();

    const t2 = nowNs(io);

    const record_ns: u64 = @intCast(t1 - t0);
    const build_ns: u64 = @intCast(t2 - t1);
    const ns_per_call = record_ns / N_TOTAL;

    std.debug.print("bench 2 — coverage model ({d} files × {d} lines = {d} total)\n", .{ N_FILES, N_LINES, N_TOTAL });
    std.debug.print("  recordHit: {d:>6} ms  ({d} ns/call)\n", .{ record_ns / std.time.ns_per_ms, ns_per_call });
    std.debug.print("  build():   {d:>6} ms\n\n", .{build_ns / std.time.ns_per_ms});
}

// ---------------------------------------------------------------------------
// Bench 3: Report generation throughput  (LCOV + summary)
// ---------------------------------------------------------------------------
//
// Builds a larger dataset and measures how long each report format takes to
// serialise. Writes into an in-memory Allocating writer so I/O latency is
// excluded from the measurement.

fn benchReportGeneration(io: std.Io, gpa: std.mem.Allocator) !void {
    const N_FILES: usize = 10_000;
    const N_LINES: usize = 10;

    const paths = try gpa.alloc([]u8, N_FILES);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
    for (paths, 0..) |*p, i| {
        p.* = try std.fmt.allocPrint(gpa, "/src/file_{d:0>5}.zig", .{i});
    }

    var builder = coverage.Builder.init(gpa);
    defer builder.deinit();
    for (0..N_FILES) |fi| {
        for (0..N_LINES) |li| {
            if (li % 2 == 0) try builder.recordHit(paths[fi], @intCast(li + 1));
        }
    }
    var cov_data = try builder.build();
    defer cov_data.deinit();

    std.debug.print("bench 3 — report generation ({d} files × {d} lines)\n", .{ N_FILES, N_LINES });

    // LCOV
    {
        var buf = std.Io.Writer.Allocating.init(gpa);
        defer buf.deinit();

        const t0 = nowNs(io);
        try lcov_report.write(gpa, &buf.writer, &cov_data, .{});
        try buf.writer.flush();
        const t1 = nowNs(io);

        const ms: u64 = @as(u64, @intCast(t1 - t0)) / std.time.ns_per_ms;
        const pass = if (ms <= 5_000) "PASS" else "WARN";
        std.debug.print("  LCOV write:    {d:>6} ms  ({d} bytes)  (target: ≤5000 ms)  [{s}]\n", .{
            ms, buf.written().len, pass,
        });
    }

    // Summary (no colour so output is stable)
    {
        var buf = std.Io.Writer.Allocating.init(gpa);
        defer buf.deinit();

        const t0 = nowNs(io);
        _ = try summary_report.write(&buf.writer, &cov_data, .{ .color = false, .fail_under = 0 });
        try buf.writer.flush();
        const t1 = nowNs(io);

        const ms: u64 = @as(u64, @intCast(t1 - t0)) / std.time.ns_per_ms;
        const pass = if (ms <= 1_000) "PASS" else "WARN";
        std.debug.print("  summary write: {d:>6} ms  ({d} bytes)  (target: ≤1000 ms)  [{s}]\n\n", .{
            ms, buf.written().len, pass,
        });
    }
}
