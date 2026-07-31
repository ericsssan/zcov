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
    /// Where each instrumented block lives, parallel to the `block_pcs` passed
    /// in. This is a direct lookup of the block's own address, so callers can
    /// attribute exact block counts to files without any line inference.
    blocks: []ResolvedLocation,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Analysis) void {
        freeLocations(self.allocator, self.hits);
        freeLocations(self.allocator, self.coverable);
        freeLocations(self.allocator, self.blocks);
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
/// `block_pcs` is every instrumented block's runtime address and `counts` its
/// execution count, index for index — exactly what the runtime recorded. Blocks
/// with a zero count are real misses, and the addresses double as block
/// boundaries so an executed block can be expanded across the lines it spans.
pub fn analyze(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    slide: i64,
    block_pcs: []const u64,
    counts: []const u8,
) ResolveError!Analysis {
    // Executed subset, in the same address space as `block_pcs`.
    var hit_list: std.ArrayList(u64) = .empty;
    defer hit_list.deinit(allocator);
    if (block_pcs.len == counts.len) {
        for (block_pcs, counts) |pc, c| {
            if (c != 0) try hit_list.append(allocator, pc);
        }
    }
    const pcs = hit_list.items;
    var coverage: std.debug.Coverage = .init;
    defer coverage.deinit(allocator);
    var handle = try openBinary(io, bin_path);
    defer handle.dir.close(io);
    var info = try std.debug.Info.load(allocator, io, handle.path, &coverage, builtin.object_format, builtin.cpu.arch);
    defer info.deinit(allocator);

    // Locations of the blocks that actually executed.
    const hit_starts = if (pcs.len == 0)
        try allocator.alloc(ResolvedLocation, 0)
    else
        try resolvePcs(allocator, io, &info, &coverage, slide, pcs);
    defer freeLocations(allocator, hit_starts);

    const vaddrOf = struct {
        fn f(pc: u64, s: i64) u64 {
            return if (s >= 0) pc -| @as(u64, @intCast(s)) else pc + @as(u64, @intCast(-s));
        }
    }.f;

    // Warm-up pass. On Mach-O, translating an address can load a new object
    // file into `mf.ofiles`, and that map's values move when it grows — which
    // would invalidate the `*Dwarf` pointers used below as object identity.
    // Touching every address first means no later step inserts, so the pointers
    // taken afterwards stay valid.
    if (block_pcs.len > 0) {
        for (block_pcs) |pc| _ = translate(&info, allocator, io, vaddrOf(pc, slide));
    }

    // Best-effort: a malformed line program should not sink the whole report.
    var coverable_keys: std.ArrayList(AddrKey) = .empty;
    defer coverable_keys.deinit(allocator);
    const coverable = enumerateCoverable(allocator, &info, &coverable_keys) catch
        try allocator.alloc(ResolvedLocation, 0);
    errdefer freeLocations(allocator, coverable);

    // Location of every block, in the order they were passed in.
    const blocks = if (block_pcs.len == 0)
        try allocator.alloc(ResolvedLocation, 0)
    else
        try resolvePcs(allocator, io, &info, &coverage, slide, block_pcs);
    errdefer freeLocations(allocator, blocks);

    if (block_pcs.len == 0 or coverable.len != coverable_keys.items.len) {
        // No instrumentation found, an object format we cannot decode, or the
        // enumeration bailed part way: mark just the lines the PCs resolved to.
        const hits = try dupeLocations(allocator, hit_starts);
        return .{ .hits = hits, .coverable = coverable, .blocks = blocks, .allocator = allocator };
    }

    // Map both the executed PCs and every block start into DWARF address space.
    var exec_keys: std.ArrayList(AddrKey) = .empty;
    defer exec_keys.deinit(allocator);
    for (pcs) |pc| {
        if (translate(&info, allocator, io, vaddrOf(pc, slide))) |k| try exec_keys.append(allocator, k);
    }

    var block_keys: std.ArrayList(AddrKey) = .empty;
    defer block_keys.deinit(allocator);
    for (block_pcs) |pc| {
        if (translate(&info, allocator, io, vaddrOf(pc, slide))) |k| try block_keys.append(allocator, k);
    }

    const hits = try expandBlocks(allocator, exec_keys.items, block_keys.items, coverable, coverable_keys.items);
    return .{ .hits = hits, .coverable = coverable, .blocks = blocks, .allocator = allocator };
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

/// An address, qualified by which DWARF object it belongs to.
///
/// On ELF one DWARF covers the whole binary, so `obj` is constant. On Mach-O
/// debug info is split per object file and each uses its *own* address space, so
/// an address is only meaningful together with the object it came from.
const AddrKey = struct { obj: usize, addr: u64 };

/// An instrumented block start, and whether that block executed.
const Block = struct {
    addr: u64,
    executed: bool,

    fn lessThan(_: void, a: Block, b: Block) bool {
        return a.addr < b.addr;
    }
};

/// Translate a virtual address in the binary into the DWARF object and address
/// that describe it. Returns null when no debug info covers the address.
fn translate(info: *std.debug.Info, gpa: std.mem.Allocator, io: std.Io, vaddr: u64) ?AddrKey {
    switch (info.impl) {
        .elf => |*ef| {
            const d = &(ef.dwarf orelse return null);
            return .{ .obj = @intFromPtr(d), .addr = vaddr };
        },
        .macho => |*mf| {
            const res = mf.getDwarfForAddress(gpa, io, vaddr) catch return null;
            return .{ .obj = @intFromPtr(res[0]), .addr = res[1] };
        },
    }
}

/// Expand executed blocks to every line they cover.
///
/// Instrumentation marks block *starts*, so a recorded PC only identifies the
/// first line of a run. A line's code belongs to the last block starting at or
/// before its address; if that block executed, the line executed.
///
/// This must be done in address space, not line space: a Debug build emits
/// panic/overflow handlers that carry the *same line* as the arithmetic they
/// guard but live at distant addresses. Comparing by line lets an unexecuted
/// panic handler shadow the very line it protects.
fn expandBlocks(
    allocator: std.mem.Allocator,
    exec_keys: []const AddrKey,
    block_keys: []const AddrKey,
    coverable: []const ResolvedLocation,
    coverable_keys: []const AddrKey,
) ![]ResolvedLocation {
    // obj -> sorted block starts, flagged with whether they executed.
    var by_obj = std.AutoHashMap(usize, std.ArrayList(Block)).init(allocator);
    defer {
        var it = by_obj.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        by_obj.deinit();
    }

    for (block_keys) |b| {
        const gop = try by_obj.getOrPut(b.obj);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, .{ .addr = b.addr, .executed = false });
    }

    var it = by_obj.valueIterator();
    while (it.next()) |list| std.mem.sort(Block, list.items, {}, Block.lessThan);

    // Flag the blocks that ran. An executed PC is itself a block start, so it
    // matches an entry exactly.
    for (exec_keys) |e| {
        const list = by_obj.getPtr(e.obj) orelse continue;
        const idx = std.sort.lowerBound(Block, list.items, e.addr, struct {
            fn order(ctx: u64, item: Block) std.math.Order {
                return std.math.order(ctx, item.addr);
            }
        }.order);
        if (idx < list.items.len and list.items[idx].addr == e.addr) list.items[idx].executed = true;
    }

    var out: std.ArrayList(ResolvedLocation) = .empty;
    errdefer {
        for (out.items) |loc| allocator.free(loc.file);
        out.deinit(allocator);
    }

    for (coverable, coverable_keys) |row, key| {
        const list = by_obj.get(key.obj) orelse continue;
        const idx = std.sort.upperBound(Block, list.items, key.addr, struct {
            fn order(ctx: u64, item: Block) std.math.Order {
                return std.math.order(ctx, item.addr);
            }
        }.order);
        if (idx == 0) continue; // before the first instrumented block
        if (!list.items[idx - 1].executed) continue;
        try out.append(allocator, .{
            .file = try allocator.dupe(u8, row.file),
            .line = row.line,
            .column = row.column,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn dupeLocations(allocator: std.mem.Allocator, locs: []const ResolvedLocation) ![]ResolvedLocation {
    var out: std.ArrayList(ResolvedLocation) = .empty;
    errdefer {
        for (out.items) |loc| allocator.free(loc.file);
        out.deinit(allocator);
    }
    for (locs) |loc| {
        if (loc.line == 0) continue;
        try out.append(allocator, .{
            .file = try allocator.dupe(u8, loc.file),
            .line = loc.line,
            .column = loc.column,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Walk every compile unit's line-number table and collect one ResolvedLocation
/// per coverable source line. Paths are reconstructed from the same DWARF
/// directory/file strings the address resolver uses, so they match hit paths.
fn enumerateCoverable(
    allocator: std.mem.Allocator,
    info: *std.debug.Info,
    keys: *std.ArrayList(AddrKey),
) ![]ResolvedLocation {
    var out: std.ArrayList(ResolvedLocation) = .empty;
    errdefer {
        for (out.items) |loc| allocator.free(loc.file);
        out.deinit(allocator);
    }

    switch (info.impl) {
        .elf => |*ef| try enumerateDwarf(allocator, &ef.dwarf.?, ef.endian, &out, keys),
        .macho => |*mf| {
            // Mach-O debug info is split per object file, loaded lazily during
            // address resolution; endian is little for these.
            for (mf.ofiles.values()) |*maybe_of| {
                const of = &(maybe_of.* catch continue);
                enumerateDwarf(allocator, &of.dwarf, .little, &out, keys) catch continue;
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
    keys: *std.ArrayList(AddrKey),
) !void {
    const obj = @intFromPtr(d);
    for (d.compile_unit_list.items) |*cu| {
        d.populateSrcLocCache(allocator, endian, cu) catch continue;
        const slc = &cu.src_loc_cache.?;
        // DWARF < 5 file indices are 1-based; >= 5 are 0-based.
        const shift: u32 = if (slc.version < 5) 1 else 0;
        for (slc.line_table.keys(), slc.line_table.values()) |addr, entry| {
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
            try keys.append(allocator, .{ .obj = obj, .addr = addr });
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
