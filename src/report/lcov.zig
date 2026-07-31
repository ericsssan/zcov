//! LCOV tracefile report generator.
//!
//! Produces the standard LCOV format accepted by Codecov, Coveralls,
//! lcov/genhtml, and most CI platforms.
//!
//! Format reference: https://ltp.sourceforge.net/coverage/lcov/geninfo.1.php

const std = @import("std");
const coverage = @import("../coverage.zig");
const paths = @import("paths.zig");

pub const Options = struct {
    /// Absolute path stripped from `SF:` records so they are repo-relative.
    /// Codecov, Coveralls and lcov's own tooling match coverage to source by
    /// relative path; an absolute build path matches nothing. null = as-is.
    source_root: ?[]const u8 = null,
};

/// Write an LCOV tracefile to `writer` from `data`.
pub fn write(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    data: *const coverage.CoverageData,
    opts: Options,
) !void {
    // Deterministic order: sort files by path.
    var sorted: std.ArrayList(*const coverage.FileCoverage) = .empty;
    defer sorted.deinit(gpa);
    for (data.files) |*fc| try sorted.append(gpa, fc);
    std.mem.sort(*const coverage.FileCoverage, sorted.items, {}, struct {
        fn lt(_: void, a: *const coverage.FileCoverage, b: *const coverage.FileCoverage) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    for (sorted.items) |fc| {
        try writer.writeAll("TN:\n"); // test name (empty = default)
        try writer.print("SF:{s}\n", .{paths.relativize(fc.path, opts.source_root)});

        // Function coverage (DA lines, then FN/FNDA)
        for (fc.functions) |fn_cov| {
            try writer.print("FN:{d},{s}\n", .{ fn_cov.start_line, fn_cov.name });
        }
        for (fc.functions) |fn_cov| {
            try writer.print("FNDA:{d},{s}\n", .{ fn_cov.hit_count, fn_cov.name });
        }
        try writer.print("FNF:{d}\n", .{fc.functions.len});
        const fns_hit = countHitFunctions(fc.functions);
        try writer.print("FNH:{d}\n", .{fns_hit});

        // Line coverage
        for (fc.lines) |lc| {
            try writer.print("DA:{d},{d}\n", .{ lc.line, lc.hit_count });
        }
        const lf = fc.lines.len;
        var lh: usize = 0;
        for (fc.lines) |lc| if (lc.hit_count > 0) {
            lh += 1;
        };
        try writer.print("LF:{d}\n", .{lf});
        try writer.print("LH:{d}\n", .{lh});

        try writer.writeAll("end_of_record\n");
    }
}

fn countHitFunctions(functions: []const coverage.FunctionCoverage) usize {
    var count: usize = 0;
    for (functions) |f| if (f.hit_count > 0) {
        count += 1;
    };
    return count;
}

test "lcov basic output" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 3 },
        .{ .line = 2, .hit_count = 0 },
        .{ .line = 5, .hit_count = 1 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/foo.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{
            .lines_found = 3,
            .lines_hit = 2,
            .functions_found = 0,
            .functions_hit = 0,
        },
    };

    try write(alloc, &buf.writer, &data, .{});

    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "SF:src/foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DA:1,3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DA:2,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LF:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LH:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "end_of_record") != null);
}

test "lcov function coverage output" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const functions = [_]coverage.FunctionCoverage{
        .{ .name = "myFunc", .start_line = 3, .hit_count = 2 },
        .{ .name = "unusedFunc", .start_line = 10, .hit_count = 0 },
    };
    const lines = [_]coverage.LineCoverage{
        .{ .line = 3, .hit_count = 2 },
        .{ .line = 10, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/funcs.zig",
        .lines = @constCast(&lines),
        .functions = @constCast(&functions),
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 2, .lines_hit = 1, .functions_found = 2, .functions_hit = 1 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "FN:3,myFunc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FN:10,unusedFunc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FNDA:2,myFunc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FNDA:0,unusedFunc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FNF:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FNH:1") != null);
}

test "lcov multiple files each get their own end_of_record" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines1 = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    const lines2 = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 0 }};
    const files = [_]coverage.FileCoverage{
        .{ .path = "src/a.zig", .lines = @constCast(&lines1), .functions = &.{} },
        .{ .path = "src/b.zig", .lines = @constCast(&lines2), .functions = &.{} },
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&files),
        .summary = .{ .lines_found = 2, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "SF:src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SF:src/b.zig") != null);

    // Count end_of_record — must be exactly one per file.
    var count: usize = 0;
    var rest = out;
    while (std.mem.indexOf(u8, rest, "end_of_record")) |pos| {
        count += 1;
        rest = rest[pos + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "lcov makes SF paths relative to the source root" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    // DWARF yields absolute paths for some files and relative for others; the
    // tracefile must be uniformly repo-relative or Codecov cannot match them.
    const files = [_]coverage.FileCoverage{
        .{ .path = "/home/u/proj/root.zig", .lines = @constCast(&lines), .functions = &.{} },
        .{ .path = "sub/rel.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&files),
        .summary = .{ .lines_found = 2, .lines_hit = 2, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{ .source_root = "/home/u/proj" });
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "SF:root.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SF:sub/rel.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SF:/home/u/proj") == null);
}

test "lcov emits files in a deterministic order" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    const files = [_]coverage.FileCoverage{
        .{ .path = "z.zig", .lines = @constCast(&lines), .functions = &.{} },
        .{ .path = "a.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&files),
        .summary = .{ .lines_found = 2, .lines_hit = 2, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    const a = std.mem.indexOf(u8, out, "SF:a.zig").?;
    const z = std.mem.indexOf(u8, out, "SF:z.zig").?;
    try std.testing.expect(a < z);
}
