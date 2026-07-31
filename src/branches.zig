//! Finds the source line spans of bodies that only run conditionally.
//!
//! The compiler places coverage points where *fuzzing* benefits, not at every
//! branch, so a loop or `if` body often has no point of its own and inherits the
//! status of the code before it. That makes a never-taken body look covered —
//! the one error a coverage tool must not make, since it hides untested code.
//!
//! Knowing where those bodies are lets the reporter decline to claim them unless
//! something inside actually recorded a hit. Reading the source is enough: this
//! walks the token stream and records the `{ ... }` that follow `if`, `while`,
//! `for`, `switch`, `else`, `catch`, `orelse`, `errdefer` and switch prongs.
//! A plain block, a function body, a struct literal or a `defer` is not
//! conditional and is deliberately not reported.

const std = @import("std");

/// Inclusive line range, 1-based, of a conditionally-executed body.
pub const Span = struct {
    start_line: u32,
    end_line: u32,

    /// Whether `line` is part of the conditional body itself.
    ///
    /// The opening line is excluded: `if (x) {` carries the condition, which
    /// runs whenever control reaches the statement, so it must not be judged by
    /// whether the body ran.
    pub fn contains(s: Span, line: u32) bool {
        return line > s.start_line and line <= s.end_line;
    }

    pub fn lineCount(s: Span) u32 {
        return s.end_line - s.start_line + 1;
    }
};

/// Line spans of every conditionally-executed body in `source`.
/// Caller owns the result. Never fails on malformed input — the tokenizer is
/// error tolerant, and an unbalanced brace simply yields no span.
pub fn conditionalBodies(gpa: std.mem.Allocator, source: [:0]const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);

    // Open braces, innermost last.
    const Open = struct { line: u32, conditional: bool };
    var stack: std.ArrayList(Open) = .empty;
    defer stack.deinit(gpa);

    var tok = std.zig.Tokenizer.init(source);
    // Tokens arrive in source order, so the line number can be tracked by
    // walking forward through the text rather than rescanning it each time.
    var scanned: usize = 0;
    var line: u32 = 1;
    // Whether a branch keyword has been seen since the last statement boundary.
    var pending_branch = false;

    while (true) {
        const t = tok.next();
        while (scanned < t.loc.start) : (scanned += 1) {
            if (source[scanned] == '\n') line += 1;
        }
        switch (t.tag) {
            .eof => break,
            .keyword_if,
            .keyword_while,
            .keyword_for,
            .keyword_switch,
            .keyword_else,
            .keyword_catch,
            .keyword_orelse,
            .keyword_errdefer,
            // A switch prong body: `.a => { ... }`.
            .equal_angle_bracket_right,
            => pending_branch = true,
            // A statement boundary ends the reach of a keyword, so the `{` of a
            // following unrelated block is not mistaken for a branch body.
            .semicolon => pending_branch = false,
            .l_brace => {
                try stack.append(gpa, .{ .line = line, .conditional = pending_branch });
                pending_branch = false;
            },
            .r_brace => {
                const open = stack.pop() orelse continue; // unbalanced source
                if (open.conditional) {
                    try out.append(gpa, .{ .start_line = open.line, .end_line = line });
                }
            },
            else => {},
        }
    }

    return out.toOwnedSlice(gpa);
}

/// The tightest span containing `line`, or null when it is not inside any
/// conditional body.
pub fn innermost(spans: []const Span, line: u32) ?Span {
    var best: ?Span = null;
    for (spans) |s| {
        if (!s.contains(line)) continue;
        if (best == null or s.lineCount() < best.?.lineCount()) best = s;
    }
    return best;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn spansOf(gpa: std.mem.Allocator, src: [:0]const u8) ![]Span {
    return conditionalBodies(gpa, src);
}

test "finds if and else bodies, not the function body" {
    const alloc = std.testing.allocator;
    const src =
        \\pub fn f(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    const spans = try spansOf(alloc, src);
    defer alloc.free(spans);

    // The `fn` body must not be reported: it is not conditional.
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expect(innermost(spans, 3) != null); // inside `if`
    try std.testing.expect(innermost(spans, 5) != null); // inside `else`
    try std.testing.expect(innermost(spans, 1) == null); // fn signature
    try std.testing.expect(innermost(spans, 7) == null); // closing fn brace
}

test "finds while and for bodies" {
    const alloc = std.testing.allocator;
    const src =
        \\pub fn f(n: i32) void {
        \\    var i: i32 = 0;
        \\    while (i < n) : (i += 1) {
        \\        total += i;
        \\    }
        \\    for (items) |it| {
        \\        use(it);
        \\    }
        \\}
    ;
    const spans = try spansOf(alloc, src);
    defer alloc.free(spans);

    // The `:` continuation and the `|it|` payload must not break the keyword's
    // reach to its `{`.
    try std.testing.expect(innermost(spans, 4) != null); // while body
    try std.testing.expect(innermost(spans, 7) != null); // for body
    try std.testing.expect(innermost(spans, 2) == null); // plain statement
}

test "a plain block and a struct literal are not conditional" {
    const alloc = std.testing.allocator;
    const src =
        \\pub fn f() void {
        \\    {
        \\        scoped();
        \\    }
        \\    const s = .{
        \\        .a = 1,
        \\    };
        \\}
    ;
    const spans = try spansOf(alloc, src);
    defer alloc.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "catch, orelse and errdefer bodies are conditional" {
    const alloc = std.testing.allocator;
    const src =
        \\pub fn f() void {
        \\    const a = get() catch {
        \\        recover();
        \\    };
        \\    const b = opt orelse {
        \\        fallback();
        \\    };
        \\    errdefer {
        \\        cleanup();
        \\    }
        \\}
    ;
    const spans = try spansOf(alloc, src);
    defer alloc.free(spans);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expect(innermost(spans, 3) != null);
    try std.testing.expect(innermost(spans, 6) != null);
    try std.testing.expect(innermost(spans, 9) != null);
}

test "switch prong bodies are conditional" {
    const alloc = std.testing.allocator;
    const src =
        \\pub fn f(x: u8) void {
        \\    switch (x) {
        \\        1 => {
        \\            one();
        \\        },
        \\        else => {},
        \\    }
        \\}
    ;
    const spans = try spansOf(alloc, src);
    defer alloc.free(spans);
    try std.testing.expect(innermost(spans, 4) != null); // inside the prong
}

test "innermost picks the tightest enclosing span" {
    const spans = [_]Span{
        .{ .start_line = 1, .end_line = 100 },
        .{ .start_line = 10, .end_line = 20 },
        .{ .start_line = 30, .end_line = 40 },
    };
    try std.testing.expectEqual(@as(u32, 10), innermost(&spans, 15).?.start_line);
    try std.testing.expectEqual(@as(u32, 1), innermost(&spans, 5).?.start_line);
    try std.testing.expect(innermost(&spans, 200) == null);
}

test "unbalanced source does not crash or report a span" {
    const alloc = std.testing.allocator;
    const spans = try spansOf(alloc, "pub fn f() void { if (x) {");
    defer alloc.free(spans);
    // The unclosed braces never produce an end line, so nothing is reported.
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}
