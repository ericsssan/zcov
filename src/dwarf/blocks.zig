//! Enumerates the instrumented basic blocks of a coverage-instrumented binary.
//!
//! Why this exists
//! ---------------
//! `-fsanitize-coverage=trace-pc-guard` instruments *basic blocks*, not lines:
//! a run of straight-line statements gets one guard, so the runtime records one
//! PC for the whole run. Marking only the line at that PC produces a wild
//! under-count — code where every line executes reports ~17%.
//!
//! The fix is to expand an executed block to every line it spans. A block runs
//! from its own guard call to the next one, so we need the address of *every*
//! instrumented block, including those that never executed. LLVM can emit that
//! as a PC table, but Zig's build system does not expose the flag, so instead we
//! recover it from the binary: every instrumented block begins with a call to
//! `__sanitizer_cov_trace_pc_guard`, and the runtime records the return address
//! of that call, so scanning the text section for those call sites yields
//! exactly the PC values the runtime reports.
//!
//! Only the two architectures zig-cov supports are decoded (aarch64, x86_64).

const std = @import("std");

/// A call site found in the text section, expressed as the PC the runtime would
/// record for it: the address of the instruction *after* the call.
pub const BlockPc = u64;

pub const Arch = enum { aarch64, x86_64 };

/// Scan `text` for calls to `guard_addr` and return the return-address of each,
/// ascending. `text_vaddr` is the virtual address of `text[0]`.
///
/// Caller owns the result.
pub fn scanCallSites(
    gpa: std.mem.Allocator,
    arch: Arch,
    text: []const u8,
    text_vaddr: u64,
    guard_addr: u64,
) ![]BlockPc {
    var out: std.ArrayList(BlockPc) = .empty;
    errdefer out.deinit(gpa);

    switch (arch) {
        .aarch64 => {
            // BL: bits 31..26 = 0b100101, imm26 = signed word offset.
            var i: usize = 0;
            while (i + 4 <= text.len) : (i += 4) {
                const word = std.mem.readInt(u32, text[i..][0..4], .little);
                if (word >> 26 != 0b100101) continue;
                const imm26: i64 = @as(i26, @bitCast(@as(u26, @truncate(word))));
                const site = text_vaddr + i;
                const target = @as(i64, @intCast(site)) + imm26 * 4;
                if (target >= 0 and @as(u64, @intCast(target)) == guard_addr) {
                    try out.append(gpa, site + 4); // return address
                }
            }
        },
        .x86_64 => {
            // CALL rel32: E8 <disp32>, target = address of next instruction + disp.
            // x86 is variable length, so a byte scan can in principle match data;
            // requiring the target to land exactly on the guard makes that
            // vanishingly unlikely.
            var i: usize = 0;
            while (i + 5 <= text.len) : (i += 1) {
                if (text[i] != 0xE8) continue;
                const disp = std.mem.readInt(i32, text[i + 1 ..][0..4], .little);
                const next = text_vaddr + i + 5;
                const target = @as(i64, @intCast(next)) + disp;
                if (target >= 0 and @as(u64, @intCast(target)) == guard_addr) {
                    try out.append(gpa, next); // return address
                }
            }
        },
    }

    const slice = try out.toOwnedSlice(gpa);
    std.mem.sort(BlockPc, slice, {}, std.sort.asc(BlockPc));
    return slice;
}

/// Largest binary we are willing to scan.
const max_binary_bytes = 512 * 1024 * 1024;

/// Enumerate every instrumented block in the binary at `bin_path`.
///
/// Returns an empty slice when the binary holds no coverage instrumentation, or
/// when its format/architecture is not one we can decode — callers then fall
/// back to line-at-PC marking rather than failing the whole report.
pub fn scanBinary(gpa: std.mem.Allocator, io: std.Io, bin_path: []const u8) ![]BlockPc {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, bin_path, gpa, std.Io.Limit.limited(max_binary_bytes)) catch
        return gpa.alloc(BlockPc, 0);
    defer gpa.free(bytes);

    const info = parseObject(bytes) orelse return gpa.alloc(BlockPc, 0);
    return scanCallSites(gpa, info.arch, info.text, info.text_vaddr, info.guard_addr);
}

const ObjectInfo = struct {
    arch: Arch,
    text: []const u8,
    text_vaddr: u64,
    guard_addr: u64,
};

fn parseObject(bytes: []const u8) ?ObjectInfo {
    if (bytes.len < 4) return null;
    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (std.mem.eql(u8, bytes[0..4], "\x7fELF")) return parseElf(bytes);
    if (magic == std.macho.MH_MAGIC_64) return parseMacho(bytes);
    return null;
}

/// Read a struct from `bytes` at `off`, or null if it would run past the end.
fn peek(comptime T: type, bytes: []const u8, off: usize) ?T {
    if (off + @sizeOf(T) > bytes.len) return null;
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), bytes[off..][0..@sizeOf(T)]);
    return v;
}

fn cstr(bytes: []const u8, off: usize) []const u8 {
    if (off >= bytes.len) return "";
    const rest = bytes[off..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
}

fn parseElf(bytes: []const u8) ?ObjectInfo {
    const hdr = peek(std.elf.Elf64_Ehdr, bytes, 0) orelse return null;
    const arch: Arch = switch (hdr.e_machine) {
        .X86_64 => .x86_64,
        .AARCH64 => .aarch64,
        else => return null,
    };
    if (hdr.e_shoff == 0 or hdr.e_shentsize < @sizeOf(std.elf.Elf64_Shdr)) return null;

    const shdr = struct {
        fn at(b: []const u8, h: std.elf.Elf64_Ehdr, i: usize) ?std.elf.Elf64_Shdr {
            return peek(std.elf.Elf64_Shdr, b, @intCast(h.e_shoff + i * h.e_shentsize));
        }
    };

    const shstr = shdr.at(bytes, hdr, hdr.e_shstrndx) orelse return null;
    if (shstr.sh_offset + shstr.sh_size > bytes.len) return null;
    const shstrtab = bytes[@intCast(shstr.sh_offset)..][0..@intCast(shstr.sh_size)];

    var text: ?ObjectInfo = null;
    var guard_addr: ?u64 = null;

    var i: usize = 0;
    while (i < hdr.e_shnum) : (i += 1) {
        const sh = shdr.at(bytes, hdr, i) orelse continue;
        const name = cstr(shstrtab, sh.sh_name);
        if (std.mem.eql(u8, name, ".text")) {
            if (sh.sh_offset + sh.sh_size > bytes.len) continue;
            text = .{
                .arch = arch,
                .text = bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)],
                .text_vaddr = sh.sh_addr,
                .guard_addr = 0,
            };
        } else if (sh.sh_type == std.elf.SHT_SYMTAB) {
            const strsh = shdr.at(bytes, hdr, sh.sh_link) orelse continue;
            if (strsh.sh_offset + strsh.sh_size > bytes.len) continue;
            if (sh.sh_offset + sh.sh_size > bytes.len) continue;
            const strtab = bytes[@intCast(strsh.sh_offset)..][0..@intCast(strsh.sh_size)];
            const n = sh.sh_size / @sizeOf(std.elf.Elf64_Sym);
            var s: usize = 0;
            while (s < n) : (s += 1) {
                const sym = peek(std.elf.Elf64_Sym, bytes, @intCast(sh.sh_offset + s * @sizeOf(std.elf.Elf64_Sym))) orelse continue;
                if (std.mem.eql(u8, cstr(strtab, sym.st_name), guard_symbol_elf)) {
                    guard_addr = sym.st_value;
                    break;
                }
            }
        }
    }

    var out = text orelse return null;
    out.guard_addr = guard_addr orelse return null;
    return out;
}

fn parseMacho(bytes: []const u8) ?ObjectInfo {
    const hdr = peek(std.macho.mach_header_64, bytes, 0) orelse return null;
    const arch: Arch = switch (hdr.cputype) {
        std.macho.CPU_TYPE_ARM64 => .aarch64,
        std.macho.CPU_TYPE_X86_64 => .x86_64,
        else => return null,
    };

    var text: ?ObjectInfo = null;
    var guard_addr: ?u64 = null;

    var off: usize = @sizeOf(std.macho.mach_header_64);
    var c: usize = 0;
    while (c < hdr.ncmds) : (c += 1) {
        const lc = peek(std.macho.load_command, bytes, off) orelse break;
        if (lc.cmdsize == 0) break;
        switch (lc.cmd) {
            .SEGMENT_64 => {
                const seg = peek(std.macho.segment_command_64, bytes, off) orelse break;
                var s: usize = 0;
                while (s < seg.nsects) : (s += 1) {
                    const sec_off = off + @sizeOf(std.macho.segment_command_64) + s * @sizeOf(std.macho.section_64);
                    const sec = peek(std.macho.section_64, bytes, sec_off) orelse break;
                    if (std.mem.eql(u8, sec.sectName(), "__text")) {
                        if (@as(usize, sec.offset) + @as(usize, @intCast(sec.size)) > bytes.len) continue;
                        text = .{
                            .arch = arch,
                            .text = bytes[sec.offset..][0..@intCast(sec.size)],
                            .text_vaddr = sec.addr,
                            .guard_addr = 0,
                        };
                    }
                }
            },
            .SYMTAB => {
                const st = peek(std.macho.symtab_command, bytes, off) orelse break;
                if (@as(usize, st.stroff) + @as(usize, st.strsize) > bytes.len) break;
                const strtab = bytes[st.stroff..][0..st.strsize];
                var s: usize = 0;
                while (s < st.nsyms) : (s += 1) {
                    const sym = peek(std.macho.nlist_64, bytes, st.symoff + s * @sizeOf(std.macho.nlist_64)) orelse break;
                    if (std.mem.eql(u8, cstr(strtab, sym.n_strx), guard_symbol_macho)) {
                        guard_addr = sym.n_value;
                        break;
                    }
                }
            },
            else => {},
        }
        off += lc.cmdsize;
    }

    var out = text orelse return null;
    out.guard_addr = guard_addr orelse return null;
    return out;
}

const guard_symbol_elf = "__sanitizer_cov_trace_pc_guard";
/// Mach-O prefixes C symbols with an underscore.
const guard_symbol_macho = "___sanitizer_cov_trace_pc_guard";

/// Index of the block containing `pc`, i.e. the last block whose start is <= pc.
/// Returns null when `pc` precedes every block.
pub fn blockIndexOf(blocks: []const BlockPc, pc: u64) ?usize {
    const i = std.sort.upperBound(BlockPc, blocks, pc, struct {
        fn order(ctx: u64, item: BlockPc) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.order);
    return if (i == 0) null else i - 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Encode an aarch64 `bl` from `site` to `target`.
fn encodeBl(site: u64, target: u64) u32 {
    const off = (@as(i64, @intCast(target)) - @as(i64, @intCast(site))) >> 2;
    return (0b100101 << 26) | @as(u32, @as(u26, @truncate(@as(u64, @bitCast(off)))));
}

test "aarch64: finds bl call sites targeting the guard and reports return addresses" {
    const alloc = std.testing.allocator;
    const base: u64 = 0x1000;
    const guard: u64 = 0x2000;

    var text: [16]u8 = undefined;
    // [0] bl -> guard, [1] nop, [2] bl -> elsewhere, [3] bl -> guard
    std.mem.writeInt(u32, text[0..4], encodeBl(base + 0, guard), .little);
    std.mem.writeInt(u32, text[4..8], 0xd503201f, .little); // nop
    std.mem.writeInt(u32, text[8..12], encodeBl(base + 8, 0x3000), .little);
    std.mem.writeInt(u32, text[12..16], encodeBl(base + 12, guard), .little);

    const pcs = try scanCallSites(alloc, .aarch64, &text, base, guard);
    defer alloc.free(pcs);

    // Return addresses: site + 4. The call to 0x3000 must be ignored.
    try std.testing.expectEqualSlices(u64, &.{ base + 4, base + 16 }, pcs);
}

test "x86_64: finds call rel32 sites targeting the guard" {
    const alloc = std.testing.allocator;
    const base: u64 = 0x400000;
    const guard: u64 = 0x401000;

    var text: [20]u8 = @splat(0x90); // nops
    // call at offset 0: next = base+5, disp = guard - next
    text[0] = 0xE8;
    std.mem.writeInt(i32, text[1..5], @intCast(@as(i64, @intCast(guard)) - @as(i64, @intCast(base + 5))), .little);
    // call at offset 10 targeting something else
    text[10] = 0xE8;
    std.mem.writeInt(i32, text[11..15], 0x20, .little);

    const pcs = try scanCallSites(alloc, .x86_64, &text, base, guard);
    defer alloc.free(pcs);

    try std.testing.expectEqualSlices(u64, &.{base + 5}, pcs);
}

test "scan returns nothing when the guard is never called" {
    const alloc = std.testing.allocator;
    var text: [8]u8 = undefined;
    std.mem.writeInt(u32, text[0..4], encodeBl(0x1000, 0x9000), .little);
    std.mem.writeInt(u32, text[4..8], 0xd503201f, .little);

    const pcs = try scanCallSites(alloc, .aarch64, &text, 0x1000, 0x2000);
    defer alloc.free(pcs);
    try std.testing.expectEqual(@as(usize, 0), pcs.len);
}

test "blockIndexOf locates the enclosing block" {
    const blocks = [_]BlockPc{ 100, 200, 300 };
    try std.testing.expectEqual(@as(?usize, null), blockIndexOf(&blocks, 50));
    try std.testing.expectEqual(@as(?usize, 0), blockIndexOf(&blocks, 100));
    try std.testing.expectEqual(@as(?usize, 0), blockIndexOf(&blocks, 150));
    try std.testing.expectEqual(@as(?usize, 1), blockIndexOf(&blocks, 200));
    try std.testing.expectEqual(@as(?usize, 2), blockIndexOf(&blocks, 5000));
}
