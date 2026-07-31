//! zig-cov: Zig code coverage tool.
//!
//! Usage:
//!   zig-cov test [options] [-- zig-build-args...]
//!   zig-cov report [options] <zcov-file>...
//!   zig-cov --help
//!
//! Options:
//!   --format=summary|lcov|html|json  Output format (default: summary)
//!   --output=<path>           Output file path (default: stdout for summary,
//!                             coverage.html for html)
//!   --fail-under=<pct>        Exit 1 if line coverage is below this %
//!   --color=on|off|auto       Terminal color (default: auto)
//!   --project=<dir>           Project directory containing build.zig
//!                             (default: current directory)
//!   --include=<substr>        Only report files matching (repeatable;
//!                             overrides the default project-dir filter)
//!   --exclude=<substr>        Drop files matching (repeatable)

const std = @import("std");
const builtin = @import("builtin");

const zcov_format = @import("runtime/zcov_format.zig");
const coverage = @import("coverage.zig");
const resolver = @import("dwarf/resolver.zig");
const lcov_report = @import("report/lcov.zig");
const summary_report = @import("report/summary.zig");
const html_report = @import("report/html.zig");
const json_report = @import("report/json.zig");
const orchestrator = @import("build_orchestrator.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Collect args into a slice.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var args_iter = init.minimal.args.iterate();
    while (args_iter.next()) |arg| {
        try args_list.append(gpa, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "test")) {
        try cmdTest(gpa, io, init.environ_map, args[2..]);
    } else if (std.mem.eql(u8, cmd, "report")) {
        try cmdReport(gpa, io, args[2..]);
    } else {
        std.debug.print("zig-cov: unknown command '{s}'\n", .{cmd});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    const text =
        \\zig-cov - Zig code coverage tool
        \\
        \\Usage:
        \\  zig-cov test [options] [-- zig-build-args...]
        \\  zig-cov report [options] <file.zcov>...
        \\
        \\Commands:
        \\  test     Build with coverage, run tests, generate report
        \\  report   Generate report from existing .zcov file(s)
        \\
        \\Options:
        \\  --format=summary|lcov|html|json
        \\                            Output format (default: summary)
        \\  --output=<path>           Output file (html defaults to coverage.html;
        \\                            lcov/json go to stdout unless set)
        \\  --fail-under=<pct>        Exit 1 if line coverage below threshold
        \\  --color=on|off|auto       Terminal color (default: auto)
        \\  --project=<dir>           Project directory (default: .)
        \\  --include=<substr>        Only report files matching (repeatable;
        \\                            overrides the default project-dir filter)
        \\  --exclude=<substr>        Drop files matching (repeatable)
        \\
        \\By default only files under --project are reported (the Zig std library
        \\and out-of-tree files are hidden). Pass --include=<substr> to override.
        \\
        \\Setup (add to your build.zig):
        \\  const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
        \\  const rt_path  = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;
        \\  if (coverage) {
        \\      unit_tests.sanitize_coverage_trace_pc_guard = true;
        \\      if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
        \\  }
        \\
    ;
    std.debug.print("{s}", .{text});
}

// ---------------------------------------------------------------------------
// Parsed options
// ---------------------------------------------------------------------------

const Format = enum { summary, lcov, html, json };

const Opts = struct {
    format: Format = .summary,
    output: ?[]const u8 = null,
    fail_under: f64 = 0,
    color: bool = true,
    project: []const u8 = ".",
    /// Substrings; if any given, only files matching one are reported (replaces
    /// the default "under the project directory" filter).
    include: std.ArrayList([]const u8) = .empty,
    /// Substrings; files matching any are dropped (applied after include).
    exclude: std.ArrayList([]const u8) = .empty,
    extra_args: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Opts, gpa: std.mem.Allocator) void {
        self.include.deinit(gpa);
        self.exclude.deinit(gpa);
        self.extra_args.deinit(gpa);
    }
};

/// Decides which source files appear in the report.
const PathFilter = struct {
    /// Absolute path of the project directory. When no `include` is given, only
    /// files under this prefix are kept (drops the Zig std library, global
    /// cache, and other out-of-tree files). null = keep everything.
    project_prefix: ?[]const u8,
    include: []const []const u8,
    exclude: []const []const u8,

    fn accept(self: PathFilter, path: []const u8) bool {
        for (self.exclude) |pat| {
            if (std.mem.indexOf(u8, path, pat) != null) return false;
        }
        if (self.include.len > 0) {
            for (self.include) |pat| {
                if (std.mem.indexOf(u8, path, pat) != null) return true;
            }
            return false;
        }
        if (self.project_prefix) |prefix| {
            // Relative paths come from DWARF relative to the build cwd (the
            // project root), so they are project files — keep them. Only absolute
            // paths (e.g. the Zig std library) are prefix-checked.
            if (!std.fs.path.isAbsolute(path)) return true;
            if (!std.mem.startsWith(u8, path, prefix)) return false;
            // Match a directory boundary so /a/proj does not match /a/project2.
            return path.len == prefix.len or path[prefix.len] == '/';
        }
        return true;
    }
};

fn parseOpts(gpa: std.mem.Allocator, raw_args: []const []const u8) !Opts {
    var opts = Opts{};

    var i: usize = 0;
    var after_dashdash = false;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (after_dashdash) {
            try opts.extra_args.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_dashdash = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const val = arg["--format=".len..];
            if (std.mem.eql(u8, val, "lcov")) {
                opts.format = .lcov;
            } else if (std.mem.eql(u8, val, "summary")) {
                opts.format = .summary;
            } else if (std.mem.eql(u8, val, "html")) {
                opts.format = .html;
            } else if (std.mem.eql(u8, val, "json")) {
                opts.format = .json;
            } else {
                std.debug.print("zig-cov: unknown format '{s}'\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            opts.output = arg["--output=".len..];
        } else if (std.mem.startsWith(u8, arg, "--fail-under=")) {
            const val = arg["--fail-under=".len..];
            opts.fail_under = std.fmt.parseFloat(f64, val) catch {
                std.debug.print("zig-cov: invalid --fail-under value '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--color=on")) {
            opts.color = true;
        } else if (std.mem.eql(u8, arg, "--color=off")) {
            opts.color = false;
        } else if (std.mem.startsWith(u8, arg, "--project=")) {
            opts.project = arg["--project=".len..];
        } else if (std.mem.startsWith(u8, arg, "--include=")) {
            try opts.include.append(gpa, arg["--include=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try opts.exclude.append(gpa, arg["--exclude=".len..]);
        } else {
            try opts.extra_args.append(gpa, arg);
        }
    }

    return opts;
}

// ---------------------------------------------------------------------------
// `zig-cov test` command
// ---------------------------------------------------------------------------

fn cmdTest(
    gpa: std.mem.Allocator,
    io: std.Io,
    parent_environ: *std.process.Environ.Map,
    raw_args: []const []const u8,
) !void {
    var opts = try parseOpts(gpa, raw_args);
    defer opts.deinit(gpa);

    std.debug.print("zig-cov: running tests with coverage...\n", .{});

    var run_result = try orchestrator.run(.{
        .project_dir = opts.project,
        .extra_args = opts.extra_args.items,
        .allocator = gpa,
        .io = io,
        .parent_environ = parent_environ,
    });
    defer run_result.deinit();

    if (run_result.zcov_files.len == 0) {
        std.debug.print("zig-cov: no .zcov files found — did you add the build.zig integration?\n", .{});
        std.process.exit(1);
    }

    try generateReport(gpa, io, run_result.zcov_files, &opts);
}

// ---------------------------------------------------------------------------
// `zig-cov report` command
// ---------------------------------------------------------------------------

fn cmdReport(gpa: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !void {
    if (raw_args.len == 0) {
        std.debug.print("zig-cov: report: no .zcov files specified\n", .{});
        std.process.exit(1);
    }

    var opts = try parseOpts(gpa, raw_args);
    defer opts.deinit(gpa);

    // Positional args (non-option args) are the .zcov files.
    const zcov_files = opts.extra_args.items;
    try generateReport(gpa, io, zcov_files, &opts);
}

// ---------------------------------------------------------------------------
// Core: build coverage model from .zcov files, generate report
// ---------------------------------------------------------------------------

fn generateReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    zcov_files: []const []const u8,
    opts: *const Opts,
) !void {
    var builder = coverage.Builder.init(gpa);
    defer builder.deinit();

    // Resolve the project directory to an absolute prefix for the default file
    // filter (only used when no --include is given). Best-effort: if it can't be
    // resolved, fall back to keeping everything.
    const project_prefix: ?[:0]u8 = if (opts.include.items.len == 0)
        (std.Io.Dir.cwd().realPathFileAlloc(io, opts.project, gpa) catch null)
    else
        null;
    defer if (project_prefix) |p| gpa.free(p);

    const filter = PathFilter{
        .project_prefix = project_prefix,
        .include = opts.include.items,
        .exclude = opts.exclude.items,
    };

    for (zcov_files) |zcov_path| {
        processZcovFile(gpa, io, zcov_path, &builder, filter) catch |err| {
            std.debug.print("zig-cov: warning: failed to process '{s}': {}\n", .{ zcov_path, err });
        };
    }

    var cov_data = try builder.build();
    defer cov_data.deinit();

    if (cov_data.files.len == 0) {
        const filtering = opts.include.items.len > 0 or opts.exclude.items.len > 0 or project_prefix != null;
        if (filtering) {
            std.debug.print("zig-cov: no files to report after filtering — adjust --include/--exclude/--project\n", .{});
        } else {
            std.debug.print("zig-cov: no coverage data could be resolved\n", .{});
        }
        std.process.exit(1);
    }

    // Write report using a buffer for stdout.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    switch (opts.format) {
        .summary => {
            const passes = try summary_report.write(stdout, &cov_data, .{
                .color = opts.color,
                .fail_under = opts.fail_under,
            });
            try stdout.flush();
            if (!passes) std.process.exit(1);
        },
        .lcov => {
            if (opts.output) |out_path| {
                var file = try std.Io.Dir.createFileAbsolute(io, out_path, .{});
                defer file.close(io);
                var file_buf: [4096]u8 = undefined;
                var file_fw = file.writer(io, &file_buf);
                try lcov_report.write(&file_fw.interface, &cov_data);
                try file_fw.interface.flush();
                std.debug.print("zig-cov: wrote LCOV to {s}\n", .{out_path});
            } else {
                try lcov_report.write(stdout, &cov_data);
                try stdout.flush();
            }
        },
        .json => {
            // Like lcov: stdout unless --output, so it can be piped to jq.
            if (opts.output) |out_path| {
                var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
                defer file.close(io);
                var file_buf: [4096]u8 = undefined;
                var file_fw = file.writer(io, &file_buf);
                try json_report.write(gpa, &file_fw.interface, &cov_data);
                try file_fw.interface.flush();
                std.debug.print("zig-cov: wrote JSON to {s}\n", .{out_path});
            } else {
                try json_report.write(gpa, stdout, &cov_data);
                try stdout.flush();
            }
        },
        .html => {
            // HTML is a file format; default to coverage.html in the cwd.
            // cwd().createFile handles both relative and absolute paths.
            const out_path = opts.output orelse "coverage.html";
            var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer file.close(io);
            var file_buf: [4096]u8 = undefined;
            var file_fw = file.writer(io, &file_buf);
            try html_report.write(gpa, io, &file_fw.interface, &cov_data);
            try file_fw.interface.flush();
            std.debug.print("zig-cov: wrote HTML report to {s}\n", .{out_path});
        },
    }
}

fn processZcovFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    zcov_path: []const u8,
    builder: *coverage.Builder,
    filter: PathFilter,
) !void {
    var data = try zcov_format.read(gpa, io, zcov_path);
    defer data.deinit();

    if (data.pcs.len == 0) return;

    std.debug.print("zig-cov: resolving {d} PCs from {s}...\n", .{ data.pcs.len, data.bin_path });

    var analysis = try resolver.analyze(
        gpa,
        io,
        data.bin_path,
        data.slide,
        data.pcs,
    );
    defer analysis.deinit();

    // Coverable lines first (establish misses), then hits (upgrade to executed).
    // Order does not matter — recordCoverable never lowers a count — but doing
    // coverable first keeps intent clear.
    for (analysis.coverable) |loc| {
        if (loc.line == 0) continue;
        if (!filter.accept(loc.file)) continue;
        try builder.recordCoverable(loc.file, loc.line);
    }
    for (analysis.hits) |loc| {
        if (loc.line == 0) continue; // unknown location
        if (!filter.accept(loc.file)) continue;
        try builder.recordHit(loc.file, loc.line);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse opts - format lcov" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{"--format=lcov"});
    defer opts.deinit(alloc);
    try std.testing.expectEqual(Format.lcov, opts.format);
}

test "parse opts - fail under" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{"--fail-under=75.5"});
    defer opts.deinit(alloc);
    try std.testing.expectApproxEqAbs(@as(f64, 75.5), opts.fail_under, 0.001);
}

test "parse opts - extra args after --" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{ "--", "-v", "--verbose" });
    defer opts.deinit(alloc);
    try std.testing.expectEqualStrings("-v", opts.extra_args.items[0]);
}

test "parse opts - include and exclude are repeatable" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{ "--include=src/", "--include=lib/", "--exclude=/std/" });
    defer opts.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), opts.include.items.len);
    try std.testing.expectEqualStrings("src/", opts.include.items[0]);
    try std.testing.expectEqualStrings("lib/", opts.include.items[1]);
    try std.testing.expectEqual(@as(usize, 1), opts.exclude.items.len);
    try std.testing.expectEqualStrings("/std/", opts.exclude.items[0]);
}

test "PathFilter default keeps only files under the project prefix" {
    const f = PathFilter{ .project_prefix = "/home/u/proj", .include = &.{}, .exclude = &.{} };
    try std.testing.expect(f.accept("/home/u/proj/src/main.zig"));
    try std.testing.expect(f.accept("/home/u/proj")); // the dir itself
    try std.testing.expect(!f.accept("/usr/lib/std/mem.zig")); // std lib dropped
    try std.testing.expect(!f.accept("/home/u/proj2/x.zig")); // sibling, not under prefix
    try std.testing.expect(f.accept("src/util.zig")); // relative = project-local
    try std.testing.expect(f.accept("clap/args.zig")); // relative subdir
}

test "PathFilter include overrides the project prefix" {
    const inc = [_][]const u8{"/std/"};
    const f = PathFilter{ .project_prefix = "/home/u/proj", .include = &inc, .exclude = &.{} };
    try std.testing.expect(f.accept("/usr/lib/std/mem.zig")); // matches an include
    try std.testing.expect(!f.accept("/home/u/proj/src/main.zig")); // no include match
}

test "PathFilter exclude wins over include and prefix" {
    const exc = [_][]const u8{"/generated/"};
    const f = PathFilter{ .project_prefix = "/home/u/proj", .include = &.{}, .exclude = &exc };
    try std.testing.expect(f.accept("/home/u/proj/src/main.zig"));
    try std.testing.expect(!f.accept("/home/u/proj/generated/x.zig"));
}

test "PathFilter with no prefix and no rules keeps everything" {
    const f = PathFilter{ .project_prefix = null, .include = &.{}, .exclude = &.{} };
    try std.testing.expect(f.accept("/anything/goes.zig"));
}
