const std = @import("std");
const GitSparseCheckoutStep = @import("GitSparseCheckoutStep.zig");

pub fn build(b: *std.Build) !void {
    const Linkage = std.Build.Step.Compile.Linkage;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(Linkage, "linkage", "The linking mode for libraries") orelse .static;
    const lib_name = "icuuc";

    // Download the "common" directory right from the ICU repo.
    const icuuc_repo = GitSparseCheckoutStep.create(b, .{
        .url = "https://github.com/ochreimu/icu.git",
        .branch = "main",
        .directories = &.{"icu4c/source/common"},
    });

    const lib = std.Build.Step.Compile.create(b, .{
        .name = lib_name,
        .kind = .lib,
        .linkage = linkage,
        .target = target,
        .optimize = optimize,
    });
    lib.step.dependOn(&icuuc_repo.step);

    if (linkage == .static) {
        lib.defineCMacro("U_STATIC_IMPLEMENTATION", null);
    }

    lib.linkLibCpp();
    lib.defineCMacro("U_COMMON_IMPLEMENTATION", null);

    const root = b.pathFromRoot(b.pathJoin(&.{ "dep", "icu", "icu4c", "source", "common" }));
    lib.addIncludePath(.{ .path = root });

    // HACK: -I xxx trick: This is an ugly trick
    addSourceFiles(b, lib, &.{ "-fno-exceptions", "-I", root }, root) catch @panic("OOM");

    lib.installHeadersDirectory(b.pathJoin(&.{ root, "unicode" }), "unicode");
    b.installArtifact(lib);
}

fn addSourceFiles(b: *std.Build, artifact: *std.Build.Step.Compile, flags: []const []const u8, root: []const u8) !void {
    var files = std.ArrayList([]const u8).init(b.allocator);
    var sources_txt = try std.fs.cwd().openFile(b.pathJoin(&.{ root, "sources.txt" }), .{});
    var reader = sources_txt.reader();
    var buffer: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |l| {
        const line = std.mem.trim(u8, l, " \t\r\n");
        try files.append(b.pathJoin(&.{ root, line }));
    }

    artifact.addCSourceFiles(.{
        .files = files.items,
        .flags = flags,
    });
}
