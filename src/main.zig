const std = @import("std");

const GPA = std.heap.DebugAllocator(.{});
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.ArgIterator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const argsWithAllocator = std.process.argsWithAllocator;
const openDirAbsolute = std.fs.openDirAbsolute;
const StaticStringMap = std.StaticStringMap;
const panic = std.debug.panic;

const APODManagerError = error {
    NoAPIkey
};

fn getErrorSetOf(comptime must_be_fn: anytype) type {
    return
        @typeInfo(
            @typeInfo(@TypeOf(must_be_fn)).@"fn".return_type.?
        ).error_union.error_set;
}

const Error =
    Allocator.Error ||
    File.WriteError ||
    APODManagerError ||
    std.fs.Dir.RealPathAllocError ||
    File.OpenError ||
    getErrorSetOf(File.readToEndAlloc);

const Configuration = struct {
    api_key: ?[]const u8 = undefined,
    apods_path: []const u8 = undefined,
    apods_path_alloc: bool = false,
    apods_media_path: []const u8 = undefined,
    apods_media_path_alloc: bool = false,
    env: std.process.EnvMap = undefined,
    allocator: Allocator = undefined,

    pub fn init(allocator: Allocator) Error!Configuration {
        var env = try std.process.getEnvMap(allocator);

        var apods_path: []const u8 = undefined;
        var apods_path_alloc = false;
        if (env.get("APODS_PATH")) |path| {
            apods_path = path;
        } else {
            apods_path = try std.fs.cwd().realpathAlloc(allocator, ".");
            apods_path_alloc = true;
        }

        var apods_media_path: []const u8 = undefined;
        var apods_media_path_alloc = false;
        if (env.get("APODS_MEDIA_PATH")) |path| {
            apods_media_path = path;
        } else {
            apods_media_path = try std.fs.cwd().realpathAlloc(allocator, ".");
            apods_media_path_alloc = true;
        }

        return Configuration {
            .env = env,
            .api_key = env.get("APOD_API_KEY"),
            .apods_path = apods_path,
            .apods_path_alloc = apods_path_alloc,
            .apods_media_path = apods_media_path,
            .apods_media_path_alloc = apods_media_path_alloc,
            .allocator = allocator
        };
    }

    pub fn deinit(self: *Configuration) void {
        self.env.deinit();
        if (self.apods_path_alloc) {
            self.allocator.free(self.apods_path);
        }
        if (self.apods_media_path_alloc) {
            self.allocator.free(self.apods_media_path);
        }
    }
};

const CommandFunctionPointer = *const fn(Allocator, *ArgIterator) Error!void;

const command_map = StaticStringMap(CommandFunctionPointer).initComptime(.{
    .{ "help", helpCommand },
    .{ "list", listCommand }
});

const APOD = struct {
    date: []u8 = undefined,
    title: []u8 = undefined,
    explanation: []u8 = undefined,
    url: []u8 = undefined,
    media_type: []u8 = undefined,
    hdurl: ?[]u8 = null,
    concepts: ?[]u8 = null,
    thumbnail_url: ?[]u8 = null,
    copyright: ?[]u8 = null,
    service_version: ?[]u8 = null,
};

const ERROR_RENDER = "\x1b[1;37;41m";
const RESET_RENDER = "\x1b[0m";

fn print(comptime fmt: []const u8, args: anytype) !void {
    return std.io
        .getStdOut()
        .writer()
        .print(
            fmt,
            args
        );
}

fn print_error(comptime fmt: []const u8, args: anytype) !void {
    return std.io
        .getStdErr()
        .writer()
        .print(
            ERROR_RENDER ++ "ERROR" ++ RESET_RENDER ++ ":" ++ fmt,
            args
        );
}

fn helpCommand(allocator: Allocator, args: *ArgIterator) Error!void {
    _ = .{ allocator, args };
    try print("zapod help:\n", .{});
    for (command_map.keys()) |command| {
        try print("    {s}\n", .{command});
    }
}

fn listCommand(allocator: Allocator, args: *ArgIterator) Error!void {
    _ = args;
    var config = try Configuration.init(allocator);
    defer config.deinit();

    const extension = ".json";

    const apods_dir = try openDirAbsolute(config.apods_path, .{ .iterate = true });

    var it = apods_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        if (entry.name.len < extension.len) {
            continue;
        }

        if (!std.mem.eql(u8, entry.name[(entry.name.len - extension.len)..], extension)) {
            continue;
        }

        var file = try std.fs.openFileAbsolute(entry.name, .{ .mode = .read_only });
        const buffer = try file.readToEndAlloc(allocator, 0xFFFF);
        defer allocator.free(buffer);
        try print("{s}", .{buffer});
    }
}

pub fn main() !void {
    var gpa: GPA = GPA {};
    defer if (gpa.deinit() == .leak) panic("Memory leak.", .{});
    const allocator: Allocator = gpa.allocator();

    var args: ArgIterator = try argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse unreachable;

    const command_name = args.next() orelse {
        try print_error("No command specificed.\n", .{});
        return;
    };

    const command_function = command_map.get(command_name) orelse {
        try print_error("'{s}' is not a command", .{command_name});
        return;
    };
    return command_function(allocator, &args);
}
