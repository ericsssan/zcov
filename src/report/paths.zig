//! Path helpers shared by the report writers.

const std = @import("std");

/// Strip `root` (and the separator that follows it) from `path`.
///
/// Coverage consumers — Codecov, Coveralls, GitLab, Jenkins, GitHub annotations
/// — match coverage to source by path *relative to the repository root*. An
/// absolute build path does not match anything, and the file silently shows up
/// as missing rather than as an error, so writers normalise paths before
/// emitting them.
///
/// Returns `path` unchanged when `root` is null, empty, or not a prefix, and
/// when stripping would leave nothing.
pub fn relativize(path: []const u8, root: ?[]const u8) []const u8 {
    const r = root orelse return path;
    if (r.len == 0 or !std.mem.startsWith(u8, path, r)) return path;
    var rest = path[r.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return if (rest.len == 0) path else rest;
}

test "relativize strips the root prefix and separator" {
    try std.testing.expectEqualStrings("src/a.zig", relativize("/home/u/proj/src/a.zig", "/home/u/proj"));
    // A trailing separator on the root is tolerated.
    try std.testing.expectEqualStrings("src/a.zig", relativize("/home/u/proj/src/a.zig", "/home/u/proj/"));
}

test "relativize leaves unrelated or already-relative paths alone" {
    try std.testing.expectEqualStrings("src/a.zig", relativize("src/a.zig", "/home/u/proj"));
    try std.testing.expectEqualStrings("/other/a.zig", relativize("/other/a.zig", "/home/u/proj"));
    try std.testing.expectEqualStrings("/home/u/proj/a.zig", relativize("/home/u/proj/a.zig", null));
    try std.testing.expectEqualStrings("/home/u/proj/a.zig", relativize("/home/u/proj/a.zig", ""));
}

test "relativize does not reduce a path to nothing" {
    // The root itself is not a file, but must not become an empty path.
    try std.testing.expectEqualStrings("/home/u/proj", relativize("/home/u/proj", "/home/u/proj"));
}
