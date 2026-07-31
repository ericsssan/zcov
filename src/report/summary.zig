//! Terminal summary report.
//!
//! Prints a table like:
//!
//!   File                       Lines      Functions
//!   src/parser.zig             87.3% (32/36)   92.0% (11/12)
//!   src/tokenizer.zig          94.1% (16/17)   100%  (5/5)
//!   ─────────────────────────────────────────────────
//!   Total                      90.6% (48/53)   95.3% (16/17)
//!
//! Color coding (when terminal supports it):
//!   Green  ≥ 80%
//!   Yellow ≥ 60%
//!   Red    < 60%

const std = @import("std");
const coverage = @import("../coverage.zig");

const ANSI_GREEN = "\x1b[32m";
const ANSI_YELLOW = "\x1b[33m";
const ANSI_RED = "\x1b[31m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_RESET = "\x1b[0m";

const COL_FILE = 40;
const COL_LINES = 22;
const COL_FUNCS = 22;

pub const Options = struct {
    /// Emit ANSI color codes.
    color: bool = true,
    /// Minimum coverage to exit 0 (0 = no threshold check).
    fail_under: f64 = 0,
};

/// Write the summary table to `writer`.
/// Returns true if coverage passes `opts.fail_under` (or no threshold set).
pub fn write(writer: *std.Io.Writer, data: *const coverage.CoverageData, opts: Options) !bool {
    // Header
    try writePadded(writer, "File", COL_FILE);
    try writePadded(writer, "Lines", COL_LINES);
    try writer.writeAll("Functions\n");

    const sep_len = COL_FILE + COL_LINES + COL_FUNCS;
    try writeRepeat(writer, "─", sep_len);
    try writer.writeByte('\n');

    // Sort files by path for deterministic output.
    // (data.files is already unsorted; we sort here without modifying data)
    var sorted: std.ArrayList(*const coverage.FileCoverage) = .empty;
    defer sorted.deinit(std.heap.page_allocator);
    for (data.files) |*fc| try sorted.append(std.heap.page_allocator, fc);
    std.mem.sort(*const coverage.FileCoverage, sorted.items, {}, struct {
        fn lt(_: void, a: *const coverage.FileCoverage, b: *const coverage.FileCoverage) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    for (sorted.items) |fc| {
        const lf = fc.lines.len;
        var lh: usize = 0;
        for (fc.lines) |lc| if (lc.hit_count > 0) {
            lh += 1;
        };
        const lpct: f64 = if (lf == 0) 100.0 else @as(f64, @floatFromInt(lh)) / @as(f64, @floatFromInt(lf)) * 100.0;

        const ff = fc.functions.len;
        var fh: usize = 0;
        for (fc.functions) |fn_cov| if (fn_cov.hit_count > 0) {
            fh += 1;
        };
        const fpct: f64 = if (ff == 0) 100.0 else @as(f64, @floatFromInt(fh)) / @as(f64, @floatFromInt(ff)) * 100.0;

        // Trim long paths to fit column
        const display_path = trimPath(fc.path, COL_FILE - 2);
        try writePadded(writer, display_path, COL_FILE);
        try writePercent(writer, lpct, lh, lf, COL_LINES, opts.color);
        try writePercent(writer, fpct, fh, ff, COL_FUNCS, opts.color);
        try writer.writeByte('\n');
    }

    // Footer total
    try writeRepeat(writer, "─", sep_len);
    try writer.writeByte('\n');

    const total_lf = data.summary.lines_found;
    const total_lh = data.summary.lines_hit;
    const total_ff = data.summary.functions_found;
    const total_fh = data.summary.functions_hit;
    const total_lpct = data.summary.linePercent();
    const total_fpct = data.summary.functionPercent();

    if (opts.color) try writer.writeAll(ANSI_BOLD);
    try writePadded(writer, "Total", COL_FILE);
    try writePercent(writer, total_lpct, total_lh, total_lf, COL_LINES, opts.color);
    try writePercent(writer, total_fpct, total_fh, total_ff, COL_FUNCS, opts.color);
    if (opts.color) try writer.writeAll(ANSI_RESET);
    try writer.writeByte('\n');

    // Block coverage, when available. This is what the counters literally
    // recorded, with no line attribution in between, so it is exact — worth
    // showing next to the line figure, which is an estimate.
    if (data.summary.blocks_found > 0) {
        try writer.print(
            "Blocks (exact)                          {d:.1}% ({d}/{d})\n",
            .{ data.summary.blockPercent(), data.summary.blocks_hit, data.summary.blocks_found },
        );
    }

    const passes = opts.fail_under == 0 or total_lpct >= opts.fail_under;
    if (!passes) {
        try writer.print(
            "Coverage {d:.1}% is below the threshold of {d:.1}%\n",
            .{ total_lpct, opts.fail_under },
        );
    }
    return passes;
}

fn writePadded(writer: *std.Io.Writer, s: []const u8, width: usize) !void {
    try writer.writeAll(s);
    if (s.len < width) {
        try writeRepeat(writer, " ", width - s.len);
    }
}

fn writeRepeat(writer: *std.Io.Writer, s: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try writer.writeAll(s);
}

fn writePercent(
    writer: *std.Io.Writer,
    pct: f64,
    hit: usize,
    total: usize,
    col_width: usize,
    color: bool,
) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.1}% ({d}/{d})", .{ pct, hit, total }) catch buf[0..0];

    if (color) {
        const code = colorFor(pct);
        try writer.writeAll(code);
    }
    try writePadded(writer, text, col_width);
    if (color) try writer.writeAll(ANSI_RESET);
}

fn colorFor(pct: f64) []const u8 {
    if (pct >= 80.0) return ANSI_GREEN;
    if (pct >= 60.0) return ANSI_YELLOW;
    return ANSI_RED;
}

fn trimPath(path: []const u8, max_len: usize) []const u8 {
    if (path.len <= max_len) return path;
    // Show the last `max_len - 3` characters with "..." prefix.
    return path[path.len - (max_len - 3)..];
}

test "summary write no crash" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/main.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{
            .lines_found = 2,
            .lines_hit = 1,
            .functions_found = 0,
            .functions_hit = 0,
        },
    };
    const passes = try write(&buf.writer, &data, .{ .color = false });
    try std.testing.expect(passes);
    try std.testing.expect(buf.written().len > 0);
}

test "summary output contains file path and percentage" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 1 },
        .{ .line = 3, .hit_count = 0 },
        .{ .line = 4, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/parser.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 4, .lines_hit = 2, .functions_found = 0, .functions_hit = 0 },
    };

    _ = try write(&buf.writer, &data, .{ .color = false });
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "src/parser.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Total") != null);
}

test "summary fail_under passes when coverage is above threshold" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 1 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/x.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 2, .lines_hit = 2, .functions_found = 0, .functions_hit = 0 },
    };

    const passes = try write(&buf.writer, &data, .{ .color = false, .fail_under = 80.0 });
    try std.testing.expect(passes); // 100% >= 80%
}

test "summary fail_under fails when coverage is below threshold" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/y.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 2, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    const passes = try write(&buf.writer, &data, .{ .color = false, .fail_under = 80.0 });
    try std.testing.expect(!passes); // 50% < 80%
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "below the threshold") != null);
}

test "summary no-color output contains no ANSI escape codes" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    const fc = coverage.FileCoverage{
        .path = "src/z.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 1, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    _ = try write(&buf.writer, &data, .{ .color = false });
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\x1b[") == null);
}
