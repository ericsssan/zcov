//! Integration test for the full zig-cov pipeline.
//!
//! Verifies end-to-end:
//!   1. A real LLVM-instrumented test binary writes a valid .zcov file on exit.
//!   2. DWARF resolution maps PCs to correct source file:line pairs.
//!   3. Line coverage is accurate: executed lines hit, unexecuted lines absent.
//!
//! The sample project under test/sample/ has three functions:
//!   add(a, b)      — tested  → math.zig line 2 must be HIT
//!   subtract(a, b) — untested → math.zig line 6 must be ABSENT
//!   multiply(a, b) — tested  → math.zig line 10 must be HIT
//!
//! Run with: zig build itest

const std = @import("std");
const build_options = @import("build_options");

const zcov_format = @import("runtime/zcov_format.zig");
const resolver = @import("dwarf/resolver.zig");
const coverage_mod = @import("coverage.zig");

// Expected line numbers in test/sample/src/math.zig — must match the file exactly.
const LINE_ADD: u32 = 2; // return a + b;
const LINE_SUBTRACT: u32 = 6; // return a - b;
const LINE_MULTIPLY: u32 = 10; // return a * b;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    std.debug.print("=== zig-cov integration test ===\n", .{});

    var step: u32 = 0;

    // Create a temp dir to collect .zcov output from the sample binary.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pid = std.c.getpid();
    const zcov_dir = std.fmt.bufPrint(&tmp_buf, "/tmp/zig-cov-itest-{d}", .{pid}) catch unreachable;
    std.Io.Dir.createDirAbsolute(io, zcov_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.Io.Dir.deleteTree(.cwd(), io, zcov_dir) catch {};

    // Step 1: build and run the sample project with coverage instrumentation.
    try runSampleWithCoverage(gpa, io, init.environ_map, zcov_dir);

    // Step 2: collect .zcov files.
    const zcov_files = try collectZcovFiles(gpa, io, zcov_dir);
    defer {
        for (zcov_files) |f| gpa.free(f);
        gpa.free(zcov_files);
    }

    check(zcov_files.len > 0, "no .zcov files produced — is ZIG_COV_DIR being picked up?");
    step += 1;
    std.debug.print("PASS [{d}] {d} .zcov file(s) produced\n", .{ step, zcov_files.len });

    // Step 3: read each .zcov file, resolve PCs through DWARF.
    var builder = coverage_mod.Builder.init(gpa);
    defer builder.deinit();

    var total_pcs: usize = 0;
    for (zcov_files) |zcov_path| {
        var data = try zcov_format.read(gpa, io, zcov_path);
        defer data.deinit();
        total_pcs += data.pcs.len;
        if (data.pcs.len == 0) continue;

        const locations = try resolver.resolveAddresses(gpa, io, data.bin_path, data.slide, data.pcs);
        defer {
            for (locations) |loc| {
                if (!std.mem.eql(u8, loc.file, "<unknown>")) gpa.free(loc.file);
            }
            gpa.free(locations);
        }

        for (locations) |loc| {
            if (loc.line == 0) continue;
            try builder.recordHit(loc.file, loc.line);
        }
    }

    check(total_pcs > 0, ".zcov file(s) contain zero PCs — sancov callbacks not firing?");
    step += 1;
    std.debug.print("PASS [{d}] {d} PCs resolved through DWARF\n", .{ step, total_pcs });

    // Step 4: find math.zig in the coverage map.
    const math_key = findFile(&builder, "math.zig") orelse {
        fail("no coverage data for math.zig — DWARF resolution produced wrong file names");
    };
    step += 1;
    std.debug.print("PASS [{d}] math.zig present in coverage ({s})\n", .{ step, math_key });

    const line_map = builder.file_map.get(math_key).?;

    // Step 5a: add (line 2) must be hit.
    check(line_map.get(LINE_ADD) != null, "math.zig line 2 (add) expected HIT but absent");
    step += 1;
    std.debug.print("PASS [{d}] math.zig:{d} (add) is hit\n", .{ step, LINE_ADD });

    // Step 5b: multiply (line 10) must be hit.
    check(line_map.get(LINE_MULTIPLY) != null, "math.zig line 10 (multiply) expected HIT but absent");
    step += 1;
    std.debug.print("PASS [{d}] math.zig:{d} (multiply) is hit\n", .{ step, LINE_MULTIPLY });

    // Step 5c: subtract (line 6) must NOT be hit.
    check(line_map.get(LINE_SUBTRACT) == null, "math.zig line 6 (subtract) expected NOT HIT but was recorded");
    step += 1;
    std.debug.print("PASS [{d}] math.zig:{d} (subtract) is correctly absent\n", .{ step, LINE_SUBTRACT });

    // Step 6: hit counts must be positive (not just present).
    const add_hits = line_map.get(LINE_ADD) orelse { fail("add absent — unreachable after step 4"); };
    const mul_hits = line_map.get(LINE_MULTIPLY) orelse { fail("multiply absent — unreachable after step 5"); };
    check(add_hits >= 1, "add hit count must be >= 1");
    check(mul_hits >= 1, "multiply hit count must be >= 1");
    step += 1;
    std.debug.print("PASS [{d}] hit counts are positive (add={d}, multiply={d})\n", .{ step, add_hits, mul_hits });

    // Step 7-8: multi-run merge + ASLR.
    // Re-execute the instrumented test binary directly (its absolute path is
    // recorded in the first run's .zcov). Going through `zig build test` again
    // would hit Zig's build cache and not actually re-run the binary. A direct
    // second run writes a new coverage-<pid>.zcov with a different PID and (on
    // macOS) a different ASLR slide. After merging both .zcov files each
    // function's hit count must be >= 2.
    const first_bin = blk: {
        var d0 = try zcov_format.read(gpa, io, zcov_files[0]);
        defer d0.deinit();
        break :blk try gpa.dupe(u8, d0.bin_path);
    };
    defer gpa.free(first_bin);
    try runBinaryWithCoverage(gpa, io, init.environ_map, first_bin, zcov_dir);

    const all_zcov = try collectZcovFiles(gpa, io, zcov_dir);
    defer {
        for (all_zcov) |f| gpa.free(f);
        gpa.free(all_zcov);
    }
    check(all_zcov.len >= 2, "expected >= 2 .zcov files after two runs");
    step += 1;
    std.debug.print("PASS [{d}] {d} .zcov files produced across two runs\n", .{ step, all_zcov.len });

    var merged = coverage_mod.Builder.init(gpa);
    defer merged.deinit();
    for (all_zcov) |zcov_path| {
        var d = try zcov_format.read(gpa, io, zcov_path);
        defer d.deinit();
        if (d.pcs.len == 0) continue;
        const locs = try resolver.resolveAddresses(gpa, io, d.bin_path, d.slide, d.pcs);
        defer {
            for (locs) |loc| if (!std.mem.eql(u8, loc.file, "<unknown>")) gpa.free(loc.file);
            gpa.free(locs);
        }
        for (locs) |loc| {
            if (loc.line == 0) continue;
            try merged.recordHit(loc.file, loc.line);
        }
    }

    const merged_key = findFile(&merged, "math.zig") orelse { fail("math.zig absent from merged coverage"); };
    const merged_map = merged.file_map.get(merged_key).?;
    const merged_add = merged_map.get(LINE_ADD) orelse { fail("add absent after merge"); };
    const merged_mul = merged_map.get(LINE_MULTIPLY) orelse { fail("multiply absent after merge"); };
    check(merged_add >= 2, "add hit count must be >= 2 after two runs");
    check(merged_mul >= 2, "multiply hit count must be >= 2 after two runs");
    step += 1;
    std.debug.print("PASS [{d}] merged hit counts >= 2 after two runs (add={d}, multiply={d})\n", .{ step, merged_add, merged_mul });

    std.debug.print("=== all {d} integration tests passed ===\n", .{step});
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn check(ok: bool, msg: []const u8) void {
    if (!ok) fail(msg);
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("FAIL: {s}\n", .{msg});
    std.process.exit(1);
}

fn findFile(builder: *const coverage_mod.Builder, suffix: []const u8) ?[]const u8 {
    var it = builder.file_map.keyIterator();
    while (it.next()) |key| {
        if (std.mem.endsWith(u8, key.*, suffix)) return key.*;
    }
    return null;
}

fn runSampleWithCoverage(
    gpa: std.mem.Allocator,
    io: std.Io,
    parent_env: *std.process.Environ.Map,
    zcov_dir: []const u8,
) !void {
    // Give the sample build its OWN throwaway local cache dir so `zig build test`
    // always recompiles AND re-runs the instrumented binary. With a warm cache the
    // test run is marked up-to-date and skipped, so no coverage-<pid>.zcov is
    // written (ZIG_COV_DIR is invisible to Zig's cache key). We can't just clear
    // test/sample/.zig-cache: CI (via setup-zig) sets ZIG_LOCAL_CACHE_DIR to a
    // shared, restored-across-runs cache, so the sample would cache there instead.
    // Overriding ZIG_LOCAL_CACHE_DIR to a fresh per-run dir is location-independent.
    // (ZIG_GLOBAL_CACHE_DIR is left inherited so the std lib stays cached — only
    // the project's build+run manifests are forced cold.)
    const sample_cache = try std.fs.path.join(gpa, &.{ zcov_dir, "sample-cache" });
    defer gpa.free(sample_cache);

    // Build child environment: copy parent + set ZIG_COV_DIR and the private cache.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var it = parent_env.iterator();
    while (it.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
    try env.put("ZIG_COV_DIR", zcov_dir);
    try env.put("ZIG_LOCAL_CACHE_DIR", sample_cache);

    // build_options.rt_lib_path is relative to the build root (this process's cwd).
    // The sample build below runs from a different cwd (test/sample), so resolve
    // it to an absolute path first.
    const rt_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.rt_lib_path, gpa);
    defer gpa.free(rt_abs);
    const rt_arg = try std.fmt.allocPrint(gpa, "-Dcoverage-rt={s}", .{rt_abs});
    defer gpa.free(rt_arg);

    std.debug.print("running: {s} build test -Dcoverage=true {s}\n", .{ build_options.zig_exe, rt_arg });

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ build_options.zig_exe, "build", "test", "-Dcoverage=true", rt_arg },
        .cwd = .{ .path = build_options.sample_dir },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
    if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});

    switch (result.term) {
        .exited => |code| if (code != 0) fail("sample build exited with non-zero code"),
        else => fail("sample build terminated abnormally"),
    }
}

/// Run an already-built instrumented binary directly (bypassing `zig build`),
/// with ZIG_COV_DIR pointed at zcov_dir so it writes a fresh coverage-<pid>.zcov.
fn runBinaryWithCoverage(
    gpa: std.mem.Allocator,
    io: std.Io,
    parent_env: *std.process.Environ.Map,
    bin_path: []const u8,
    zcov_dir: []const u8,
) !void {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var it = parent_env.iterator();
    while (it.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
    try env.put("ZIG_COV_DIR", zcov_dir);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{bin_path},
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) fail("direct sample run exited with non-zero code"),
        else => fail("direct sample run terminated abnormally"),
    }
}

fn collectZcovFiles(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".zcov")) continue;
        const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        try files.append(gpa, full_path);
    }
    return files.toOwnedSlice(gpa);
}
