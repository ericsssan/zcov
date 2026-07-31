//! Build orchestrator: compiles the runtime library and invokes `zig build test`
//! with coverage instrumentation enabled.
//!
//! Workflow:
//!  1. Locate the `zig` executable.
//!  2. Determine the output directory for .zcov files (temp dir per run).
//!  3. Invoke `zig build test -Dcoverage=true -Dcoverage-rt=<path>`.
//!  4. Collect .zcov files from the output directory.
//!  5. Return paths to the collected data files and the test binary.

const std = @import("std");

pub const OrchestratorError = error{
    ZigNotFound,
    BuildFailed,
    NoCoverageFiles,
} || std.mem.Allocator.Error || std.process.SpawnError || std.process.RunError ||
    std.Io.File.OpenError || std.Io.Dir.OpenError;

pub const RunResult = struct {
    /// Absolute path to the directory containing .zcov files.
    zcov_dir: []u8,
    /// Paths to all .zcov files collected (may be empty if no tests ran).
    zcov_files: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.zcov_dir);
        for (self.zcov_files) |f| self.allocator.free(f);
        self.allocator.free(self.zcov_files);
        self.* = undefined;
    }
};

pub const Options = struct {
    /// Directory containing the user's build.zig.
    project_dir: []const u8,
    /// Additional args to pass to `zig build test` (e.g. "--", "-v").
    extra_args: []const []const u8 = &.{},
    /// Allocator for subprocess output.
    allocator: std.mem.Allocator,
    /// Io instance.
    io: std.Io,
    /// Parent process environment (to inherit + add ZIG_COV_DIR).
    parent_environ: *const std.process.Environ.Map,
};

/// Run `zig build test` with coverage instrumentation.
/// Returns collected .zcov file paths. Caller owns the result.
pub fn run(opts: Options) OrchestratorError!RunResult {
    const allocator = opts.allocator;
    const io = opts.io;

    // Create a temporary directory for .zcov output.
    var tmp_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zcov_dir = try makeTmpDir(io, &tmp_dir_buf);
    errdefer removeTmpDir(io, zcov_dir);

    // Find the zig executable.
    const zig_path = findZig(allocator, io) catch return error.ZigNotFound;
    defer allocator.free(zig_path);

    // Build the runtime library path (next to ourselves).
    var self_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const self_exe_len = std.process.executablePath(io, &self_path_buf) catch return error.ZigNotFound;
    const self_path = self_path_buf[0..self_exe_len];
    const self_dir = std.fs.path.dirname(self_path) orelse ".";

    const rt_path = try std.fs.path.join(allocator, &.{ self_dir, "zig-cov-rt.o" });
    defer allocator.free(rt_path);

    // Build argv.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const cov_rt_arg = try std.fmt.allocPrint(allocator, "-Dcoverage-rt={s}", .{rt_path});
    defer allocator.free(cov_rt_arg);

    try argv.appendSlice(allocator, &.{
        zig_path,
        "build",
        "test",
        "-Dcoverage=true",
        cov_rt_arg,
    });

    for (opts.extra_args) |arg| try argv.append(allocator, arg);

    // Build child environment: copy parent + add ZIG_COV_DIR.
    var child_env = try buildChildEnv(allocator, opts.parent_environ, zcov_dir);
    defer child_env.deinit();

    // Force the project's `zig build test` to actually recompile AND re-run the
    // instrumented binary by giving it a throwaway local cache. Zig caches the
    // test *run*; with a warm cache it is skipped and no coverage-<pid>.zcov is
    // written (ZIG_COV_DIR is not part of Zig's cache key), so a second
    // `zig-cov test` would otherwise report "no .zcov files found". Fresh per
    // invocation under our temp dir. ZIG_GLOBAL_CACHE_DIR is left inherited so
    // the std library and dependencies stay cached.
    const proj_cache = try std.fs.path.join(allocator, &.{ zcov_dir, "cache" });
    defer allocator.free(proj_cache);
    try child_env.put("ZIG_LOCAL_CACHE_DIR", proj_cache);

    // Run the build.
    // Print the command as text. ({any} on [][]const u8 renders each argument as
    // a list of byte values, which is unreadable.)
    std.debug.print("zig-cov: running:", .{});
    for (argv.items) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = opts.project_dir },
        .environ_map = &child_env,
    }) catch |e| return e;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stderr.len > 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    if (result.stdout.len > 0) {
        std.debug.print("{s}", .{result.stdout});
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return error.BuildFailed,
        else => return error.BuildFailed,
    }

    // Collect .zcov files.
    const zcov_files = try collectZcovFiles(allocator, io, zcov_dir);

    const zcov_dir_owned = try allocator.dupe(u8, zcov_dir);
    return RunResult{
        .zcov_dir = zcov_dir_owned,
        .zcov_files = zcov_files,
        .allocator = allocator,
    };
}

fn makeTmpDir(io: std.Io, buf: []u8) OrchestratorError![]const u8 {
    const pid = std.c.getpid();
    const path = std.fmt.bufPrint(buf, "/tmp/zig-cov-{d}", .{pid}) catch return error.ZigNotFound;
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.BuildFailed,
    };
    return path;
}

fn removeTmpDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteTree(.cwd(), io, path) catch {};
}

fn findZig(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    // Try the PATH first.
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "which", "zig" },
        .stdout_limit = std.Io.Limit.limited(1024),
    }) catch return error.ZigNotFound;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        const path = std.mem.trim(u8, result.stdout, "\n\r ");
        return allocator.dupe(u8, path);
    }
    return error.ZigNotFound;
}

fn buildChildEnv(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
    zcov_dir: []const u8,
) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();

    // Copy all entries from the parent environment.
    var it = parent.iterator();
    while (it.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Override with our coverage directory.
    try env.put("ZIG_COV_DIR", zcov_dir);
    return env;
}

fn collectZcovFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) OrchestratorError![][]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".zcov")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        try files.append(allocator, full_path);
    }

    return files.toOwnedSlice(allocator);
}
