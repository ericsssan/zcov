# zig-cov

[![CI](https://github.com/ericsssan/zcov/actions/workflows/ci.yml/badge.svg)](https://github.com/ericsssan/zcov/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Cross-platform code coverage for Zig. One command, no external dependencies.

```
zig-cov test
```

```
Filename                        Lines      Hit    Miss   Coverage
----------------------------------------------------------------
src/main.zig                       84       71      13      84.5%
src/coverage.zig                   58       58       0     100.0%
src/report/lcov.zig                32       32       0     100.0%
src/report/summary.zig             61       55       6      90.2%
----------------------------------------------------------------
Total                             235      216      19      91.9%
```

## Why

Zig has no native coverage tool. [Issue #352](https://github.com/ziglang/zig/issues/352) has been open since May 2017. Existing workarounds are fragmented:

| Tool | Platform | Requires |
|------|----------|---------|
| kcov | Linux; macOS works but requires build-from-source, code signing, and breaks on DWARF/clang updates; ARM64 untested | Homebrew deps + codesign |
| grindcov | Linux only | Valgrind (no ARM64 support) |

None work on all platforms. None produce standard output formats without configuration. Apple Silicon is the worst-served target — Valgrind has no ARM64 support, kcov's macOS support is partial.

zig-cov is written in Zig, ships as a single binary, and works on Linux and macOS without any additional tools.

## How it works

zig-cov uses LLVM's SanitizerCoverage (`-fsanitize-coverage=trace-pc-guard`), the same infrastructure Zig's built-in fuzzer uses. The runtime library provides custom `__sanitizer_cov_trace_pc_guard` callbacks that:

1. Record a 1-bit hit in an atomic bitmap per control-flow edge
2. Capture the return address (PC) on the first hit
3. Write a `.zcov` binary file on process exit

The CLI then maps those PC addresses back to `file:line` locations using DWARF debug information via `std.debug.Info` (supports ELF on Linux, Mach-O on macOS).

### Why SanitizerCoverage over alternatives

| | SanitizerCoverage | LLVM source-based | ptrace (kcov) | Source rewriting |
|-|:-----------------:|:-----------------:|:-------------:|:----------------:|
| Compile overhead | < 2x | 14x | none | needs Zig parser |
| Runtime overhead | 5–15% | 5–30% | 10–50% | ~3% |
| Cross-platform | yes | yes | platform-specific | yes |
| Accuracy | line-level | expression-level | line-level | line-level |
| Uses existing Zig infra | yes | needs flag exposure | external tool | full parser needed |

The hot-path callback runs in **~2 ns** on Apple Silicon (measured; target was ≤5 ns).

## Installation

```sh
git clone https://codeberg.org/ziglang/zig-coverage-tool
cd zig-coverage-tool
zig build -Doptimize=ReleaseSafe
# Produces: zig-out/bin/zig-cov  and  zig-out/lib/zig-cov-rt.o
```

Copy both to a directory on your `$PATH` (they must stay in the same directory).

## Setup

Add to your `build.zig`:

```zig
const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
const rt_path  = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;

if (coverage) {
    unit_tests.use_llvm = true;                     // required (see note below)
    unit_tests.sanitize_coverage_trace_pc_guard = true;
    unit_tests.root_module.link_libc = true;        // required (see note below)
    if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
}
```

That's the only change needed. zig-cov passes the flags automatically when you use `zig-cov test`.

> **Why `use_llvm` and `link_libc`?** Two portability requirements, both of which macOS happens to satisfy by default but Linux does not:
> - `use_llvm`: `sanitize-coverage` is only emitted by the LLVM backend. On x86_64 Linux the Debug default is the self-hosted backend, which silently produces **no** instrumentation, so forcing LLVM is required.
> - `link_libc`: the runtime writes the `.zcov` from a libc `atexit` handler (and uses `fopen`). Without libc, `std.process.exit` exits via a raw syscall on Linux and the handler never runs.
>
> `rt_path` points at `zig-cov-rt.o` — a relocatable object, so the sancov symbols are force-included (a static archive gets dropped by `lld`).

## Usage

### Run tests and generate a report

```sh
# Summary to stdout (default)
zig-cov test

# LCOV format (for Codecov, Coveralls, lcov --genhtml, etc.)
zig-cov test --format=lcov --output=coverage.lcov

# Fail the build if coverage drops below a threshold
zig-cov test --fail-under=80

# Pass extra args to zig build
zig-cov test -- --summary all
```

### Generate a report from existing .zcov files

```sh
zig-cov report coverage-1234.zcov
zig-cov report --format=lcov *.zcov
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--format=summary\|lcov` | `summary` | Output format |
| `--output=<path>` | stdout | Output file (summary goes to stdout, lcov defaults to `coverage.lcov`) |
| `--fail-under=<pct>` | `0` | Exit 1 if line coverage is below this percentage |
| `--color=on\|off\|auto` | `auto` | Terminal colour in summary output |
| `--project=<dir>` | `.` | Directory containing `build.zig` |

## .zcov file format

`.zcov` is a simple binary format written by the runtime on process exit:

```
Magic:      [4]u8  = "ZCOV"
Version:    u32    = 1  (little-endian throughout)
Slide:      i64    = ASLR slide (subtract from PCs to get virtual addresses)
NumPCs:     u32    = number of hit edge PCs
BinPathLen: u16    = byte length of binary path
BinPath:    [BinPathLen]u8
PCs:        [NumPCs]u64
```

Multiple `.zcov` files (one per test binary invocation) are merged by the CLI before generating the report.

## Performance

Measured on Apple Silicon (M-series, `ReleaseSafe`):

| Metric | Result | Target |
|--------|--------|--------|
| sancov hot-path (first hit) | 2 ns/call | ≤ 5 ns |
| `recordHit` (100 K calls) | 20 ns/call | — |
| LCOV write (10 K files) | < 1 ms | ≤ 5 000 ms |
| summary write (10 K files) | 3 ms | ≤ 1 000 ms |

Run the benchmarks yourself:

```sh
zig build bench
```

## Limitations

- **Requires the LLVM backend.** `sanitize_coverage_trace_pc_guard` is only emitted by the LLVM backend. Zig increasingly defaults to the self-hosted backend (already the case for Debug on x86_64), which silently produces no instrumentation, so the setup snippet forces it with `use_llvm = true`. This also means `Debug` or `ReleaseSafe` only — `ReleaseFast`/`ReleaseSmall` are not supported. Coverage is inherently a debug-time activity, so this is not expected to be a practical constraint. Tracked upstream: [#23242](https://github.com/ziglang/zig/issues/23242).
- **Line-level accuracy.** The fast mode reports line coverage, not branch/expression coverage. A line is marked hit if any control-flow edge on that line executed.
- **No Windows support yet.** Three concrete gaps need fixing before Windows works:
  1. `std.debug.Info.load` only handles `.elf` and `.macho` — `.coff` (Windows PE) hits an `UnsupportedDebugInfo` error at runtime (`src/dwarf/resolver.zig`)
  2. The temp directory is hardcoded to `/tmp/zig-cov-{pid}` — Windows has no `/tmp/` (`src/build_orchestrator.zig:128`)
  3. Finding the Zig executable uses `which zig` — Windows uses `where` instead (`src/build_orchestrator.zig:143`)

  Planned for v1.0.
- **Lazy compilation.** Zig only compiles functions that are referenced. Unreferenced functions produce no object code and are invisible to all coverage tools, not just zig-cov.

## Project structure

```
src/
├── main.zig                  CLI entry point
├── build_orchestrator.zig    Invokes zig build test with coverage flags
├── coverage.zig              Unified coverage data model
├── dwarf/
│   └── resolver.zig          Batch PC → file:line resolver (ELF + Mach-O)
├── report/
│   ├── lcov.zig              LCOV tracefile writer
│   └── summary.zig           Terminal table writer
├── runtime/
│   ├── sancov.zig            __sanitizer_cov_trace_pc_guard callbacks
│   └── zcov_format.zig       .zcov binary format read/write
└── bench.zig                 Synthetic performance benchmarks
```

## Roadmap

- [ ] HTML report with Zig syntax highlighting
- [ ] Windows support (PE/COFF)
- [ ] Branch/expression coverage via LLVM profraw (`--precise` mode)
- [ ] Cobertura XML and JSON output
- [ ] GitHub Actions annotations
- [ ] Codecov upload integration
- [ ] Comptime/unreachable line detection

## Contributing

```sh
zig build test   # run unit tests
zig build bench  # run performance benchmarks
```

Tracks the latest **Zig master** nightly (CI installs `master`). It was last verified against `0.17.0-dev.1464+6aff551f1` — recorded as `minimum_zig_version` in `build.zig.zon`. The project uses in-flux std/build APIs, so a future master may need a small porting pass; if `zig build` fails on a fresh master, that's expected churn, not a bug.
