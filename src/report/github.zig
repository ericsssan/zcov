//! GitHub Actions annotations.
//!
//! Emits workflow commands on stdout, which the Actions runner turns into
//! inline annotations on the pull request diff:
//!
//! ```
//! ::warning file=src/parser.zig,line=42,endLine=57::16 lines not covered
//! ::notice::Coverage 36.8% (301/819 lines)
//! ```
//!
//! Two things make this usable on a real project:
//!
//!   * Runs of uncovered lines are merged into a single ranged annotation
//!     instead of one per line. A run is broken by a *covered* line, so lines
//!     that simply have no generated code (comments, blanks) do not split it.
//!   * The number of annotations is capped (`max_annotations`). GitHub only
//!     surfaces a limited number per step, and a file with a thousand misses
//!     would otherwise bury everything else. Whatever is dropped is reported in
//!     the summary rather than silently discarded.
//!
//! Paths are made relative to `source_root`: GitHub resolves annotations
//! against the repository root, and an absolute path silently fails to attach.

const std = @import("std");
const coverage = @import("../coverage.zig");
const paths = @import("paths.zig");

pub const Options = struct {
    /// Absolute path stripped from file paths so annotations attach to files in
    /// the repository. null = paths are left as-is.
    source_root: ?[]const u8 = null,
    /// Maximum number of warning annotations to emit. 0 = unlimited.
    max_annotations: usize = 10,
    /// Minimum line coverage; below it an `::error::` is emitted and `write`
    /// returns false. 0 = no threshold.
    fail_under: f64 = 0,
};

/// Write annotations to `writer`. Returns false when `fail_under` is set and
/// total line coverage is below it.
pub fn write(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    data: *const coverage.CoverageData,
    opts: Options,
) !bool {
    // Deterministic order: sort files by path.
    var sorted: std.ArrayList(*const coverage.FileCoverage) = .empty;
    defer sorted.deinit(gpa);
    for (data.files) |*fc| try sorted.append(gpa, fc);
    std.mem.sort(*const coverage.FileCoverage, sorted.items, {}, struct {
        fn lt(_: void, a: *const coverage.FileCoverage, b: *const coverage.FileCoverage) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    var emitted: usize = 0;
    var suppressed: usize = 0;

    for (sorted.items) |fc| {
        const rel = paths.relativize(fc.path, opts.source_root);
        var i: usize = 0;
        while (i < fc.lines.len) {
            if (fc.lines[i].hit_count > 0) {
                i += 1;
                continue;
            }
            // Start of a run of uncovered lines; extend while they stay uncovered.
            const start = fc.lines[i].line;
            var end = start;
            var missed: usize = 0;
            while (i < fc.lines.len and fc.lines[i].hit_count == 0) : (i += 1) {
                end = fc.lines[i].line;
                missed += 1;
            }

            if (opts.max_annotations != 0 and emitted >= opts.max_annotations) {
                suppressed += 1;
                continue;
            }

            try writer.writeAll("::warning file=");
            try escapeProperty(writer, rel);
            try writer.print(",line={d},endLine={d}::", .{ start, end });
            if (missed == 1) {
                try writer.writeAll("line not covered");
            } else {
                try writer.print("{d} lines not covered", .{missed});
            }
            try writer.writeByte('\n');
            emitted += 1;
        }
    }

    // Summary. Never silently truncate: say what was dropped.
    const pct = data.summary.linePercent();
    try writer.print(
        "::notice::Coverage {d:.1}% ({d}/{d} lines)",
        .{ pct, data.summary.lines_hit, data.summary.lines_found },
    );
    if (suppressed > 0) {
        try writer.print(
            "; {d} more uncovered region{s} not annotated (limit {d})",
            .{ suppressed, if (suppressed == 1) "" else "s", opts.max_annotations },
        );
    }
    try writer.writeByte('\n');

    const passes = opts.fail_under == 0 or pct >= opts.fail_under;
    if (!passes) {
        try writer.print(
            "::error::Coverage {d:.1}% is below the threshold of {d:.1}%\n",
            .{ pct, opts.fail_under },
        );
    }
    return passes;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Escape a workflow command property value. Mirrors `escapeProperty` in
/// actions/toolkit: on top of the message escapes, ':' and ',' must be encoded
/// because they delimit the property list.
fn escapeProperty(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '%' => try w.writeAll("%25"),
        '\r' => try w.writeAll("%0D"),
        '\n' => try w.writeAll("%0A"),
        ':' => try w.writeAll("%3A"),
        ',' => try w.writeAll("%2C"),
        else => try w.writeByte(ch),
    };
}

/// Escape workflow command message data. Mirrors `escapeData` in
/// actions/toolkit.
fn escapeData(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '%' => try w.writeAll("%25"),
        '\r' => try w.writeAll("%0D"),
        '\n' => try w.writeAll("%0A"),
        else => try w.writeByte(ch),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testData(alloc: std.mem.Allocator, files: []coverage.FileCoverage, found: u32, hit: u32) coverage.CoverageData {
    return .{
        .allocator = alloc,
        .files = files,
        .summary = .{ .lines_found = found, .lines_hit = hit, .functions_found = 0, .functions_hit = 0 },
    };
}

test "github merges runs of uncovered lines and splits on a covered line" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    // Lines 2,3,4 uncovered (contiguous), 5 covered, 9 uncovered alone.
    // Note 4 -> 9 skips 5..8: the run is broken by the *covered* line 5.
    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 0 },
        .{ .line = 3, .hit_count = 0 },
        .{ .line = 4, .hit_count = 0 },
        .{ .line = 5, .hit_count = 2 },
        .{ .line = 9, .hit_count = 0 },
    };
    var files = [_]coverage.FileCoverage{
        .{ .path = "src/p.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 6, 2);

    const passes = try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(passes);
    try std.testing.expect(std.mem.indexOf(u8, out, "::warning file=src/p.zig,line=2,endLine=4::3 lines not covered") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "::warning file=src/p.zig,line=9,endLine=9::line not covered") != null);
    // Exactly two warnings, not one per line.
    var count: usize = 0;
    var rest = out;
    while (std.mem.indexOf(u8, rest, "::warning ")) |pos| {
        count += 1;
        rest = rest[pos + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "github does not split a run across non-coverable lines" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    // Lines 10 and 14 are coverable and uncovered; 11..13 have no code at all
    // (absent from the model), so they must not break the run.
    const lines = [_]coverage.LineCoverage{
        .{ .line = 10, .hit_count = 0 },
        .{ .line = 14, .hit_count = 0 },
    };
    var files = [_]coverage.FileCoverage{
        .{ .path = "a.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 2, 0);

    _ = try write(alloc, &buf.writer, &data, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "line=10,endLine=14::2 lines not covered") != null);
}

test "github escapes commas and colons in file paths" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 0 }};
    var files = [_]coverage.FileCoverage{
        .{ .path = "we:ird,name%.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 1, 0);

    _ = try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    // Raw ':' or ',' in the path would corrupt the property list.
    try std.testing.expect(std.mem.indexOf(u8, out, "file=we%3Aird%2Cname%25.zig,line=1") != null);
}

test "github caps annotations and reports what was suppressed" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    // Five separate uncovered regions (alternating miss/hit).
    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 0 }, .{ .line = 2, .hit_count = 1 },
        .{ .line = 3, .hit_count = 0 }, .{ .line = 4, .hit_count = 1 },
        .{ .line = 5, .hit_count = 0 }, .{ .line = 6, .hit_count = 1 },
        .{ .line = 7, .hit_count = 0 }, .{ .line = 8, .hit_count = 1 },
        .{ .line = 9, .hit_count = 0 },
    };
    var files = [_]coverage.FileCoverage{
        .{ .path = "m.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 9, 4);

    _ = try write(alloc, &buf.writer, &data, .{ .max_annotations = 2 });
    const out = buf.written();

    var count: usize = 0;
    var rest = out;
    while (std.mem.indexOf(u8, rest, "::warning ")) |pos| {
        count += 1;
        rest = rest[pos + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    // The cap must be visible, not silent.
    try std.testing.expect(std.mem.indexOf(u8, out, "3 more uncovered regions not annotated") != null);
}

test "github emits no warnings for fully covered code" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 2 },
        .{ .line = 2, .hit_count = 1 },
    };
    var files = [_]coverage.FileCoverage{
        .{ .path = "c.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 2, 2);

    const passes = try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(passes);
    try std.testing.expect(std.mem.indexOf(u8, out, "::warning") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "::notice::Coverage 100.0% (2/2 lines)") != null);
}

test "github reports a threshold failure as an error annotation" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 0 },
    };
    var files = [_]coverage.FileCoverage{
        .{ .path = "t.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 2, 1);

    const passes = try write(alloc, &buf.writer, &data, .{ .fail_under = 80 });
    const out = buf.written();

    try std.testing.expect(!passes);
    try std.testing.expect(std.mem.indexOf(u8, out, "::error::Coverage 50.0% is below the threshold of 80.0%") != null);
}

test "github relativizes paths against the source root" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 7, .hit_count = 0 }};
    var files = [_]coverage.FileCoverage{
        .{ .path = "/home/u/proj/src/x.zig", .lines = @constCast(&lines), .functions = &.{} },
    };
    const data = testData(alloc, &files, 1, 0);

    _ = try write(alloc, &buf.writer, &data, .{ .source_root = "/home/u/proj" });
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "file=src/x.zig,") != null);
    // An absolute path would not attach to a file in the repository.
    try std.testing.expect(std.mem.indexOf(u8, out, "file=%2Fhome") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/home/u/proj/src") == null);
}

test "escapeData encodes only percent and newlines" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try escapeData(&buf.writer, "a%b\nc\rd:e,f");
    // ':' and ',' are legal in message data and must be left alone.
    try std.testing.expectEqualStrings("a%25b%0Ac%0Dd:e,f", buf.written());
}
