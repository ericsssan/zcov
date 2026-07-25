//! Unified coverage data model.
//! All report generators consume this representation.

const std = @import("std");

pub const SourceLocation = struct {
    /// Absolute path to the source file.
    file: []const u8,
    /// 1-based line number.
    line: u32,
    /// 1-based column (0 = unknown).
    column: u32,
};

pub const LineCoverage = struct {
    /// 1-based line number.
    line: u32,
    /// Number of times this line was executed (0 = not executed).
    hit_count: u32,
};

pub const FunctionCoverage = struct {
    /// Mangled function name as it appears in DWARF.
    name: []const u8,
    /// 1-based line number where the function starts.
    start_line: u32,
    /// Number of times the function was called (approximated from its first line).
    hit_count: u32,
};

pub const FileCoverage = struct {
    /// Absolute path to the source file.
    path: []const u8,
    /// Coverage per executed line (sorted by line number, only lines that
    /// appear in DWARF are included).
    lines: []LineCoverage,
    /// Functions defined in this file.
    functions: []FunctionCoverage,
};

pub const Summary = struct {
    lines_found: u32,
    lines_hit: u32,
    functions_found: u32,
    functions_hit: u32,

    pub fn linePercent(s: Summary) f64 {
        if (s.lines_found == 0) return 100.0;
        return @as(f64, @floatFromInt(s.lines_hit)) / @as(f64, @floatFromInt(s.lines_found)) * 100.0;
    }

    pub fn functionPercent(s: Summary) f64 {
        if (s.functions_found == 0) return 100.0;
        return @as(f64, @floatFromInt(s.functions_hit)) / @as(f64, @floatFromInt(s.functions_found)) * 100.0;
    }
};

pub const CoverageData = struct {
    allocator: std.mem.Allocator,
    files: []FileCoverage,
    summary: Summary,

    pub fn deinit(self: *CoverageData) void {
        for (self.files) |fc| {
            self.allocator.free(fc.lines);
            for (fc.functions) |fn_cov| {
                self.allocator.free(fn_cov.name);
            }
            self.allocator.free(fc.functions);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

/// Builder accumulates per-file line hit counts, then produces CoverageData.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    /// file_path → (line → hit_count)
    file_map: std.StringHashMap(std.AutoHashMap(u32, u32)),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .file_map = std.StringHashMap(std.AutoHashMap(u32, u32)).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        var it = self.file_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*); // free the owned copy
            entry.value_ptr.deinit();
        }
        self.file_map.deinit();
    }

    /// Record that `line` in `file_path` was hit.
    /// Builder copies `file_path` on first insertion and owns the copy.
    pub fn recordHit(self: *Builder, file_path: []const u8, line: u32) !void {
        const count_ptr = try self.getOrPutLine(file_path, line);
        count_ptr.* += 1;
    }

    /// Record that `line` in `file_path` is *coverable* (has generated code) but
    /// say nothing about whether it was hit. Establishes the line with a hit
    /// count of 0 if not already present; never decreases an existing count.
    /// Feeding the full set of coverable lines (e.g. from the DWARF line table)
    /// turns unhit lines into genuine misses instead of leaving them absent.
    pub fn recordCoverable(self: *Builder, file_path: []const u8, line: u32) !void {
        _ = try self.getOrPutLine(file_path, line);
    }

    /// Get (creating if needed, initialized to 0) the hit-count slot for a line.
    fn getOrPutLine(self: *Builder, file_path: []const u8, line: u32) !*u32 {
        const gop = try self.file_map.getOrPut(file_path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, file_path);
            gop.value_ptr.* = std.AutoHashMap(u32, u32).init(self.allocator);
        }
        const count_gop = try gop.value_ptr.getOrPut(line);
        if (!count_gop.found_existing) {
            count_gop.value_ptr.* = 0;
        }
        return count_gop.value_ptr;
    }

    /// Produce the final CoverageData. Caller owns the result (call deinit).
    /// `all_lines`: optional map of file_path → sorted list of all coverable line numbers.
    /// When provided, lines not in `file_map` are included with hit_count = 0.
    pub fn build(self: *Builder) !CoverageData {
        var files: std.ArrayList(FileCoverage) = .empty;
        errdefer files.deinit(self.allocator);

        var summary = Summary{
            .lines_found = 0,
            .lines_hit = 0,
            .functions_found = 0,
            .functions_hit = 0,
        };

        var it = self.file_map.iterator();
        while (it.next()) |file_entry| {
            const path = file_entry.key_ptr.*;
            const line_map = file_entry.value_ptr;

            // Build sorted list of line coverages
            var lines: std.ArrayList(LineCoverage) = .empty;
            errdefer lines.deinit(self.allocator);

            var line_it = line_map.iterator();
            while (line_it.next()) |le| {
                try lines.append(self.allocator, .{ .line = le.key_ptr.*, .hit_count = le.value_ptr.* });
            }

            std.mem.sort(LineCoverage, lines.items, {}, struct {
                fn lt(_: void, a: LineCoverage, b: LineCoverage) bool {
                    return a.line < b.line;
                }
            }.lt);

            for (lines.items) |lc| {
                summary.lines_found += 1;
                if (lc.hit_count > 0) summary.lines_hit += 1;
            }

            try files.append(self.allocator, .{
                .path = path,
                .lines = try lines.toOwnedSlice(self.allocator),
                .functions = &.{},
            });
        }

        return CoverageData{
            .allocator = self.allocator,
            .files = try files.toOwnedSlice(self.allocator),
            .summary = summary,
        };
    }
};

test "Builder recordHit increments count" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("foo.zig", 5);
    try bldr.recordHit("foo.zig", 5);
    try bldr.recordHit("foo.zig", 5);

    const line_map = bldr.file_map.get("foo.zig").?;
    try std.testing.expectEqual(@as(u32, 3), line_map.get(5).?);
}

test "Builder recordHit tracks multiple files independently" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("a.zig", 1);
    try bldr.recordHit("b.zig", 2);

    try std.testing.expectEqual(@as(usize, 2), bldr.file_map.count());
    try std.testing.expectEqual(@as(u32, 1), bldr.file_map.get("a.zig").?.get(1).?);
    try std.testing.expectEqual(@as(u32, 1), bldr.file_map.get("b.zig").?.get(2).?);
}

test "Builder recordHit copies key string" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    // Allocate a key, record a hit, then free the original.
    // The builder must own its own copy so the map remains valid afterward.
    const key = try std.testing.allocator.dupe(u8, "owned.zig");
    try bldr.recordHit(key, 1);
    std.testing.allocator.free(key);

    try std.testing.expect(bldr.file_map.contains("owned.zig"));
}

test "Builder recordCoverable establishes a miss that hits then upgrade" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    // Coverable-but-unhit line stays at 0 (a miss).
    try bldr.recordCoverable("m.zig", 2);
    // A coverable line that later gets hit becomes a hit, regardless of order.
    try bldr.recordCoverable("m.zig", 4);
    try bldr.recordHit("m.zig", 4);
    // recordCoverable on an already-hit line does not reset the count.
    try bldr.recordHit("m.zig", 6);
    try bldr.recordCoverable("m.zig", 6);

    const line_map = bldr.file_map.get("m.zig").?;
    try std.testing.expectEqual(@as(u32, 0), line_map.get(2).?);
    try std.testing.expectEqual(@as(u32, 1), line_map.get(4).?);
    try std.testing.expectEqual(@as(u32, 1), line_map.get(6).?);
}

test "Builder build counts coverable misses in the summary" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("s.zig", 1); // hit
    try bldr.recordCoverable("s.zig", 2); // miss
    try bldr.recordCoverable("s.zig", 3); // miss

    var cov = try bldr.build();
    defer cov.deinit();

    try std.testing.expectEqual(@as(u32, 3), cov.summary.lines_found);
    try std.testing.expectEqual(@as(u32, 1), cov.summary.lines_hit);
    try std.testing.expectApproxEqAbs(@as(f64, 33.333), cov.summary.linePercent(), 0.01);
}

test "Builder build produces sorted lines and correct summary" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("z.zig", 10);
    try bldr.recordHit("z.zig", 2);
    try bldr.recordHit("z.zig", 2); // line 2 hit twice

    var cov = try bldr.build();
    defer cov.deinit(); // runs before bldr.deinit() (LIFO)

    try std.testing.expectEqual(@as(usize, 1), cov.files.len);
    const lines = cov.files[0].lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    // Lines sorted by number: 2 then 10
    try std.testing.expectEqual(@as(u32, 2), lines[0].line);
    try std.testing.expectEqual(@as(u32, 2), lines[0].hit_count);
    try std.testing.expectEqual(@as(u32, 10), lines[1].line);
    try std.testing.expectEqual(@as(u32, 1), lines[1].hit_count);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.lines_found);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.lines_hit);
}

test "Summary linePercent and functionPercent" {
    const s = Summary{
        .lines_found = 10,
        .lines_hit = 5,
        .functions_found = 4,
        .functions_hit = 3,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), s.linePercent(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), s.functionPercent(), 0.001);
}

test "Summary returns 100 percent when no items" {
    const s = Summary{
        .lines_found = 0,
        .lines_hit = 0,
        .functions_found = 0,
        .functions_hit = 0,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), s.linePercent(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), s.functionPercent(), 0.001);
}
