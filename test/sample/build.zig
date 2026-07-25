const std = @import("std");

pub fn build(b: *std.Build) void {
    const coverage = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
    const rt_path = b.option([]const u8, "coverage-rt", "Absolute path to zig-cov-rt.o") orelse null;

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = .Debug,
        }),
    });

    if (coverage) {
        // sanitize-coverage requires the LLVM backend. The self-hosted x86_64
        // backend (the Debug default on Linux) silently emits no instrumentation,
        // so force LLVM to get the trace-pc-guard callbacks.
        unit_tests.use_llvm = true;
        unit_tests.sanitize_coverage_trace_pc_guard = true;
        // The runtime uses libc (fopen) and writes coverage from a libc atexit
        // handler. Without link_libc, builtin.link_libc is false and
        // std.process.exit() takes the raw-syscall path on Linux, so the handler
        // never runs and no .zcov is written. (macOS always links libc.)
        unit_tests.root_module.link_libc = true;
        // Link the runtime as an object (rt_path points at zig-cov-rt.o) so the
        // sancov symbols are force-included; a static archive gets dropped by lld.
        if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
