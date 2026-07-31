# zig-cov

[![CI](https://github.com/ericsssan/zcov/actions/workflows/ci.yml/badge.svg)](https://github.com/ericsssan/zcov/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/ericsssan/zcov/branch/main/graph/badge.svg)](https://codecov.io/gh/ericsssan/zcov)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> The coverage badge is measured by zig-cov on its own test suite.

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

zig-cov uses the same SanitizerCoverage instrumentation Zig's built-in fuzzer relies on: inline 8-bit counters plus a table of the program counters they correspond to. The runtime:

1. Reads `__sancov_cntrs` (one byte per instrumented block) and `__sancov_pcs1` (that block's address) at process exit
2. Writes both to a `.zcov` binary file

Recording the whole table rather than only what ran is what makes misses real: a block with a zero counter definitely never executed, and the table's addresses mark block boundaries, so an executed block can be expanded across every line it spans.

The CLI then maps those PC addresses back to `file:line` locations using DWARF debug information via `std.debug.Info` (supports ELF on Linux, Mach-O on macOS).

### Why SanitizerCoverage over alternatives

| | SanitizerCoverage | LLVM source-based | ptrace (kcov) | Source rewriting |
|-|:-----------------:|:-----------------:|:-------------:|:----------------:|
| Compile overhead | < 2x | 14x | none | needs Zig parser |
| Runtime overhead | 5–15% | 5–30% | 10–50% | ~3% |
| Cross-platform | yes | yes | platform-specific | yes |
| Accuracy | line-level | expression-level | line-level | line-level |
| Uses existing Zig infra | yes | needs flag exposure | external tool | full parser needed |

There is no zig-cov code on the instrumentation hot path: LLVM emits an inline byte increment per block, and the runtime reads the counters once, at process exit.

## Installation

```sh
git clone https://github.com/ericsssan/zcov
cd zcov
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
    unit_tests.use_llvm = true;                  // required (see note below)
    unit_tests.root_module.fuzz = true;          // emits counters + PC table
    unit_tests.root_module.link_libc = true;     // required (see note below)
    if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
}
```

That's the only change needed. zig-cov passes the flags automatically when you use `zig-cov test`.

> **Why these three?**
> - `fuzz`: this is the switch that makes LLVM emit inline 8-bit counters and the table of block addresses they belong to (`__sancov_cntrs` / `__sancov_pcs1`), which is what the zig-cov runtime reads. It is the only coverage instrumentation Zig's build system exposes. Note it also makes the test binary require the build runner — `zig build test` is fine, but the binary can no longer be executed standalone.
> - `use_llvm`: instrumentation is only emitted by the LLVM backend. The self-hosted backends emit **none**, silently, so forcing LLVM is required.
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

# Self-contained HTML report (source view with syntax highlighting)
zig-cov test --format=html --output=coverage.html

# JSON for scripting (stdout by default, so it pipes)
zig-cov test --format=json | jq '.summary.line_percent'

# Cobertura XML (Jenkins, GitLab CI, Codecov)
zig-cov test --format=cobertura --output=coverage.xml

# Inline annotations on the PR diff (inside GitHub Actions)
zig-cov test --format=github

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
| `--format=summary\|lcov\|html\|json\|cobertura\|github` | `summary` | Output format |
| `--output=<path>` | stdout | Output file (all formats go to stdout except `html`, which defaults to `coverage.html`) |
| `--fail-under=<pct>` | `0` | Exit 1 if line coverage is below this percentage |
| `--color=on\|off\|auto` | `auto` | Terminal colour in summary output |
| `--project=<dir>` | `.` | Directory containing `build.zig` |
| `--include=<substr>` | — | Only report files matching (repeatable; overrides the default project-dir filter) |
| `--exclude=<substr>` | — | Drop files matching (repeatable) |
| `--max-annotations=<n>` | `10` | Cap for `--format=github` (`0` = no cap) |

By default only files under `--project` are reported — the Zig standard library
and other out-of-tree files are hidden. Relative source paths (project-local)
are always kept. To report everything, pass an `--include` that matches (e.g.
`--include=.zig`); to see the std library too, `--include=/std/`.

## Block coverage

Alongside the line figures, `zig-cov` reports:

```
Blocks (exact)                          62.5% (5/8)
```

This is what the counters literally recorded — how many instrumented basic
blocks executed — with no line attribution in between, so unlike the line
percentage it cannot be wrong. Blocks are attributed to files by their own
address, so the same `--include`/`--exclude` filtering applies.

It answers a stricter question than line coverage, closer to branch coverage: an
error path that never runs is an unexecuted block even when every *line* of the
function ran. Zig emits a branch after every `try`, so this figure reads low for
ordinary code — a function whose every line executes but which never fails
reports 2/9 blocks. That is not a bug; those branches genuinely never ran. Use
line coverage to ask "did I execute this code", and block coverage to ask "did I
exercise its paths".

## JSON format

`--format=json` emits a stable document. Files are sorted by path and lines by
number, so output is deterministic and diffable. A line with `"hits": 0` is a
miss; lines with no generated code are absent.

```json
{
  "version": 2,
  "tool": "zig-cov",
  "summary": {
    "lines_found": 819, "lines_hit": 301, "line_percent": 36.75,
    "functions_found": 0, "functions_hit": 0, "function_percent": 100.00,
    "blocks_found": 512, "blocks_hit": 190, "block_percent": 37.11
  },
  "files": [
    {
      "path": "clap/parsers.zig",
      "lines_found": 57, "lines_hit": 16, "line_percent": 28.07,
      "lines": [ {"line": 12, "hits": 3}, {"line": 13, "hits": 0} ],
      "functions": [ {"name": "parseInt", "line": 12, "hits": 3} ]
    }
  ]
}
```

`version` is the schema version, bumped on any incompatible change.

## Cobertura XML

`--format=cobertura` emits a `coverage-04.dtd` document for Jenkins, GitLab CI
and Codecov. Files are grouped into `<package>` elements by directory, and
`filename` attributes are made **relative to the project directory** (emitted as
`<source>`) because CI platforms resolve coverage against the repository root.

```xml
<coverage line-rate="0.3675" lines-covered="301" lines-valid="819" ...>
  <sources><source>/path/to/project</source></sources>
  <packages>
    <package name="clap" line-rate="0.3652" ...>
      <classes>
        <class name="parsers" filename="clap/parsers.zig" line-rate="0.2807" ...>
          <methods/>
          <lines><line number="12" hits="3"/></lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
```

zig-cov has no branch data, so `branch-rate` and the branch counters are
reported as zero rather than fabricated.

## GitHub Actions annotations

`--format=github` writes workflow commands to stdout, which the runner turns
into inline annotations on the pull request diff:

```yaml
- name: Coverage
  run: zig-cov test --format=github --fail-under=80
```

```
::warning file=src/parser.zig,line=164,endLine=170::6 lines not covered
::notice::Coverage 36.8% (301/819 lines); 152 more uncovered regions not annotated (limit 10)
```

- Runs of uncovered lines are merged into one ranged annotation instead of one
  per line. A run is broken by a *covered* line, so lines with no generated code
  (comments, blanks) don't split it — the message states how many lines in the
  range are actually uncovered.
- Output is capped at `--max-annotations` (default 10) because GitHub only
  surfaces a limited number per step. Anything dropped is reported in the
  summary rather than silently discarded; pass `--max-annotations=0` for all.
- With `--fail-under`, falling short emits an `::error::` annotation and exits 1.

## Uploading to Codecov

zig-cov writes the tracefile; the official uploader ships it. Coverage services
match files by path **relative to the repository root**, which is what zig-cov
emits (`SF:src/main.zig`, not an absolute build path), so files line up without
any `fixes`/path-mapping configuration.

```yaml
- name: Coverage
  run: zig-cov test --format=lcov --output=coverage.lcov

- uses: codecov/codecov-action@v5
  with:
    files: coverage.lcov
    token: ${{ secrets.CODECOV_TOKEN }}
```

The same tracefile works with Coveralls and anything else that reads LCOV;
`--format=cobertura` is also accepted by Codecov if you prefer XML. Run
`zig-cov` from the repository root (or pass `--project=<dir>`) so the paths are
relative to the root the service expects.

## .zcov file format

`.zcov` is a simple binary format written by the runtime on process exit:

```
Magic:      [4]u8  = "ZCOV"
Version:    u32    = 2  (little-endian throughout)
Slide:      i64    = ASLR slide (subtract from PCs to get virtual addresses)
NumPCs:     u32    = number of instrumented blocks
BinPathLen: u16    = byte length of binary path
BinPath:    [BinPathLen]u8
PCs:        [NumPCs]u64 = address of every instrumented block
Counts:     [NumPCs]u8  = execution count per block, saturating at 255
```

Multiple `.zcov` files (one per test binary invocation) are merged by the CLI before generating the report.

## Performance

Measured on Apple Silicon (M-series, `ReleaseSafe`):

| Metric | Result | Target |
|--------|--------|--------|
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
- **Line coverage is approximate.** Coverage points are chosen by the Zig compiler, and it places them where *fuzzing* benefits rather than at every branch — `Sema.zig` marks error-handling branches as points of interest and explicitly declines others ("code coverage is not valuable on either branch", "not wanted for panic branches"). zig-cov takes that exact table and attributes each source line to the last point at or before it, which is exact for straight-line code (a function whose every line runs reports 100%).

  Where the compiler placed no point, a line would otherwise inherit the status of the code before it, which can report a never-taken branch as **covered** — the one error that matters, since it hides untested code. zig-cov guards against this: a line inside an `if`/`while`/`for`/`switch`/`catch` body is only reported covered when a coverage point *inside that body* actually executed. A never-executed loop body is therefore reported as a miss, and the integration test pins that behaviour.

  Two gaps remain, both understating rather than overstating:

  - A body that really did run, but contains no coverage point, is reported missed. This is the deliberate trade — unproven is treated as uncovered.
  - Lines following a `try` can be reported missed, because the error branch *is* instrumented and shadows them when it never runs.

  One case still overstates and cannot be fixed here: when an `if` body ends in `return`, the compiler attributes the merge point after the `if` to the body's **last line**, so DWARF itself reports that line as executed. Overriding that would mean second-guessing the compiler's own line table.

  Treat line percentages as an estimate and read the annotated source rather than a single number — **block coverage** (below) involves no such inference. Closing the gap properly needs Zig to emit a coverage point per branch; this is not LLVM's `-fsanitize-coverage` pruning, since Zig sets `PCTable` and `Inline8bitCounters` to false and emits its own instrumentation.

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
│   └── resolver.zig          PC → file:line resolver, block expansion and
│                             coverable-line enumeration (ELF + Mach-O)
├── report/
│   ├── paths.zig             Repo-relative path helper (shared)
│   ├── lcov.zig              LCOV tracefile writer
│   ├── summary.zig           Terminal table writer
│   ├── html.zig              HTML report (source view + highlighting)
│   ├── json.zig              JSON writer
│   ├── cobertura.zig         Cobertura XML writer
│   └── github.zig            GitHub Actions annotations
├── runtime/
│   ├── sancov.zig            reads the counter + PC-table sections at exit
│   └── zcov_format.zig       .zcov binary format read/write
└── bench.zig                 Synthetic performance benchmarks
```

## Roadmap

- [x] HTML report with Zig syntax highlighting
- [ ] Windows support (PE/COFF)
- [ ] Branch/expression coverage via LLVM profraw (`--precise` mode)
- [x] JSON output
- [x] Cobertura XML output
- [x] GitHub Actions annotations
- [x] Codecov upload integration
- [ ] Comptime/unreachable line detection

## Contributing

```sh
zig build test   # run unit tests
zig build bench  # run performance benchmarks
```

Tracks the latest **Zig master** nightly (CI installs `master`). It was last verified against `0.17.0-dev.1509+bb296ab9b` — recorded as `minimum_zig_version` in `build.zig.zon`. The project uses in-flux std/build APIs, so a future master may need a small porting pass; if `zig build` fails on a fresh master, that's expected churn, not a bug.
