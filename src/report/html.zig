//! HTML coverage report generator.
//!
//! Produces a single self-contained HTML file (CSS inlined, no external assets):
//!   - an overall coverage figure,
//!   - a per-file table with coverage bars, linking to
//!   - one section per file rendering the source with line-level hit/miss
//!     coloring and Zig syntax highlighting.
//!
//! Non-coverable lines (comments, blanks, declarations that produce no code —
//! i.e. lines absent from DWARF) are shown uncolored, matching genhtml/lcov.

const std = @import("std");
const coverage = @import("../coverage.zig");

/// Cap on how much of a source file we read for rendering.
const max_source_bytes = 8 * 1024 * 1024;

/// Write a complete HTML report to `writer`. Reads each file's source from disk
/// (via `io`) to render the annotated source view; files that cannot be read
/// still appear, with a "source not available" note and their line data.
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    data: *const coverage.CoverageData,
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

    try writeHead(writer);
    try writeOverview(writer, data, sorted.items);

    for (sorted.items, 0..) |fc, idx| {
        const source: ?[]u8 = readSource(gpa, io, fc.path);
        defer if (source) |s| gpa.free(s);
        try renderFile(gpa, writer, fc, idx, source);
    }

    try writeFoot(writer);
}

fn readSource(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(max_source_bytes)) catch null;
}

// ---------------------------------------------------------------------------
// Per-file line statistics
// ---------------------------------------------------------------------------

const Stats = struct { hit: usize, found: usize, pct: f64 };

fn lineStats(fc: *const coverage.FileCoverage) Stats {
    var hit: usize = 0;
    for (fc.lines) |lc| if (lc.hit_count > 0) {
        hit += 1;
    };
    const found = fc.lines.len;
    const pct: f64 = if (found == 0) 100.0 else @as(f64, @floatFromInt(hit)) / @as(f64, @floatFromInt(found)) * 100.0;
    return .{ .hit = hit, .found = found, .pct = pct };
}

/// CSS class bucketing a percentage into high/mid/low (matches summary colors).
fn pctClass(pct: f64) []const u8 {
    if (pct >= 80.0) return "high";
    if (pct >= 60.0) return "mid";
    return "low";
}

// ---------------------------------------------------------------------------
// Overview: header + file table
// ---------------------------------------------------------------------------

fn writeOverview(
    writer: *std.Io.Writer,
    data: *const coverage.CoverageData,
    sorted: []const *const coverage.FileCoverage,
) !void {
    const total_pct = data.summary.linePercent();
    try writer.writeAll("<header>\n<h1>Coverage Report</h1>\n");
    try writer.print(
        "<div class=\"overall {s}\">{d:.1}% <span>({d}/{d} lines)</span></div>\n</header>\n",
        .{ pctClass(total_pct), total_pct, data.summary.lines_hit, data.summary.lines_found },
    );

    try writer.writeAll("<table class=\"files\">\n<thead><tr><th>File</th><th>Coverage</th><th class=\"num\">Lines</th></tr></thead>\n<tbody>\n");
    for (sorted, 0..) |fc, idx| {
        const st = lineStats(fc);
        const cls = pctClass(st.pct);
        try writer.print("<tr><td class=\"path\"><a href=\"#f{d}\">", .{idx});
        try escape(writer, fc.path);
        try writer.print(
            "</a></td><td class=\"bar {s}\"><div class=\"track\"><div class=\"fill\" style=\"width:{d:.1}%\"></div></div><span>{d:.1}%</span></td><td class=\"num\">{d}/{d}</td></tr>\n",
            .{ cls, st.pct, st.pct, st.hit, st.found },
        );
    }
    try writer.writeAll("</tbody>\n</table>\n");
}

// ---------------------------------------------------------------------------
// Per-file source section
// ---------------------------------------------------------------------------

fn renderFile(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    fc: *const coverage.FileCoverage,
    idx: usize,
    source: ?[]const u8,
) !void {
    const st = lineStats(fc);
    try writer.print("<section class=\"file\" id=\"f{d}\">\n<h2>", .{idx});
    try escape(writer, fc.path);
    try writer.print(
        "</h2>\n<div class=\"filepct {s}\">{d:.1}% <span>({d}/{d} lines)</span></div>\n",
        .{ pctClass(st.pct), st.pct, st.hit, st.found },
    );

    if (source) |src| {
        // Map of coverable line -> hit count. Presence = coverable.
        var hits = std.AutoHashMap(u32, u32).init(gpa);
        defer hits.deinit();
        for (fc.lines) |lc| try hits.put(lc.line, lc.hit_count);

        const highlighted = try highlightSource(gpa, src);
        defer gpa.free(highlighted);

        // Split the highlighted HTML into lines. Highlight spans never cross a
        // newline (Zig tokens and comments are single-line), so each segment is
        // balanced HTML. Drop a trailing empty segment from a final newline.
        var segs: std.ArrayList([]const u8) = .empty;
        defer segs.deinit(gpa);
        var it = std.mem.splitScalar(u8, highlighted, '\n');
        while (it.next()) |seg| try segs.append(gpa, seg);
        if (segs.items.len > 1 and segs.items[segs.items.len - 1].len == 0) _ = segs.pop();

        try writer.writeAll("<table class=\"source\">\n");
        var line_no: u32 = 1;
        for (segs.items) |seg| {
            var hcbuf: [16]u8 = undefined;
            var row_cls: []const u8 = "non";
            var hc_cell: []const u8 = "";
            if (hits.get(line_no)) |hc| {
                row_cls = if (hc > 0) "hit" else "miss";
                hc_cell = std.fmt.bufPrint(&hcbuf, "{d}", .{hc}) catch "";
            }
            try writer.print(
                "<tr class=\"{s}\"><td class=\"ln\">{d}</td><td class=\"hc\">{s}</td><td class=\"src\">{s}</td></tr>\n",
                .{ row_cls, line_no, hc_cell, seg },
            );
            line_no += 1;
        }
        try writer.writeAll("</table>\n");
    } else {
        try writer.writeAll("<p class=\"unavail\">Source file not available. Line coverage:</p>\n<table class=\"source\">\n");
        for (fc.lines) |lc| {
            const row_cls: []const u8 = if (lc.hit_count > 0) "hit" else "miss";
            try writer.print(
                "<tr class=\"{s}\"><td class=\"ln\">{d}</td><td class=\"hc\">{d}</td><td class=\"src\"></td></tr>\n",
                .{ row_cls, lc.line, lc.hit_count },
            );
        }
        try writer.writeAll("</table>\n");
    }
    try writer.writeAll("</section>\n");
}

// ---------------------------------------------------------------------------
// Syntax highlighting
// ---------------------------------------------------------------------------

/// Render `src` to HTML with Zig syntax highlighting and HTML escaping.
/// Newlines are preserved and no `<span>` crosses one, so the result can be
/// split by '\n' into balanced per-line fragments. Caller owns the result.
fn highlightSource(gpa: std.mem.Allocator, src: []const u8) ![]const u8 {
    const srcz = try gpa.allocSentinel(u8, src.len, 0);
    defer gpa.free(srcz);
    @memcpy(srcz, src);

    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var tok = std.zig.Tokenizer.init(srcz);
    var cursor: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        // Whitespace / regular comments live in the gap before the token.
        try emitGap(w, srcz[cursor..t.loc.start]);
        const text = srcz[t.loc.start..t.loc.end];
        if (classForTag(t.tag)) |cls| {
            try w.print("<span class=\"{s}\">", .{cls});
            try escape(w, text);
            try w.writeAll("</span>");
        } else {
            try escape(w, text);
        }
        cursor = t.loc.end;
    }
    try emitGap(w, srcz[cursor..]);

    return gpa.dupe(u8, out.written());
}

/// Emit inter-token text (whitespace + regular `//` comments). Inside a gap a
/// `//` can only begin a comment (strings/doc-comments are their own tokens),
/// so each `//` runs to end of line as a comment.
fn emitGap(w: *std.Io.Writer, text: []const u8) !void {
    var rest = text;
    while (rest.len > 0) {
        if (std.mem.indexOf(u8, rest, "//")) |idx| {
            try escape(w, rest[0..idx]);
            const after = rest[idx..];
            const nl = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
            try w.writeAll("<span class=\"c\">");
            try escape(w, after[0..nl]);
            try w.writeAll("</span>");
            rest = after[nl..];
        } else {
            try escape(w, rest);
            break;
        }
    }
}

fn classForTag(tag: std.zig.Token.Tag) ?[]const u8 {
    if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) return "k";
    return switch (tag) {
        .string_literal, .char_literal, .multiline_string_literal_line => "s",
        .number_literal => "n",
        .builtin => "b",
        .doc_comment, .container_doc_comment => "c",
        else => null,
    };
}

fn escape(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

// ---------------------------------------------------------------------------
// Static shell (head + styles, footer)
// ---------------------------------------------------------------------------

fn writeHead(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>zig-cov coverage</title>
        \\<style>
        \\:root{color-scheme:light dark}
        \\*{box-sizing:border-box}
        \\body{margin:0;font-family:-apple-system,system-ui,Segoe UI,sans-serif;background:#fff;color:#1a1a1a;line-height:1.5}
        \\header{padding:1.5rem 2rem;border-bottom:1px solid #d8dee4}
        \\h1{margin:0 0 .3rem;font-size:1.35rem}
        \\.overall{font-size:2rem;font-weight:700}
        \\.overall span{font-size:1rem;font-weight:400;opacity:.65}
        \\.high{color:#1a7f37}.mid{color:#9a6700}.low{color:#cf222e}
        \\table.files{border-collapse:collapse;width:100%;font-size:14px}
        \\table.files th,table.files td{text-align:left;padding:.4rem 2rem;border-bottom:1px solid #eaecef}
        \\table.files th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;opacity:.6}
        \\table.files td.num,table.files th.num{text-align:right;font-variant-numeric:tabular-nums;opacity:.8}
        \\td.path a{color:inherit;text-decoration:none}td.path a:hover{text-decoration:underline}
        \\td.bar{display:flex;align-items:center;gap:.6rem}
        \\td.bar .track{flex:1;max-width:180px;height:8px;border-radius:4px;background:#e6e8eb;overflow:hidden}
        \\td.bar .fill{height:100%}
        \\td.bar.high .fill{background:#2da44e}td.bar.mid .fill{background:#d4a72c}td.bar.low .fill{background:#e5534b}
        \\td.bar span{font-variant-numeric:tabular-nums;min-width:3.4rem}
        \\section.file{margin:2rem;border:1px solid #d8dee4;border-radius:8px;overflow:hidden}
        \\section.file h2{margin:0;padding:.7rem 1rem;font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:#f6f8fa;border-bottom:1px solid #d8dee4;word-break:break-all}
        \\.filepct{padding:.4rem 1rem;font-size:13px;font-weight:600;border-bottom:1px solid #eaecef}
        \\.filepct span{font-weight:400;opacity:.65}
        \\.unavail{padding:.6rem 1rem;opacity:.7;font-style:italic}
        \\table.source{border-collapse:collapse;width:100%;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;overflow-x:auto}
        \\table.source td{padding:0 .5rem;vertical-align:top}
        \\td.ln,td.hc{text-align:right;color:#8c959f;user-select:none;width:1%;white-space:nowrap}
        \\td.src{white-space:pre;width:100%}
        \\tr.hit{background:rgba(45,164,78,.12)}tr.miss{background:rgba(229,83,75,.14)}
        \\tr.hit td.hc{color:#1a7f37}tr.miss td.hc{color:#cf222e;font-weight:600}
        \\.k{color:#cf222e}.s{color:#0a3069}.n{color:#0550ae}.b{color:#8250df}.c{color:#6e7781;font-style:italic}
        \\footer{padding:1.5rem 2rem;font-size:12px;opacity:.55}
        \\@media (prefers-color-scheme:dark){
        \\body{background:#0d1117;color:#c9d1d9}
        \\header,section.file{border-color:#30363d}
        \\table.files th,table.files td,.filepct,.overall span{border-color:#21262d}
        \\.high{color:#3fb950}.mid{color:#d29922}.low{color:#f85149}
        \\section.file h2{background:#161b22;border-color:#30363d}
        \\td.bar .track{background:#21262d}
        \\.k{color:#ff7b72}.s{color:#a5d6ff}.n{color:#79c0ff}.b{color:#d2a8ff}.c{color:#8b949e}
        \\}
        \\</style>
        \\</head>
        \\<body>
        \\
    );
}

fn writeFoot(writer: *std.Io.Writer) !void {
    try writer.writeAll("<footer>Generated by <a href=\"https://github.com/ericsssan/zcov\">zig-cov</a></footer>\n</body>\n</html>\n");
}

// ---------------------------------------------------------------------------
// Tests (in-memory; no I/O so they run in the report_tests binary)
// ---------------------------------------------------------------------------

test "highlightSource highlights keywords, numbers, and comments" {
    const alloc = std.testing.allocator;
    const hl = try highlightSource(alloc, "const x = 5; // note\n");
    defer alloc.free(hl);
    try std.testing.expect(std.mem.indexOf(u8, hl, "<span class=\"k\">const</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hl, "<span class=\"n\">5</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hl, "<span class=\"c\">// note</span>") != null);
}

test "highlightSource escapes HTML metacharacters" {
    const alloc = std.testing.allocator;
    const hl = try highlightSource(alloc, "if (b < c and d > e) {}");
    defer alloc.free(hl);
    try std.testing.expect(std.mem.indexOf(u8, hl, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, hl, "&gt;") != null);
    // The raw '<' must not survive as a bare character between tokens.
    try std.testing.expect(std.mem.indexOf(u8, hl, " < ") == null);
}

test "highlightSource highlights strings and builtins" {
    const alloc = std.testing.allocator;
    const hl = try highlightSource(alloc, "const s = @import(\"std\");");
    defer alloc.free(hl);
    try std.testing.expect(std.mem.indexOf(u8, hl, "<span class=\"b\">@import</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hl, "<span class=\"s\">&quot;std&quot;</span>") != null);
}

test "highlightSource preserves line count for splitting" {
    const alloc = std.testing.allocator;
    const src = "const a = 1;\nconst b = 2;\nconst c = 3;";
    const hl = try highlightSource(alloc, src);
    defer alloc.free(hl);
    var n: usize = 1;
    for (hl) |ch| if (ch == '\n') {
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "renderFile marks hit, miss, and non-coverable rows" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    // Line 1 hit, line 3 miss; line 2 is not in the map (non-coverable).
    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 4 },
        .{ .line = 3, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{ .path = "x.zig", .lines = @constCast(&lines), .functions = &.{} };
    const src = "const a = 1;\n// a comment\nconst c = 3;\n";

    try renderFile(alloc, &buf.writer, &fc, 0, src);
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"f0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tr class=\"hit\"><td class=\"ln\">1</td><td class=\"hc\">4</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tr class=\"non\"><td class=\"ln\">2</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tr class=\"miss\"><td class=\"ln\">3</td><td class=\"hc\">0</td>") != null);
}

test "renderFile falls back cleanly when source is null" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 7, .hit_count = 2 },
        .{ .line = 9, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{ .path = "gone.zig", .lines = @constCast(&lines), .functions = &.{} };

    try renderFile(alloc, &buf.writer, &fc, 1, null);
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "not available") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gone.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tr class=\"hit\"><td class=\"ln\">7</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tr class=\"miss\"><td class=\"ln\">9</td>") != null);
}

test "writeHead emits a self-contained document shell" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try writeHead(&buf.writer);
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<style>") != null);
    // No external assets.
    try std.testing.expect(std.mem.indexOf(u8, out, "http://") == null);
}

test "writeOverview lists files with coverage" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 1 },
        .{ .line = 2, .hit_count = 0 },
    };
    const fc = coverage.FileCoverage{ .path = "src/demo.zig", .lines = @constCast(&lines), .functions = &.{} };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{ .lines_found = 2, .lines_hit = 1, .functions_found = 0, .functions_hit = 0 },
    };
    try writeOverview(&buf.writer, &data, &.{&data.files[0]});
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "src/demo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "href=\"#f0\"") != null);
}
