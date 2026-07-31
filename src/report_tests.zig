//! Test root for the coverage model and report formatters.
//!
//! Run with: zig build test
//!
//! Zig only includes a module's test blocks in a test binary when that module
//! is actually reachable from the binary's call graph. This file calls a
//! function from each module so they survive DCE, which causes the test runner
//! to discover all their `test "..."` blocks.

const std = @import("std");
const coverage = @import("coverage.zig");
const lcov = @import("report/lcov.zig");
const summary = @import("report/summary.zig");
const html = @import("report/html.zig");
const json = @import("report/json.zig");
const cobertura = @import("report/cobertura.zig");
const github = @import("report/github.zig");
const blocks = @import("dwarf/blocks.zig");

// Empty CoverageData used by the anchor tests below.
fn emptyData(alloc: std.mem.Allocator) coverage.CoverageData {
    return .{
        .allocator = alloc,
        .files = &.{},
        .summary = .{ .lines_found = 0, .lines_hit = 0, .functions_found = 0, .functions_hit = 0 },
    };
}

// Each test below touches one module to keep it in the call graph. The
// test runner then discovers and runs all tests in those modules too.

test "anchor: coverage.Builder is reachable" {
    var bldr = coverage.Builder.init(std.testing.allocator);
    defer bldr.deinit();
}

test "anchor: lcov.write is reachable" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const data = emptyData(std.testing.allocator);
    try lcov.write(std.testing.allocator, &buf.writer, &data, .{});
}

test "anchor: summary.write is reachable" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const data = emptyData(std.testing.allocator);
    _ = try summary.write(&buf.writer, &data, .{ .color = false });
}

// html.write needs an Io to read source files; referencing it (without calling)
// pulls report/html.zig into the module graph so the test runner discovers its
// (I/O-free) test blocks.
test "anchor: report/html is reachable" {
    _ = &html.write;
}

test "anchor: json.write is reachable" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const data = emptyData(std.testing.allocator);
    try json.write(std.testing.allocator, &buf.writer, &data);
}

test "anchor: cobertura.write is reachable" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const data = emptyData(std.testing.allocator);
    try cobertura.write(std.testing.allocator, &buf.writer, &data, .{});
}

// Not a report writer, but it needs the same anchoring: its tests only run if
// something reachable from this root references it.
test "anchor: dwarf/blocks is reachable" {
    const pcs = try blocks.scanCallSites(std.testing.allocator, .aarch64, &.{}, 0, 0);
    defer std.testing.allocator.free(pcs);
}

test "anchor: github.write is reachable" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const data = emptyData(std.testing.allocator);
    _ = try github.write(std.testing.allocator, &buf.writer, &data, .{});
}
