//! JSON coverage report generator.
//!
//! Emits a stable, machine-readable document:
//!
//! ```json
//! {
//!   "version": 1,
//!   "tool": "zig-cov",
//!   "summary": { "lines_found": 4, "lines_hit": 3, "line_percent": 75.00, ... },
//!   "files": [
//!     {
//!       "path": "src/main.zig",
//!       "lines_found": 2, "lines_hit": 1, "line_percent": 50.00,
//!       "lines": [ {"line": 1, "hits": 3}, {"line": 2, "hits": 0} ],
//!       "functions": [ {"name": "foo", "line": 1, "hits": 3} ]
//!     }
//!   ]
//! }
//! ```
//!
//! Files are sorted by path and lines by number, so the output is deterministic
//! and diffable. A line with `"hits": 0` is a miss; lines with no generated code
//! are absent entirely.

const std = @import("std");
const coverage = @import("../coverage.zig");

/// Schema version. Bump on any incompatible change to the document shape.
pub const schema_version = 2;

/// Write the coverage data to `writer` as JSON.
pub fn write(gpa: std.mem.Allocator, writer: *std.Io.Writer, data: *const coverage.CoverageData) !void {
    // Deterministic order: sort files by path.
    var sorted: std.ArrayList(*const coverage.FileCoverage) = .empty;
    defer sorted.deinit(gpa);
    for (data.files) |*fc| try sorted.append(gpa, fc);
    std.mem.sort(*const coverage.FileCoverage, sorted.items, {}, struct {
        fn lt(_: void, a: *const coverage.FileCoverage, b: *const coverage.FileCoverage) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    try writer.print("{{\n  \"version\": {d},\n  \"tool\": \"zig-cov\",\n", .{schema_version});

    // Overall summary.
    try writer.writeAll("  \"summary\": {\n");
    try writer.print("    \"lines_found\": {d},\n", .{data.summary.lines_found});
    try writer.print("    \"lines_hit\": {d},\n", .{data.summary.lines_hit});
    try writer.print("    \"line_percent\": {d:.2},\n", .{data.summary.linePercent()});
    try writer.print("    \"functions_found\": {d},\n", .{data.summary.functions_found});
    try writer.print("    \"functions_hit\": {d},\n", .{data.summary.functions_hit});
    try writer.print("    \"function_percent\": {d:.2},\n", .{data.summary.functionPercent()});
    // Exact: what the counters recorded, with no line attribution in between.
    try writer.print("    \"blocks_found\": {d},\n", .{data.summary.blocks_found});
    try writer.print("    \"blocks_hit\": {d},\n", .{data.summary.blocks_hit});
    try writer.print("    \"block_percent\": {d:.2}\n", .{data.summary.blockPercent()});
    try writer.writeAll("  },\n");

    // Per-file entries.
    try writer.writeAll("  \"files\": [");
    for (sorted.items, 0..) |fc, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("\n    {\n      \"path\": ");
        try writeString(writer, fc.path);
        try writer.writeAll(",\n");

        const lh = countHitLines(fc.lines);
        const lf = fc.lines.len;
        try writer.print("      \"lines_found\": {d},\n", .{lf});
        try writer.print("      \"lines_hit\": {d},\n", .{lh});
        try writer.print("      \"line_percent\": {d:.2},\n", .{percent(lh, lf)});

        try writer.writeAll("      \"lines\": [");
        for (fc.lines, 0..) |lc, j| {
            if (j > 0) try writer.writeByte(',');
            try writer.print("\n        {{\"line\": {d}, \"hits\": {d}}}", .{ lc.line, lc.hit_count });
        }
        try writer.writeAll(if (fc.lines.len == 0) "]," else "\n      ],\n");

        try writer.writeAll("      \"functions\": [");
        for (fc.functions, 0..) |fn_cov, j| {
            if (j > 0) try writer.writeByte(',');
            try writer.writeAll("\n        {\"name\": ");
            try writeString(writer, fn_cov.name);
            try writer.print(", \"line\": {d}, \"hits\": {d}}}", .{ fn_cov.start_line, fn_cov.hit_count });
        }
        try writer.writeAll(if (fc.functions.len == 0) "]\n" else "\n      ]\n");

        try writer.writeAll("    }");
    }
    try writer.writeAll(if (sorted.items.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

/// Write a JSON string literal (including quotes) with spec-correct escaping.
fn writeString(writer: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, writer);
}

fn countHitLines(lines: []const coverage.LineCoverage) usize {
    var n: usize = 0;
    for (lines) |lc| if (lc.hit_count > 0) {
        n += 1;
    };
    return n;
}

fn percent(hit: usize, found: usize) f64 {
    if (found == 0) return 100.0;
    return @as(f64, @floatFromInt(hit)) / @as(f64, @floatFromInt(found)) * 100.0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Render `data` and assert the result parses as JSON; returns the parsed doc.
fn renderAndParse(
    alloc: std.mem.Allocator,
    buf: *std.Io.Writer.Allocating,
    data: *const coverage.CoverageData,
) !std.json.Parsed(std.json.Value) {
    try write(alloc, &buf.writer, data);
    return std.json.parseFromSlice(std.json.Value, alloc, buf.written(), .{});
}

test "json output is valid and reports summary and per-line hits" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 3 },
        .{ .line = 2, .hit_count = 0 }, // a miss
        .{ .line = 5, .hit_count = 1 },
    };
    const fc = coverage.FileCoverage{ .path = "src/foo.zig", .lines = @constCast(&lines), .functions = &.{} };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 3, .lines_hit = 2, .functions_found = 0, .functions_hit = 0 },
    };

    var parsed = try renderAndParse(alloc, &buf, &data);
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, schema_version), root.get("version").?.integer);
    try std.testing.expectEqualStrings("zig-cov", root.get("tool").?.string);

    const summary = root.get("summary").?.object;
    try std.testing.expectEqual(@as(i64, 3), summary.get("lines_found").?.integer);
    try std.testing.expectEqual(@as(i64, 2), summary.get("lines_hit").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 66.67), summary.get("line_percent").?.float, 0.01);

    const files = root.get("files").?.array;
    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    const f0 = files.items[0].object;
    try std.testing.expectEqualStrings("src/foo.zig", f0.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 3), f0.get("lines_found").?.integer);
    try std.testing.expectEqual(@as(i64, 2), f0.get("lines_hit").?.integer);

    const line_entries = f0.get("lines").?.array;
    try std.testing.expectEqual(@as(usize, 3), line_entries.items.len);
    try std.testing.expectEqual(@as(i64, 1), line_entries.items[0].object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 3), line_entries.items[0].object.get("hits").?.integer);
    // The miss is present with hits == 0, not omitted.
    try std.testing.expectEqual(@as(i64, 2), line_entries.items[1].object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 0), line_entries.items[1].object.get("hits").?.integer);
}

test "json escapes paths that contain JSON metacharacters" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    // Backslashes and a quote must survive a parse round-trip intact.
    const nasty = "C:\\src\\a\"b\\weird\tname.zig";
    const fc = coverage.FileCoverage{ .path = nasty, .lines = @constCast(&lines), .functions = &.{} };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 1, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    var parsed = try renderAndParse(alloc, &buf, &data);
    defer parsed.deinit();

    const path = parsed.value.object.get("files").?.array.items[0].object.get("path").?.string;
    try std.testing.expectEqualStrings(nasty, path);
}

test "json emits functions and sorts files by path" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines_b = [_]coverage.LineCoverage{.{ .line = 3, .hit_count = 2 }};
    const lines_a = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 0 }};
    const funcs = [_]coverage.FunctionCoverage{
        .{ .name = "myFunc", .start_line = 3, .hit_count = 2 },
    };
    // Deliberately out of order: "z.zig" before "a.zig".
    const files = [_]coverage.FileCoverage{
        .{ .path = "z.zig", .lines = @constCast(&lines_b), .functions = @constCast(&funcs) },
        .{ .path = "a.zig", .lines = @constCast(&lines_a), .functions = &.{} },
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&files),
        .summary = .{ .lines_found = 2, .lines_hit = 1, .functions_found = 1, .functions_hit = 1 },
    };

    var parsed = try renderAndParse(alloc, &buf, &data);
    defer parsed.deinit();

    const arr = parsed.value.object.get("files").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("a.zig", arr.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("z.zig", arr.items[1].object.get("path").?.string);

    // a.zig's only line is a miss -> 0%.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), arr.items[0].object.get("line_percent").?.float, 0.01);

    const fns = arr.items[1].object.get("functions").?.array;
    try std.testing.expectEqual(@as(usize, 1), fns.items.len);
    try std.testing.expectEqualStrings("myFunc", fns.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), fns.items[0].object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 2), fns.items[0].object.get("hits").?.integer);
}

test "json with no files is still valid" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = &.{},
        .summary = .{ .lines_found = 0, .lines_hit = 0, .functions_found = 0, .functions_hit = 0 },
    };

    var parsed = try renderAndParse(alloc, &buf, &data);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("files").?.array.items.len);
}

test "json handles a file with no lines" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const fc = coverage.FileCoverage{ .path = "empty.zig", .lines = &.{}, .functions = &.{} };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 0, .lines_hit = 0, .functions_found = 0, .functions_hit = 0 },
    };

    var parsed = try renderAndParse(alloc, &buf, &data);
    defer parsed.deinit();

    const f0 = parsed.value.object.get("files").?.array.items[0].object;
    try std.testing.expectEqual(@as(usize, 0), f0.get("lines").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), f0.get("functions").?.array.items.len);
}
