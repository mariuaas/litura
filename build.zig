const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter = b.option(
        bool,
        "tree-sitter",
        "Enable Tree-sitter tokens and syntax (Lua, Zig)",
    ) orelse false;
    const zg = b.dependency("zg", .{});
    const options = b.addOptions();
    options.addOption(bool, "tree_sitter", tree_sitter);

    const module = b.addModule("litura", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    const syntax: ?SyntaxSources = if (tree_sitter) .{
        .runtime = b.lazyDependency("tree_sitter", .{ .amalgamated = true }) orelse return,
        .lua = b.lazyDependency("tree_sitter_lua", .{}) orelse return,
        .zig = b.lazyDependency("tree_sitter_zig", .{}) orelse return,
    } else null;
    configureModule(b, module, zg, syntax);
    const library = b.addLibrary(.{ .name = "litura", .linkage = .static, .root_module = module });
    b.installArtifact(library);

    const conformance_stride = b.option(
        u32,
        "conformance-stride",
        "Check every nth Unicode grapheme conformance case in `test` (default 8; 1 checks all)",
    ) orelse 8;
    const syntax_corpus = b.option(
        bool,
        "syntax-corpus",
        "Also test syntax views against a pinned corpus of test-only grammars (implies -Dtree-sitter)",
    ) orelse false;
    if (syntax_corpus and !tree_sitter) {
        std.debug.panic("-Dsyntax-corpus=true requires -Dtree-sitter=true", .{});
    }
    const syntax_corpus_steps = b.option(
        u32,
        "syntax-corpus-steps",
        "Random edit steps per corpus document (default 12)",
    ) orelse 12;
    const syntax_corpus_seed = b.option(
        u64,
        "syntax-corpus-seed",
        "Base seed of the corpus workloads, in decimal (default 1592639710, 0x5eedc0de)",
    ) orelse 0x5eed_c0de;
    const tests = behavioralTests(b, module, zg, target, optimize, conformance_stride);
    if (syntax_corpus and !addSyntaxCorpus(b, tests, module)) return;
    const corpus_options = b.addOptions();
    corpus_options.addOption(bool, "enabled", syntax_corpus);
    corpus_options.addOption(u32, "steps", syntax_corpus_steps);
    corpus_options.addOption(u64, "seed", syntax_corpus_seed);
    tests.root_module.addOptions("syntax_corpus_options", corpus_options);
    const units = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    units.root_module.addOptions("build_options", options);
    configureModule(b, units.root_module, zg, syntax);
    const check = b.step("check", "Compile behavioral and module-local tests without running them");
    check.dependOn(&tests.step);
    check.dependOn(&units.step);
    const test_step = b.step("test", "Run behavioral and module-local tests");
    const run_tests = b.addRunArtifact(tests);
    const run_units = b.addRunArtifact(units);
    if (b.args) |args| {
        run_tests.addArgs(args);
        run_units.addArgs(args);
    }
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_units.step);

    const conformance = b.step(
        "conformance",
        "Run behavioral tests against every Unicode grapheme conformance case",
    );
    const conformance_tests = behavioralTests(b, module, zg, target, optimize, 1);
    const no_corpus = b.addOptions();
    no_corpus.addOption(bool, "enabled", false);
    no_corpus.addOption(u32, "steps", 0);
    no_corpus.addOption(u64, "seed", 0);
    conformance_tests.root_module.addOptions("syntax_corpus_options", no_corpus);
    conformance.dependOn(&b.addRunArtifact(conformance_tests).step);

    const example = b.addExecutable(.{ .name = "litura-basic", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    example.root_module.addImport("litura", module);
    b.getInstallStep().dependOn(&example.step);
    b.step("example", "Run a document edit through the public module").dependOn(&b.addRunArtifact(example).step);

    const measure = b.addExecutable(.{ .name = "litura-measure", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/blocks.zig"),
        .target = target,
        .optimize = b.option(
            std.builtin.OptimizeMode,
            "measure-optimize",
            "Optimization mode for `measure` (default ReleaseFast)",
        ) orelse .ReleaseFast,
    }) });
    measure.root_module.addImport("litura", module);
    const measure_step = b.step("measure", "Measure block production for one caret and a thousand");
    measure_step.dependOn(&b.addRunArtifact(measure).step);

    const measure_syntax_step = b.step(
        "measure-syntax",
        "Measure syntax view costs across document sizes (requires -Dtree-sitter=true)",
    );
    if (tree_sitter) {
        const measure_syntax = b.addExecutable(.{
            .name = "litura-measure-syntax",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/syntax.zig"),
                .target = target,
                .optimize = measure.root_module.optimize.?,
            }),
        });
        measure_syntax.root_module.addImport("litura", module);
        measure_syntax_step.dependOn(&b.addRunArtifact(measure_syntax).step);
    } else {
        measure_syntax_step.dependOn(&b.addFail("measure-syntax requires -Dtree-sitter=true").step);
    }
}

/// Behavioral tests import the public module; `conformance_stride` samples the Unicode
/// conformance data, which zg ships for the Unicode version it implements.
fn behavioralTests(
    b: *std.Build,
    module: *std.Build.Module,
    zg: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    conformance_stride: u32,
) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.addImport("litura", module);
    tests.root_module.addAnonymousImport("grapheme_break_test", .{
        .root_source_file = zg.path("data/unicode/auxiliary/GraphemeBreakTest.txt"),
    });
    const test_options = b.addOptions();
    test_options.addOption(u32, "conformance_stride", conformance_stride);
    tests.root_module.addOptions("test_options", test_options);
    return tests;
}

const SyntaxSources = struct {
    runtime: *std.Build.Dependency,
    lua: *std.Build.Dependency,
    zig: *std.Build.Dependency,
};

fn configureModule(
    b: *std.Build,
    module: *std.Build.Module,
    zg: *std.Build.Dependency,
    syntax: ?SyntaxSources,
) void {
    module.addImport("zg_graphemes", zg.module("Graphemes"));
    module.addImport("zg_code_point", zg.module("code_point"));
    module.addImport("zg_properties", zg.module("Properties"));
    module.addImport("zg_words", zg.module("Words"));
    const sources = syntax orelse return;

    module.link_libc = true;
    module.addIncludePath(sources.runtime.path("lib/include"));
    module.addIncludePath(sources.lua.path("src"));
    module.addIncludePath(sources.zig.path(""));
    const files = [_]std.Build.LazyPath{
        sources.runtime.path("lib/src/lib.c"),
        sources.lua.path("src/parser.c"),
        sources.zig.path("parser.c"),
    };
    for (files) |file| module.addCSourceFile(.{ .file = file, .flags = &.{"-std=c11"} });

    // Give each upstream scanner a distinct include name for its ABI adapter.
    const scanners = b.addWriteFiles();
    _ = scanners.addCopyFile(sources.lua.path("src/scanner.c"), "lua_scanner_source.c");
    module.addIncludePath(scanners.getDirectory());
    module.addCSourceFile(.{ .file = b.path("src/text/tree_sitter/lua_scanner.c"), .flags = &.{"-std=c11"} });
}

/// A grammar of the optional grammar-diversity suite: a test fixture, compiled into the
/// test executable only and never into the library.
const CorpusGrammar = struct {
    name: []const u8,
    /// Its `build.zig.zon` dependency, and the version that pins (for reports).
    package: []const u8,
    version: []const u8,
    /// The directory holding `parser.c`, and `scanner.c` when `scanner` is set.
    src: []const u8,
    scanner: bool,
    /// Highlight query files, concatenated in order; a null package means this repository.
    highlights: []const QueryFile,
    /// The grammar's own test corpus directory, when its archive includes one.
    corpus: ?[]const u8,
    /// A larger hand-written document, under `tests/syntax_corpus/samples`.
    sample: []const u8,

    const QueryFile = struct { package: ?[]const u8 = null, path: []const u8 };
};

const corpus_grammars = [_]CorpusGrammar{
    .{
        .name = "c",
        .package = "corpus_c",
        .version = "v0.24.2",
        .src = "src",
        .scanner = false,
        .highlights = &.{
            .{ .package = "corpus_c", .path = "queries/highlights.scm" },
        },
        .corpus = null,
        .sample = "c.c",
    },
    .{
        .name = "cpp",
        .package = "corpus_cpp",
        .version = "v0.23.4",
        .src = "src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_c", .path = "queries/highlights.scm" },
            .{ .package = "corpus_cpp", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "cpp.cpp",
    },
    .{
        .name = "python",
        .package = "corpus_python",
        .version = "v0.23.6",
        .src = "src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_python", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "python.py",
    },
    .{
        .name = "rust",
        .package = "corpus_rust",
        .version = "v0.24.0",
        .src = "src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_rust", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "rust.rs",
    },
    .{
        .name = "go",
        .package = "corpus_go",
        .version = "v0.25.0",
        .src = "src",
        .scanner = false,
        .highlights = &.{
            .{ .package = "corpus_go", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "go.go",
    },
    .{
        .name = "javascript",
        .package = "corpus_javascript",
        .version = "v0.25.0",
        .src = "src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_javascript", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "javascript.js",
    },
    .{
        .name = "typescript",
        .package = "corpus_typescript",
        .version = "v0.23.2",
        .src = "typescript/src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_javascript", .path = "queries/highlights.scm" },
            .{ .package = "corpus_typescript", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "typescript.ts",
    },
    .{
        .name = "tsx",
        .package = "corpus_typescript",
        .version = "v0.23.2",
        .src = "tsx/src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_javascript", .path = "queries/highlights.scm" },
            .{ .package = "corpus_typescript", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "tsx.tsx",
    },
    .{
        .name = "bash",
        .package = "corpus_bash",
        .version = "v0.25.0",
        .src = "src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_bash", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "bash.sh",
    },
    .{
        .name = "java",
        .package = "corpus_java",
        .version = "v0.23.5",
        .src = "src",
        .scanner = false,
        .highlights = &.{
            .{ .package = "corpus_java", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "java.java",
    },
    .{
        .name = "ocaml",
        .package = "corpus_ocaml",
        .version = "v0.26.0",
        .src = "grammars/ocaml/src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_ocaml", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "ocaml.ml",
    },
    .{
        .name = "clojure",
        .package = "corpus_clojure",
        .version = "v0.0.13",
        .src = "src",
        .scanner = false,
        .highlights = &.{
            .{ .package = "corpus_clojure", .path = "queries/highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "clojure.clj",
    },
    .{
        .name = "commonlisp",
        .package = "corpus_commonlisp",
        .version = "v0.4.1",
        .src = "src",
        .scanner = false,
        .highlights = &.{
            .{ .path = "tests/syntax_corpus/commonlisp_highlights.scm" },
        },
        .corpus = "test/corpus",
        .sample = "commonlisp.lisp",
    },
    .{
        .name = "perl",
        .package = "corpus_perl",
        .version = "release@471859e9",
        .src = "src",
        .scanner = true,
        .highlights = &.{
            .{ .package = "corpus_perl", .path = "queries/highlights.scm" },
        },
        .corpus = null,
        .sample = "perl.pl",
    },
};

/// Compiles the corpus grammars into `tests` and gives it a generated `syntax_corpus`
/// module listing them with their queries and seed documents. Returns false while a
/// lazy dependency is still being fetched.
fn addSyntaxCorpus(b: *std.Build, tests: *std.Build.Step.Compile, litura: *std.Build.Module) bool {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    const w = &source;
    w.appendSlice(b.allocator,
        \\//! Generated by build.zig: the grammar-diversity corpus.
        \\const litura = @import("litura");
        \\
        \\pub const Entry = struct {
        \\    name: []const u8,
        \\    version: []const u8,
        \\    grammar: litura.tree_sitter.Grammar,
        \\    corpus: []const []const u8,
        \\    sample: []const u8,
        \\};
        \\
        \\pub const entries = [_]Entry{
        \\
    ) catch @panic("OOM");
    var externs: std.ArrayList(u8) = .empty;
    for (corpus_grammars) |grammar| {
        const package = b.lazyDependency(grammar.package, .{}) orelse return false;
        // Most of these scanners define `create()` without a prototype; calls through
        // Tree-sitter's `void *(*)(void)` are valid C but trip -fsanitize=function. The
        // fixtures are optimized in every mode: they are not under test, and lexing
        // through unoptimized parse tables dominates a Debug run.
        const flags: []const []const u8 = &.{
            "-std=c11",
            "-Wno-unused-but-set-variable",
            "-fno-sanitize=function",
            "-O2",
        };
        const parser = package.path(b.fmt("{s}/parser.c", .{grammar.src}));
        tests.root_module.addCSourceFile(.{ .file = parser, .flags = flags });
        if (grammar.scanner) {
            // Shared scanner headers include `tree_sitter/parser.h` from outside `src`.
            const include = b.fmt("-I{s}", .{package.path(grammar.src).getPath(b)});
            const scanner_flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{include} }) catch
                @panic("OOM");
            tests.root_module.addCSourceFile(.{
                .file = package.path(b.fmt("{s}/scanner.c", .{grammar.src})),
                .flags = scanner_flags,
            });
        }
        append(b, &externs, "extern fn tree_sitter_{s}() callconv(.c) " ++
            "*const litura.tree_sitter.Language;\n", .{grammar.name});

        append(b, w, "    .{{ .name = \"{s}\", .version = \"{s}\", .grammar = .{{\n", .{
            grammar.name,
            grammar.version,
        });
        append(b, w, "        .name = \"{s}\",\n", .{grammar.name});
        append(b, w, "        .provider_name = \"tree-sitter-{s}\",\n", .{grammar.name});
        append(b, w, "        .language = tree_sitter_{s},\n", .{grammar.name});
        append(b, w, "        .highlights_query = \"\"", .{});
        for (grammar.highlights, 0..) |query, index| {
            const path = if (query.package) |name|
                b.lazyDependency(name, .{}).?.path(query.path)
            else
                b.path(query.path);
            const copied = b.fmt("{s}/highlights{d}.scm", .{ grammar.name, index });
            _ = files.addCopyFile(path, copied);
            append(b, w, " ++ @embedFile(\"{s}\") ++ \"\\n\"", .{copied});
        }
        append(b, w, ",\n    }},\n        .corpus = &.{{", .{});
        if (grammar.corpus) |directory| {
            for (corpusFiles(b, package.path(directory))) |name| {
                const copied = b.fmt("{s}/corpus/{s}", .{ grammar.name, name });
                _ = files.addCopyFile(package.path(b.fmt("{s}/{s}", .{ directory, name })), copied);
                append(b, w, " @embedFile(\"{s}\"),", .{copied});
            }
        }
        const sample = b.fmt("{s}/sample", .{grammar.name});
        const sample_path = b.path(b.fmt("tests/syntax_corpus/samples/{s}", .{grammar.sample}));
        _ = files.addCopyFile(sample_path, sample);
        append(b, w, " }},\n        .sample = @embedFile(\"{s}\"),\n    }},\n", .{sample});
    }
    append(b, w, "}};\n\n{s}", .{externs.items});
    const root = files.add("corpus.zig", source.items);
    const corpus = b.createModule(.{ .root_source_file = root });
    corpus.addImport("litura", litura);
    tests.root_module.addImport("syntax_corpus", corpus);
    return true;
}

fn append(b: *std.Build, list: *std.ArrayList(u8), comptime format: []const u8, args: anytype) void {
    list.print(b.allocator, format, args) catch @panic("OOM");
}

/// The `.txt` files directly in `directory`, sorted so the generated module is stable.
fn corpusFiles(b: *std.Build, directory: std.Build.LazyPath) []const []const u8 {
    const io = b.graph.io;
    const path = directory.getPath(b);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.panic("opening corpus {s}: {t}", .{ path, err });
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| std.debug.panic("listing {s}: {t}", .{ path, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return names.items;
}
