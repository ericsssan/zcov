//! Cobertura XML report generator.
//!
//! Produces the `coverage-04.dtd` document that Jenkins, GitLab CI, Codecov and
//! most other CI platforms consume:
//!
//! ```xml
//! <coverage line-rate="0.5" lines-covered="1" lines-valid="2" ...>
//!   <sources><source>/path/to/project</source></sources>
//!   <packages>
//!     <package name="src" line-rate="0.5" ...>
//!       <classes>
//!         <class name="main" filename="src/main.zig" line-rate="0.5" ...>
//!           <methods/>
//!           <lines><line number="1" hits="3"/></lines>
//!         </class>
//!       </classes>
//!     </package>
//!   </packages>
//! </coverage>
//! ```
//!
//! Files are grouped into `<package>` elements by directory, and their
//! `filename` is made relative to `source_root` (emitted as `<source>`) because
//! CI consumers resolve coverage against the repository root.
//!
//! zig-cov has no branch data, so branch counters are reported as zero rather
//! than fabricated.

const std = @import("std");
const coverage = @import("../coverage.zig");

pub const Options = struct {
    /// Unix epoch seconds for the report's `timestamp` attribute. Injected
    /// rather than read from the clock so output is reproducible in tests.
    timestamp: i64 = 0,
    /// Absolute path stripped from file paths to make `filename` attributes
    /// repo-relative; also emitted as `<source>`. null = paths are left as-is.
    source_root: ?[]const u8 = null,
};

/// One file, paired with the package (directory) it belongs to.
const Entry = struct {
    /// Directory of `rel`, or "." at the root. Written with '.' separators.
    pkg: []const u8,
    /// Path relative to `source_root` when possible, else the original path.
    rel: []const u8,
    fc: *const coverage.FileCoverage,
};

/// Write a Cobertura XML document to `writer`.
pub fn write(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    data: *const coverage.CoverageData,
    opts: Options,
) !void {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    for (data.files) |*fc| {
        const rel = relativize(fc.path, opts.source_root);
        try entries.append(gpa, .{ .pkg = packageOf(rel), .rel = rel, .fc = fc });
    }

    // Sort by (package, path) so each package's files are contiguous and the
    // whole document is deterministic.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return switch (std.mem.order(u8, a.pkg, b.pkg)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, a.rel, b.rel),
            };
        }
    }.lt);

    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE coverage SYSTEM "http://cobertura.sourceforge.net/xml/coverage-04.dtd">
        \\
    );
    try writer.print(
        "<coverage line-rate=\"{d:.4}\" branch-rate=\"0.0\" lines-covered=\"{d}\" lines-valid=\"{d}\"" ++
            " branches-covered=\"0\" branches-valid=\"0\" complexity=\"0\" version=\"1.9\" timestamp=\"{d}\">\n",
        .{ rate(data.summary.lines_hit, data.summary.lines_found), data.summary.lines_hit, data.summary.lines_found, opts.timestamp },
    );

    try writer.writeAll("  <sources>\n    <source>");
    try escape(writer, opts.source_root orelse ".");
    try writer.writeAll("</source>\n  </sources>\n  <packages>\n");

    var i: usize = 0;
    while (i < entries.items.len) {
        // The current package spans entries [i, end).
        const pkg = entries.items[i].pkg;
        var end = i;
        var pkg_hit: usize = 0;
        var pkg_found: usize = 0;
        while (end < entries.items.len and std.mem.eql(u8, entries.items[end].pkg, pkg)) : (end += 1) {
            pkg_hit += countHitLines(entries.items[end].fc.lines);
            pkg_found += entries.items[end].fc.lines.len;
        }

        try writer.writeAll("    <package name=\"");
        try escapeDots(writer, pkg);
        try writer.print("\" line-rate=\"{d:.4}\" branch-rate=\"0.0\" complexity=\"0\">\n      <classes>\n", .{rate(pkg_hit, pkg_found)});

        for (entries.items[i..end]) |e| try writeClass(writer, e);

        try writer.writeAll("      </classes>\n    </package>\n");
        i = end;
    }

    try writer.writeAll("  </packages>\n</coverage>\n");
}

fn writeClass(writer: *std.Io.Writer, e: Entry) !void {
    const hit = countHitLines(e.fc.lines);
    const found = e.fc.lines.len;

    try writer.writeAll("        <class name=\"");
    try escape(writer, classNameOf(e.rel));
    try writer.writeAll("\" filename=\"");
    try escape(writer, e.rel);
    try writer.print("\" line-rate=\"{d:.4}\" branch-rate=\"0.0\" complexity=\"0\">\n", .{rate(hit, found)});

    // Methods.
    if (e.fc.functions.len == 0) {
        try writer.writeAll("          <methods/>\n");
    } else {
        try writer.writeAll("          <methods>\n");
        for (e.fc.functions) |fn_cov| {
            try writer.writeAll("            <method name=\"");
            try escape(writer, fn_cov.name);
            try writer.print(
                "\" signature=\"\" line-rate=\"{d:.4}\" branch-rate=\"0.0\">\n" ++
                    "              <lines><line number=\"{d}\" hits=\"{d}\"/></lines>\n" ++
                    "            </method>\n",
                .{ rate(if (fn_cov.hit_count > 0) 1 else 0, 1), fn_cov.start_line, fn_cov.hit_count },
            );
        }
        try writer.writeAll("          </methods>\n");
    }

    // Lines.
    if (found == 0) {
        try writer.writeAll("          <lines/>\n");
    } else {
        try writer.writeAll("          <lines>\n");
        for (e.fc.lines) |lc| {
            try writer.print("            <line number=\"{d}\" hits=\"{d}\"/>\n", .{ lc.line, lc.hit_count });
        }
        try writer.writeAll("          </lines>\n");
    }

    try writer.writeAll("        </class>\n");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Strip `root` (and the following separator) from `path` when it is a prefix,
/// so CI consumers can resolve the file against the repository root.
fn relativize(path: []const u8, root: ?[]const u8) []const u8 {
    const r = root orelse return path;
    if (r.len == 0 or !std.mem.startsWith(u8, path, r)) return path;
    var rest = path[r.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return if (rest.len == 0) path else rest;
}

/// Directory portion of `rel`, or "." when the file sits at the root.
fn packageOf(rel: []const u8) []const u8 {
    return std.fs.path.dirnamePosix(rel) orelse ".";
}

/// Class name: the file's basename without its extension.
fn classNameOf(rel: []const u8) []const u8 {
    const base = std.fs.path.basenamePosix(rel);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

fn countHitLines(lines: []const coverage.LineCoverage) usize {
    var n: usize = 0;
    for (lines) |lc| if (lc.hit_count > 0) {
        n += 1;
    };
    return n;
}

/// Cobertura rates are fractions in [0,1]. An empty file counts as fully
/// covered, matching how the other zig-cov formats report 100% of nothing.
fn rate(hit: usize, found: usize) f64 {
    if (found == 0) return 1.0;
    return @as(f64, @floatFromInt(hit)) / @as(f64, @floatFromInt(found));
}

/// Escape text for use in an XML attribute or element body. Control characters
/// are not representable in XML 1.0, so they are replaced rather than emitted.
fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.writeByte('?'),
        else => try w.writeByte(ch),
    };
}

/// Like `escape`, but writes path separators as '.' (package naming convention).
fn escapeDots(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '/' => try w.writeByte('.'),
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.writeByte('?'),
        else => try w.writeByte(ch),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cobertura emits root counters and a DTD header" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 3 },
        .{ .line = 2, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{ .path = "src/main.zig", .lines = @constCast(&lines), .functions = &.{} };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 2, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{ .timestamp = 1700000000 });
    const out = buf.written();

    try std.testing.expect(std.mem.startsWith(u8, out, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "coverage-04.dtd") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lines-covered=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lines-valid=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line-rate=\"0.5000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "timestamp=\"1700000000\"") != null);
    // No branch data is available, so branch counters must read zero.
    try std.testing.expect(std.mem.indexOf(u8, out, "branches-valid=\"0\"") != null);
    // Per-line entries, including the miss.
    try std.testing.expect(std.mem.indexOf(u8, out, "<line number=\"1\" hits=\"3\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<line number=\"2\" hits=\"0\"/>") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</coverage>\n"));
}

test "cobertura relativizes filenames against source_root and emits it as source" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    const fc = coverage.FileCoverage{
        .path = "/home/u/proj/src/util.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 1, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{ .source_root = "/home/u/proj" });
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<source>/home/u/proj</source>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "filename=\"src/util.zig\"") != null);
    // The absolute path must not leak into the filename attribute.
    try std.testing.expect(std.mem.indexOf(u8, out, "filename=\"/home/u/proj") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"src\"") != null); // package
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"util\"") != null); // class
}

test "cobertura groups files into packages by directory" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const l = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    // Deliberately unsorted, and interleaving directories so that naive
    // consecutive grouping would emit "a" twice.
    const files = [_]coverage.FileCoverage{
        .{ .path = "a/z.zig", .lines = @constCast(&l), .functions = &.{} },
        .{ .path = "a/b/m.zig", .lines = @constCast(&l), .functions = &.{} },
        .{ .path = "a/c.zig", .lines = @constCast(&l), .functions = &.{} },
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&files),
        .summary = .{ .lines_found = 3, .lines_hit = 3, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    // Exactly two packages: "a" (z.zig, c.zig) and "a.b" (m.zig).
    var count: usize = 0;
    var rest = out;
    while (std.mem.indexOf(u8, rest, "<package ")) |pos| {
        count += 1;
        rest = rest[pos + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"a.b\"") != null);
}

test "cobertura escapes XML metacharacters in paths" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 1, .hit_count = 1 }};
    const fc = coverage.FileCoverage{
        .path = "src/a&b<c>\"d\".zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 1, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&quot;") != null);
    // Raw metacharacters must not survive inside the attribute value.
    try std.testing.expect(std.mem.indexOf(u8, out, "a&b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b<c") == null);
}

test "cobertura emits methods when function data is present" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{.{ .line = 3, .hit_count = 2 }};
    const funcs = [_]coverage.FunctionCoverage{.{ .name = "myFunc", .start_line = 3, .hit_count = 2 }};
    const fc = coverage.FileCoverage{
        .path = "f.zig",
        .lines = @constCast(&lines),
        .functions = @constCast(&funcs),
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 1, .lines_hit = 1, .functions_found = 1, .functions_hit = 1 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<method name=\"myFunc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<methods/>") == null);
    // Root-level files land in the "." package.
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\".\"") != null);
}

test "cobertura with no files is still a complete document" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = &.{},
        .summary = .{ .lines_found = 0, .lines_hit = 0, .functions_found = 0, .functions_hit = 0 },
    };

    try write(alloc, &buf.writer, &data, .{});
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<packages>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</packages>") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</coverage>\n"));
}
