const std = @import("std");
const builtin = @import("builtin");
const GitSparseCheckoutStep = @This();

step: std.Build.Step,
git_path: []const u8,
url: []const u8,
branch: ?[]const u8,
name: []const u8,
path: []const u8,
directories: []const []const u8,

fn getSearchPath(allocator: std.mem.Allocator) ![]const u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // sane systems must have a PATH variable
    const path = env_map.get("PATH") orelse return error.NoPathVariable;
    // well, the backing store will be nuked after this function returns.
    const path_dup = try allocator.dupe(u8, path);

    return path_dup;
}

inline fn getSearchPathSeparator() []const u8 {
    // TODO: should be made more comprehensive
    // NOTE: use the OS tag of the building computer, not the target computer!
    return switch (builtin.os.tag) {
        .windows => ";",
        else => ":",
    };
}

/// Searches for an executable using the system PATH variable. This function
/// in a nutshell checks for existence of the given executable file under each
/// path defined in the system PATH variable, returning the first match just
/// like an operating system would resolve an executable name to. *Keep in mind
/// that the returned path is an absolute path.*
///
/// **Important!** This function does __not__ deal with the executable extension,
/// you must append the extension for the OS being worked with. This means that
/// the `exe_name` must contain the extension (if it has one, such as `.exe` on
/// Windows systems.)
///
/// The caller is responsible for releasing the returned string with the given
/// allocator.
fn searchForExecutable(allocator: std.mem.Allocator, exe_name: []const u8) ![]const u8 {
    const search_path = try getSearchPath(allocator);
    defer allocator.free(search_path);

    // create an arena to release all the new path strings at once.
    var path_arena = std.heap.ArenaAllocator.init(allocator);
    defer path_arena.deinit();
    const path_alloc = path_arena.allocator();

    // split the PATH variable into its actual paths.
    var paths_split = std.mem.splitSequence(u8, search_path, getSearchPathSeparator());
    while (paths_split.next()) |path_str| {
        // skip the empty splits
        if (path_str.len == 0) continue;

        // XXX: should we return the allocation error as is? we're just skipping here.
        const new_path = std.fs.path.join(path_alloc, &.{ path_str, exe_name }) catch continue;

        // skip if this file does not exist. or else blow up
        std.fs.accessAbsolute(new_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        // return the first one, just like a system would resolve.
        // but we need to dupe the whole path using the main allocator as
        // the arena will get nuked out of orbit when this whole function
        // returns.
        const path_dupe = try allocator.dupe(u8, new_path);
        return path_dupe;
    }

    return error.FileNotFound;
}

fn hasDependency(allocator: std.mem.Allocator, step: *const std.build.Step, dep_candidate: *const std.build.Step) !bool {
    const S = struct {
        const Self = @This();

        /// A hash set to keep the account of which steps are encountered
        encountered: std.AutoHashMap(*const std.build.Step, void),

        pub fn init() Self {
            return .{
                .encountered = std.AutoHashMap(*const std.build.Step, void).init(allocator),
            };
        }

        pub fn check(self: *Self, _step: *const std.build.Step, candidate: *const std.build.Step) !bool {
            if (self.encountered.contains(_step))
                return error.CircularDependencyDetected;

            try self.encountered.put(_step, {});

            for (_step.dependencies.items) |dep| {
                if (dep == candidate or try self.check(dep, candidate)) {
                    return true;
                }
            }

            return false;
        }

        pub fn deinit(self: *Self) void {
            self.encountered.deinit();
        }
    };

    var checker = S.init(allocator);
    defer checker.deinit();
    return try checker.check(step, dep_candidate);
}

fn run(build: *std.Build, argv: []const []const u8, cwd_: ?std.fs.Dir) !void {
    var cwd = cwd_ orelse build.build_root.handle;
    {
        var message = std.ArrayList(u8).init(build.allocator);
        defer message.deinit();
        const writer = message.writer();

        var prefix: []const u8 = "";

        for (argv) |arg| {
            try writer.print("{s}\"{s}\"", .{ prefix, arg });
            prefix = " ";
        }

        //std.log.info("[RUN] {s}", .{message.items});
    }

    var child = std.ChildProcess.init(argv, build.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.cwd_dir = cwd;
    child.env_map = build.env_map;
    const result = try child.spawnAndWait();
    switch (result) {
        .Exited => |code| if (code != 0) {
            std.log.err("git clone failed with exit code {}", .{code});
            std.os.exit(0xFF);
        },

        else => {
            std.log.err("git clone failed with: {}", .{result});
            std.os.exit(0xFF);
        },
    }
}

const GitSparseCheckoutStepOptions = struct {
    url: []const u8,
    directories: []const []const u8,
    git_path: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    local_path: ?[]const u8 = null,
};

inline fn getGitExeName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "git.exe",
        else => "git",
    };
}

pub fn create(b: *std.Build, options: GitSparseCheckoutStepOptions) *GitSparseCheckoutStep {
    var result = b.allocator.create(GitSparseCheckoutStep) catch @panic("memory");
    const name = std.fs.path.stem(options.url);

    result.* = GitSparseCheckoutStep{
        .step = std.build.Step.init(.{
            .id = .custom,
            .name = "sparse checkout some dirs from a git repository",
            .owner = b,
            .makeFn = make,
            .first_ret_addr = @returnAddress(),
        }),
        .git_path = options.git_path orelse searchForExecutable(b.allocator, getGitExeName()) catch @panic("git not found"),
        .url = options.url,
        .branch = options.branch,
        .name = name,
        .path = if (options.local_path) |p| (b.allocator.dupe(u8, p) catch @panic("memory")) else (std.fs.path.resolve(b.allocator, &[_][]const u8{
            b.build_root.path.?,
            "dep",
            name,
        })) catch @panic("memory"),
        .directories = options.directories,
    };

    return result;
}

fn make(step: *std.Build.Step, progress: *std.Progress.Node) !void {
    const self = @fieldParentPtr(GitSparseCheckoutStep, "step", step);

    std.fs.accessAbsolute(self.path, .{}) catch {
        {
            var gitsc_progress = progress.start("Git Sparse Clone", 0);
            defer gitsc_progress.end();
            gitsc_progress.activate();

            var args = std.ArrayList([]const u8).init(self.step.owner.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ self.git_path, "clone", "-n", "--depth=1", "--filter=tree:0", self.url, self.path });

            if (self.branch) |branch| try args.appendSlice(&.{ "-b", branch });

            try run(self.step.owner, args.items, null);
        }

        {
            var gitsc_progress = progress.start("Git Set Sparse Checkout", 0);
            defer gitsc_progress.end();
            gitsc_progress.activate();

            var args = std.ArrayList([]const u8).init(self.step.owner.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ self.git_path, "sparse-checkout", "set", "--no-cone" });
            try args.appendSlice(self.directories);

            var the_cwd = std.fs.openDirAbsolute(self.path, .{}) catch @panic("failed to open dir");
            defer the_cwd.close();
            try run(self.step.owner, args.items, the_cwd);
        }

        {
            var gitsc_progress = progress.start("Git Pull", 0);
            defer gitsc_progress.end();
            gitsc_progress.activate();

            var args = std.ArrayList([]const u8).init(self.step.owner.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ self.git_path, "pull", "origin", self.branch orelse "main" });

            var the_cwd = std.fs.openDirAbsolute(self.path, .{}) catch @panic("failed to open dir");
            defer the_cwd.close();
            try run(self.step.owner, args.items, the_cwd);
        }

        {
            var gitsc_progress = progress.start("Git Checkout", 0);
            defer gitsc_progress.end();
            gitsc_progress.activate();

            var args = std.ArrayList([]const u8).init(self.step.owner.allocator);
            defer args.deinit();
            try args.append(self.git_path);
            try args.append("checkout");

            var the_cwd = std.fs.openDirAbsolute(self.path, .{}) catch @panic("failed to open dir");
            defer the_cwd.close();
            try run(self.step.owner, args.items, the_cwd);
        }
    };
}

// Get's the repository path and also verifies that the step requesting the path
// is dependent on this step.
pub fn getPath(self: *const GitSparseCheckoutStep, who_wants_to_know: *const std.build.Step) []const u8 {
    if (!hasDependency(who_wants_to_know, &self.step))
        @panic("a step called GitSparseCheckoutStep.getPath but has not added it as a dependency");
    return self.path;
}
