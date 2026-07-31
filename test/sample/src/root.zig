// Integration test sample: add and multiply are tested, subtract is not.
// zig-cov should report line 2 and line 10 as hit, line 6 as not hit.
const math = @import("math.zig");
const std = @import("std");

test "add" {
    try std.testing.expectEqual(@as(i32, 5), math.add(2, 3));
}

test "sumTo with a zero-iteration loop" {
    // The loop body never runs, so its line must be reported as a miss rather
    // than inheriting the surrounding code.
    try std.testing.expectEqual(@as(i32, 0), math.sumTo(0));
}

test "multiply" {
    try std.testing.expectEqual(@as(i32, 6), math.multiply(2, 3));
}

// Force `subtract` to be compiled (referenced) without calling it, so its
// body is a coverable-but-unhit MISS rather than dead-code-eliminated.
comptime {
    _ = &math.subtract;
}
