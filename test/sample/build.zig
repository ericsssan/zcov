const std = @import("std");

pub fn build(b: *std.Build) void {
    const coverage = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
    const rt_path = b.option([]const u8, "coverage-rt", "Absolute path to libzig-cov-rt.a") orelse null;

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = .Debug,
        }),
    });

    if (coverage) {
        unit_tests.sanitize_coverage_trace_pc_guard = true;
        // Required: the runtime uses libc (fopen) and writes coverage from a libc
        // atexit handler. Without link_libc, builtin.link_libc is false and
        // std.process.exit() takes the raw-syscall path on Linux, so the atexit
        // handler never runs and no .zcov is written. (macOS always links libc.)
        unit_tests.root_module.link_libc = true;
        if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
