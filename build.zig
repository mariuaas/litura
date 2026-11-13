const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter = b.option(bool, "tree-sitter", "Enable Tree-sitter tokens and syntax (Lua, Zig, Fennel)") orelse false;
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
        .fennel = b.lazyDependency("tree_sitter_fennel", .{}) orelse return,
    } else null;
    configureModule(b, module, zg, syntax);
    const library = b.addLibrary(.{ .name = "litura", .linkage = .static, .root_module = module });
    b.installArtifact(library);

    const conformance_stride = b.option(
        u32,
        "conformance-stride",
        "Check every nth Unicode grapheme conformance case in `test` (default 8; 1 checks all)",
    ) orelse 8;
    const tests = behavioralTests(b, module, zg, target, optimize, conformance_stride);
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
    conformance.dependOn(&b.addRunArtifact(behavioralTests(b, module, zg, target, optimize, 1)).step);

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
    fennel: *std.Build.Dependency,
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
    module.addIncludePath(sources.fennel.path("src"));
    const files = [_]std.Build.LazyPath{
        sources.runtime.path("lib/src/lib.c"),
        sources.lua.path("src/parser.c"),
        sources.zig.path("parser.c"),
        sources.fennel.path("src/parser.c"),
    };
    for (files) |file| module.addCSourceFile(.{ .file = file, .flags = &.{"-std=c11"} });

    // Give each upstream scanner a distinct include name for its ABI adapter.
    const scanners = b.addWriteFiles();
    _ = scanners.addCopyFile(sources.lua.path("src/scanner.c"), "lua_scanner_source.c");
    _ = scanners.addCopyFile(sources.fennel.path("src/scanner.c"), "fennel_scanner_source.c");
    module.addIncludePath(scanners.getDirectory());
    module.addCSourceFile(.{ .file = b.path("src/text/tree_sitter/lua_scanner.c"), .flags = &.{"-std=c11"} });
    module.addCSourceFile(.{ .file = b.path("src/text/tree_sitter/fennel_scanner.c"), .flags = &.{"-std=c11"} });
}
