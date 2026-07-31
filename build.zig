const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Self-coverage: zig-cov measuring its own test suite. These are the same
    // options `zig-cov test` passes to any project (see the README setup), which
    // is what lets the tool dogfood itself in CI.
    const coverage = b.option(bool, "coverage", "Instrument zig-cov's own tests with zig-cov") orelse false;
    const coverage_rt = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o") orelse null;

    // zig-cov CLI executable
    const exe = b.addExecutable(.{
        .name = "zig-cov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // build_orchestrator.zig calls std.c.getpid() and zcov_format.zig
            // uses fopen/fread. macOS links libc implicitly; Linux does not, so
            // it must be explicit or the build fails on Linux.
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // zig-cov-rt: runtime linked into instrumented test binaries. Emitted as a
    // relocatable OBJECT (not a static library): the sancov callbacks must be
    // force-included, but lld pulls .a members lazily and drops them, so on Linux
    // __sanitizer_cov_trace_pc_guard ends up undefined. An object is always
    // linked in full. link_libc = true so atexit()/fopen() are available.
    const rt_obj = b.addObject(.{
        .name = "zig-cov-rt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(rt_obj.getEmittedBin(), .lib, "zig-cov-rt.o").step);

    // Run step for the CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zig-cov");
    run_step.dependOn(&run_cmd.step);

    // Tests for zig-cov itself (main + report + coverage model).
    // link_libc = true is required because zcov_format.zig (imported transitively)
    // has tests that call fopen/fread, which need the system C library.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (coverage) instrument(unit_tests, coverage_rt);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Runtime library tests
    const rt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Deliberately NOT instrumented: this binary's root module *is* the coverage
    // runtime, so linking zig-cov-rt.o would duplicate the sancov symbols, and
    // instrumenting the trace callbacks would have them record their own calls.
    const run_rt_tests = b.addRunArtifact(rt_tests);
    test_step.dependOn(&run_rt_tests.step);

    // Coverage model + report formatter tests.
    // Uses a dedicated root (report_tests.zig) so that DCE does not drop these
    // modules: their code is only reachable from the CLI main, which is replaced
    // by the test runner and therefore eliminated in a test binary.
    const report_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/report_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (coverage) instrument(report_tests, coverage_rt);
    const run_report_tests = b.addRunArtifact(report_tests);
    test_step.dependOn(&run_report_tests.step);

    // Integration test (run with: zig build itest)
    // Builds the sample project under test/sample/ with coverage and verifies
    // that the full pipeline (sancov → .zcov → DWARF → report) is correct.
    const itest_options = b.addOptions();
    itest_options.addOptionPath("rt_lib_path", rt_obj.getEmittedBin());
    itest_options.addOption([]const u8, "sample_dir", b.root.joinString(b.graph.arena, "test/sample") catch @panic("OOM"));
    itest_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);

    const itest_exe = b.addExecutable(.{
        .name = "zig-cov-itest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            // Uses std.c.getpid() and, via zcov_format.zig, fopen/fread — libc
            // must be explicit for the Linux build (see the exe above).
            .link_libc = true,
        }),
    });
    itest_exe.root_module.addOptions("build_options", itest_options);
    itest_exe.step.dependOn(b.getInstallStep()); // ensure zig-cov-rt.o is installed first

    const run_itest = b.addRunArtifact(itest_exe);
    const itest_step = b.step("itest", "Run integration tests (full pipeline: sancov → .zcov → DWARF → report)");
    itest_step.dependOn(&run_itest.step);

    // Synthetic benchmarks (run with: zig build bench)
    const bench_exe = b.addExecutable(.{
        .name = "zig-cov-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run synthetic performance benchmarks");
    bench_step.dependOn(&run_bench.step);
}

/// Apply zig-cov instrumentation to a test binary — the same three settings the
/// README tells users to add to their own build.zig:
///   * use_llvm: coverage instrumentation is only emitted by the LLVM backend
///   * fuzz: emits inline 8-bit counters and the PC table zig-cov reads
///   * link_libc: the runtime writes its .zcov from a libc atexit handler
fn instrument(compile: *std.Build.Step.Compile, rt_path: ?[]const u8) void {
    compile.use_llvm = true;
    compile.root_module.fuzz = true;
    compile.root_module.link_libc = true;
    if (rt_path) |p| compile.root_module.addObjectFile(.{ .cwd_relative = p });
}
