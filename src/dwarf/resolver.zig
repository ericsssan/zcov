//! Resolves PC addresses to source file:line locations using DWARF debug info,
//! and enumerates all coverable lines from the DWARF line-number tables.
//!
//! Uses Zig's standard library (std.debug.Info) which supports ELF (Linux)
//! and Mach-O (macOS) out of the box.

const std = @import("std");
const builtin = @import("builtin");

pub const ResolvedLocation = struct {
    /// Absolute or relative path to the source file.
    file: []const u8,
    /// 1-based line number (0 = unknown).
    line: u32,
    /// 1-based column (0 = unknown).
    column: u32,
};

pub const ResolveError = std.debug.Info.LoadError || std.debug.Info.ResolveAddressesError || error{
    OutOfMemory,
    NoDebugInfo,
};

/// Resolves a batch of PC addresses (runtime, with ASLR slide applied) to
/// source locations.
///
/// `slide` is the ASLR slide stored in the .zcov file: subtract it from
/// each runtime PC to get the virtual address in the binary.
///
/// `pcs` should ideally be sorted ascending for best performance.
///
/// Returns a slice of ResolvedLocation parallel to `pcs`. Caller owns the
/// result; free with `allocator.free(result)` (and free each non-"<unknown>"
/// `.file`).
pub fn resolveAddresses(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    slide: i64,
    pcs: []const u64,
) ResolveError![]ResolvedLocation {
    if (pcs.len == 0) return &.{};

    // coverage and info must live in this frame: info.coverage points at coverage.
    var coverage: std.debug.Coverage = .init;
    defer coverage.deinit(allocator);
    var handle = try openBinary(io, bin_path);
    defer handle.dir.close(io);
    var info = try std.debug.Info.load(allocator, io, handle.path, &coverage, builtin.object_format, builtin.cpu.arch);
    defer info.deinit(allocator);

    return resolvePcs(allocator, io, &info, &coverage, slide, pcs);
}

/// Result of `analyze`: resolved hits (parallel to the input PCs) plus every
/// coverable line found in the binary's DWARF line tables.
pub const Analysis = struct {
    /// One entry per input PC, in input order.
    hits: []ResolvedLocation,
    /// One entry per coverable source line (whether hit or not). Feeding these
    /// through `Builder.recordCoverable` turns unhit lines into real misses.
    coverable: []ResolvedLocation,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Analysis) void {
        freeLocations(self.allocator, self.hits);
        freeLocations(self.allocator, self.coverable);
        self.* = undefined;
    }
};

/// Resolve the hit PCs AND enumerate every coverable line from the binary's
/// DWARF line-number tables, in a single load of the debug info.
///
/// On ELF the whole binary is enumerated. On Mach-O debug info is split across
/// per-object-file DWARF that is loaded lazily while resolving `pcs`, so only
/// object files touched by `pcs` are enumerated — i.e. coverable lines are
/// reported for files that had at least one hit.
pub fn analyze(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    slide: i64,
    pcs: []const u64,
) ResolveError!Analysis {
    var coverage: std.debug.Coverage = .init;
    defer coverage.deinit(allocator);
    var handle = try openBinary(io, bin_path);
    defer handle.dir.close(io);
    var info = try std.debug.Info.load(allocator, io, handle.path, &coverage, builtin.object_format, builtin.cpu.arch);
    defer info.deinit(allocator);

    const hits = if (pcs.len == 0)
        try allocator.alloc(ResolvedLocation, 0)
    else
        try resolvePcs(allocator, io, &info, &coverage, slide, pcs);
    errdefer freeLocations(allocator, hits);

    // Best-effort: a malformed line program should not sink the whole report.
    const coverable = enumerateCoverable(allocator, io, &info) catch
        try allocator.alloc(ResolvedLocation, 0);

    return .{ .hits = hits, .coverable = coverable, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

const OpenedBinary = struct { dir: std.Io.Dir, path: std.Build.Cache.Path };

fn openBinary(io: std.Io, bin_path: []const u8) !OpenedBinary {
    const dirname = std.fs.path.dirname(bin_path) orelse ".";
    const dir_handle = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    return .{
        .dir = dir_handle,
        .path = .{
            .root_dir = .{
                .handle = dir_handle,
                // Must be non-null so Cache.Path.toString() produces the full
                // absolute path. With path=null, toString() emits only the
                // basename, which can accidentally open a same-named directory
                // in CWD and cause mmap(EINVAL) on macOS.
                .path = dirname,
            },
            .sub_path = std.fs.path.basename(bin_path),
        },
    };
}

/// Resolve `pcs` against already-loaded debug info. Returns locations in input
/// order.
fn resolvePcs(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *std.debug.Info,
    coverage: *std.debug.Coverage,
    slide: i64,
    pcs: []const u64,
) ResolveError![]ResolvedLocation {
    // Convert runtime addresses to virtual addresses (subtract ASLR slide).
    const virtual_pcs = try allocator.alloc(u64, pcs.len);
    defer allocator.free(virtual_pcs);
    for (pcs, virtual_pcs) |pc, *vpc| {
        vpc.* = if (slide >= 0)
            pc -| @as(u64, @intCast(slide))
        else
            pc + @as(u64, @intCast(-slide));
    }

    // Sort for resolveAddresses (requires ascending order). Keep a sort index to
    // map results back to original order.
    const IndexedPc = struct { pc: u64, orig_idx: usize };
    const indexed = try allocator.alloc(IndexedPc, pcs.len);
    defer allocator.free(indexed);
    for (virtual_pcs, 0..) |pc, i| indexed[i] = .{ .pc = pc, .orig_idx = i };
    std.mem.sort(IndexedPc, indexed, {}, struct {
        fn lt(_: void, a: IndexedPc, b: IndexedPc) bool {
            return a.pc < b.pc;
        }
    }.lt);

    const sorted_pcs = try allocator.alloc(u64, pcs.len);
    defer allocator.free(sorted_pcs);
    for (indexed, sorted_pcs) |ip, *sp| sp.* = ip.pc;

    const raw_locs = try allocator.alloc(std.debug.Coverage.SourceLocation, pcs.len);
    defer allocator.free(raw_locs);
    try info.resolveAddresses(allocator, io, sorted_pcs, raw_locs);

    const result = try allocator.alloc(ResolvedLocation, pcs.len);
    errdefer allocator.free(result);

    const sorted_results = try allocator.alloc(ResolvedLocation, pcs.len);
    defer allocator.free(sorted_results);
    for (raw_locs, 0..) |raw, i| {
        sorted_results[i] = try convertSourceLocation(coverage, allocator, raw);
    }
    for (indexed, sorted_results) |ip, sr| {
        result[ip.orig_idx] = sr;
    }

    return result;
}

/// Walk every compile unit's line-number table and collect one ResolvedLocation
/// per coverable source line. Paths are reconstructed from the same DWARF
/// directory/file strings the address resolver uses, so they match hit paths.
fn enumerateCoverable(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *std.debug.Info,
) ![]ResolvedLocation {
    _ = io;
    var out: std.ArrayList(ResolvedLocation) = .empty;
    errdefer {
        for (out.items) |loc| allocator.free(loc.file);
        out.deinit(allocator);
    }

    switch (info.impl) {
        .elf => |*ef| try enumerateDwarf(allocator, &ef.dwarf.?, ef.endian, &out),
        .macho => |*mf| {
            // Mach-O debug info is split per object file, loaded lazily during
            // address resolution; endian is little for these.
            for (mf.ofiles.values()) |*maybe_of| {
                const of = &(maybe_of.* catch continue);
                enumerateDwarf(allocator, &of.dwarf, .little, &out) catch continue;
            }
        },
    }

    return out.toOwnedSlice(allocator);
}

fn enumerateDwarf(
    allocator: std.mem.Allocator,
    d: *std.debug.Dwarf,
    endian: std.builtin.Endian,
    out: *std.ArrayList(ResolvedLocation),
) !void {
    for (d.compile_unit_list.items) |*cu| {
        d.populateSrcLocCache(allocator, endian, cu) catch continue;
        const slc = &cu.src_loc_cache.?;
        // DWARF < 5 file indices are 1-based; >= 5 are 0-based.
        const shift: u32 = if (slc.version < 5) 1 else 0;
        for (slc.line_table.values()) |entry| {
            if (entry.isInvalid()) continue; // end_sequence marker
            if (entry.line == 0) continue;
            if (entry.file < shift) continue;
            const fi = entry.file - shift;
            if (fi >= slc.files.len) continue;
            const fe = slc.files[fi];
            if (fe.dir_index >= slc.directories.len) continue;
            const dir = slc.directories[fe.dir_index].path;
            const path = if (dir.len > 0)
                try std.fs.path.join(allocator, &.{ dir, fe.path })
            else
                try allocator.dupe(u8, fe.path);
            try out.append(allocator, .{ .file = path, .line = entry.line, .column = entry.column });
        }
    }
}

fn freeLocations(allocator: std.mem.Allocator, locs: []ResolvedLocation) void {
    for (locs) |loc| {
        if (!std.mem.eql(u8, loc.file, "<unknown>")) allocator.free(loc.file);
    }
    allocator.free(locs);
}

fn convertSourceLocation(
    coverage: *std.debug.Coverage,
    allocator: std.mem.Allocator,
    raw: std.debug.Coverage.SourceLocation,
) !ResolvedLocation {
    if (raw.file == .invalid) {
        return .{ .file = "<unknown>", .line = 0, .column = 0 };
    }

    const file = coverage.fileAt(raw.file);
    const basename = coverage.stringAt(file.basename);

    // Reconstruct the full path: directory + "/" + basename.
    const dir_idx = file.directory_index;
    const dir_key = coverage.directories.keys()[dir_idx];
    const dir_name = coverage.stringAt(dir_key);

    const full_path = if (dir_name.len > 0)
        try std.fs.path.join(allocator, &.{ dir_name, basename })
    else
        try allocator.dupe(u8, basename);

    return .{
        .file = full_path,
        .line = raw.line,
        .column = raw.column,
    };
}
