const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Linkage = Step.Compile.Linkage;
const LazyPath = Build.LazyPath;
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(Linkage, "linkage", "The linking mode for the ICU libraries");
    const module = b.addModule("common", .{ .source_file = LazyPath.relative("build.zig") });
    _ = module;

    const lib_name = "icuuc";

    var lib = addLibraryWithLinkage(b, .{
        .name = lib_name,
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    });
    const linkage_def = if (linkage == .static) "-DU_STATIC_IMPLEMENTATION" else "";

    lib.linkLibCpp();
    addSourceFiles(b, lib, &.{ "-fno-exceptions", "-DU_COMMON_IMPLEMENTATION", linkage_def }) catch @panic("OOM");
    lib.addIncludePath(LazyPath.relative("cpp"));
    installInternalHeaders(b, lib) catch @panic("OOM");
    b.installArtifact(lib);
}

fn installInternalHeaders(b: *Build, artifact: *Step.Compile) !void {
    var dir = try std.fs.cwd().openIterableDir("cpp", .{ .access_sub_paths = false });
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    const allowed_exts = [_][]const u8{ ".h", ".hpp" };
    while (try walker.next()) |entry| {
        const ext = std.fs.path.extension(entry.basename);
        const include_file = for (allowed_exts) |e| {
            if (std.mem.eql(u8, ext, e))
                break true;
        } else false;

        if (include_file) {
            // we need to clone the path as walker.next()
            const duped = b.dupe(entry.path);
            artifact.installHeader(b.pathJoin(&.{ "cpp", duped }), duped);
        }
    }
}

fn addSourceFiles(b: *Build, artifact: *Step.Compile, flags: []const []const u8) !void {
    var files = std.ArrayList([]const u8).init(b.allocator);
    var sources_txt = try std.fs.cwd().openFile(b.pathFromRoot("cpp/sources.txt"), .{});
    var reader = sources_txt.reader();
    var buffer: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |l| {
        const line = std.mem.trim(u8, l, " \t\r\n");
        try files.append(b.pathJoin(&.{ "cpp", line }));
    }

    artifact.addCSourceFiles(files.items, flags);
}

const LibraryOptions = struct {
    name: []const u8,
    root_source_file: ?LazyPath = null,
    version: ?std.SemanticVersion = null,
    target: CrossTarget,
    optimize: std.builtin.OptimizeMode,
    max_rss: usize = 0,
    link_libc: ?bool = null,
    single_threaded: ?bool = null,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    main_pkg_path: ?LazyPath = null,
    linkage: ?Linkage = null,
};

fn addLibraryWithLinkage(b: *Build, options: LibraryOptions) *Step.Compile {
    return Step.Compile.create(b, .{
        .name = options.name,
        .root_source_file = options.root_source_file,
        .kind = .lib,
        .version = options.version,
        .target = options.target,
        .optimize = options.optimize,
        .max_rss = options.max_rss,
        .link_libc = options.link_libc,
        .single_threaded = options.single_threaded,
        .use_llvm = options.use_llvm,
        .use_lld = options.use_lld,
        .zig_lib_dir = options.zig_lib_dir orelse b.zig_lib_dir,
        .main_pkg_path = options.main_pkg_path,
        .linkage = options.linkage,
    });
}
