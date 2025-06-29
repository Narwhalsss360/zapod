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
    NoAPIkey,
    InvalidDateFormat,
    MissingArgument,
    InvalidAPIKey,
    InvalidArgument,
    FetchError
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
    getErrorSetOf(File.readToEndAlloc) ||
    std.posix.MakeDirError ||
    std.json.ParseError(std.json.Scanner) ||
    getErrorSetOf(std.http.Client.fetch) ||
    std.fs.Dir.AccessError;

const Configuration = struct {
    api_key: ?[]const u8 = undefined,
    apods_path: []const u8 = undefined,
    apods_path_alloc: bool = false,
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

        return Configuration {
            .env = env,
            .api_key = env.get("APOD_API_KEY"),
            .apods_path = apods_path,
            .apods_path_alloc = apods_path_alloc,
            .allocator = allocator
        };
    }

    pub fn deinit(self: *Configuration) void {
        self.env.deinit();
        if (self.apods_path_alloc) {
            self.allocator.free(self.apods_path);
        }
    }
};

const APODDate = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn init(date: []const u8) APODManagerError!APODDate {
        if (date.len < 4 + 1 + 2 + 1 + 2) {
            return APODManagerError.InvalidDateFormat;
        }

        return APODDate {
            .year = std.fmt.parseInt(u16, date[0..4], 10) catch {
                return APODManagerError.InvalidDateFormat;
            },
            .month = std.fmt.parseInt(u8, date[5..7], 10) catch {
                return APODManagerError.InvalidDateFormat;
            },
            .day = std.fmt.parseInt(u8, date[8..10], 10) catch {
                return APODManagerError.InvalidDateFormat;
            }
        };
    }

    pub fn str(self: *const APODDate) ![10]u8 {
        var buffer: [10]u8 = [10]u8 { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        var buffer_stream = std.io.fixedBufferStream(&buffer);
        try buffer_stream.writer().print("{s}", .{self});
        return buffer;
    }

    pub fn format(
        self: *const APODDate,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        _ = .{ fmt, options };

        try writer.print(
            "{d:04.}-{d:02.}-{d:02.}",
            .{ self.year, self.month, self.day }
        );
    }
};

const CommandFunctionPointer = *const fn(Allocator, *ArgIterator) Error!void;

const CommandFunction = struct {
    function: CommandFunctionPointer = undefined,
    description: []const u8 = undefined,
};

const command_map = StaticStringMap(CommandFunction).initComptime(.{
    .{
        "help",
        CommandFunction {
            .function = helpCommand,
            .description = "Show help. usage: <command name: optional string>",
        },
    },
    .{
        "list",
        CommandFunction {
            .function = listCommand,
            .description = "List all locally saved APODs.",
        },
    },
    .{
        "fetch-single",
        CommandFunction {
            .function = fetchSingle,
            .description = "Fetch an apod. usage: <date: YYYY-MM-DD>",
        },
    },
    .{
        "fetch-random",
        CommandFunction {
            .function = fetchRandom,
            .description = "Fetch a random count of apods. usage: <count: 1-100>"
        }
    },
    .{
        "fetch-range",
        CommandFunction {
            .function = fetchRange,
            .description = "Fetch a range of apods. usage: <start_date: YYYY-MM-DD> <end_date: YYYY-MM-DD>"
        }
    },
    .{
        "details",
        CommandFunction {
            .function = details,
            .description = "Show details of an APOD that exists locally. usage: <date: YYYY-MM-DD>"
        }
    }
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

    pub fn format(
        self: *const APOD,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        _ = .{ options };
 
        if (fmt.len > 0 and fmt[0] == 'D') {
            try writer.print(
                \\{s} ({s}) - {s} (C) {s}
                \\{s}
                \\Media:{s}
                ,
                .{
                    self.date, self.media_type, self.title, self.copyright orelse "",
                    self.explanation,
                    self.hdurl orelse self.url
                }
            );
            return;
        }

        try writer.print(
            "{s} ({s}) - {s}",
            .{ self.date, self.media_type, self.title }
        );
    }
};

const GET_ENDPOINT = "https://api.nasa.gov/planetary/apod?api_key=";
const COUNT_PARAM = "&count=";
const START_DATE_PARAM = "&start_date=";
const END_DATE_PARAM = "&end_date=";
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
    _ = allocator;
    const command_name = args.next() orelse {
        try print("zapod help:\n", .{});
        for (command_map.keys()) |command_name| {
            try print("    {s}: {s}\n", .{command_name, command_map.get(command_name).?.description});
        }
        return;
    };

    const command = command_map.get(command_name) orelse {
        try print_error("'{s}' is not a command, use help without arguments to list commands.\n", .{command_name});
        return;
    };

    try print("    {s}: {s}\n", .{command_name, command.description});
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

        const absolute = try std.fs.path.join(allocator, &[_][]const u8 { config.apods_path, entry.name });
        defer allocator.free(absolute);

        var file = try std.fs.openFileAbsolute(absolute, .{ .mode = .read_only });
        const buffer = try file.readToEndAlloc(allocator, 0xFFFF);
        defer allocator.free(buffer);

        const apod = try std.json.parseFromSlice(APOD, allocator, buffer, .{
            .ignore_unknown_fields = true
        });
        defer apod.deinit();

        try print("{s}\n", .{apod.value});
    }
}

fn loadLocal(allocator: Allocator, date: APODDate) !std.json.Parsed(APOD) {
    var config = try Configuration.init(allocator);
    defer config.deinit();

    const file_name = try date.str() ++ ".json";
    const absolute = try std.fs.path.join(allocator, &[_][]const u8 { config.apods_path, file_name });
    defer allocator.free(absolute);

    var file = try std.fs.openFileAbsolute(absolute, .{ .mode = .read_only });
    const buffer = try file.readToEndAlloc(allocator, 0xFFFF);
    defer allocator.free(buffer);
    return std.json.parseFromSlice(APOD, allocator, buffer, .{
        .ignore_unknown_fields = true
    });
}

fn headersLength(header_buffer: []const u8) usize {
    var i: usize = 0;
    while (i < header_buffer.len - 1) : (i += 1) {
        if (header_buffer[i] == '\r' and header_buffer[i + 1] == '\n') {
            if (i + 3 >= header_buffer.len) {
                return header_buffer.len;
            }
            if (header_buffer[i + 2] == '\r' and header_buffer[i + 3] == '\n') {
                return i;
            }
        }
    }
    return header_buffer.len;
}

fn fetchSingleEndPoint(api_key: []const u8, date: [10]u8) !*const [100]u8 {
    if (api_key.len != 40) {
        return APODManagerError.InvalidAPIKey;
    }
    try print("{s}\n", .{date});
    return
        GET_ENDPOINT ++
        (api_key[0..40].*)  ++
        "&date=" ++ date;
}

fn fetchRandomEndPoint(allocator: Allocator, api_key: []const u8, count: u8) ![]u8 {
    if (api_key.len != 40) {
        return APODManagerError.InvalidAPIKey;
    }
    const endpoint = try allocator.alloc(u8, GET_ENDPOINT.len + 40 + COUNT_PARAM.len + 3);
    std.mem.copyForwards(u8, endpoint, GET_ENDPOINT);
    std.mem.copyForwards(u8, endpoint[GET_ENDPOINT.len..], api_key);
    std.mem.copyForwards(u8, endpoint[(GET_ENDPOINT.len + 40)..], COUNT_PARAM);

    var count_buffer: [3]u8 = [3]u8 { 0, 0, 0 };
    var count_buffer_stream = std.io.fixedBufferStream(&count_buffer);
    try count_buffer_stream.writer().print("{d:03}", .{count});
    std.mem.copyForwards(u8, endpoint[(GET_ENDPOINT.len + 40 + COUNT_PARAM.len)..], &count_buffer);
    return endpoint;
}

fn fetchRangeEndPoint(api_key: []const u8, start_date: [10]u8, end_date: [10]u8) !*const [GET_ENDPOINT.len + 40 + START_DATE_PARAM.len + 10 + END_DATE_PARAM.len + 10]u8 {
    if (api_key.len != 40) {
        return APODManagerError.InvalidAPIKey;
    }
    return
        GET_ENDPOINT ++
        (api_key[0..40].*) ++
        START_DATE_PARAM ++ start_date ++
        END_DATE_PARAM ++ end_date;
}

fn fetchSingle(allocator: Allocator, args: *ArgIterator) Error!void {
    var config = try Configuration.init(allocator);
    defer config.deinit();

    const date_arg = args.next() orelse {
        try print_error("Missing required argument: date YYYY-MM-DD", .{});
        return APODManagerError.MissingArgument;
    };
    const date_string = try (try APODDate.init(date_arg)).str();

    const apods_dir = try openDirAbsolute(config.apods_path, .{ .iterate = true });

    if (apods_dir.access(date_string ++ ".json", .{})) {
        try print_error("APOD {s} already exists locally.", .{date_string});
        return;
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }

    if (config.api_key == null) {
        try print_error("An API Key is required for this operation.", .{});
        return APODManagerError.NoAPIkey;
    }

    var header_buffer: [0x1FFF]u8 = undefined;
    var response_storage_buffer: [0x7FFF]u8 = undefined;
    var response_storage=  std.ArrayListUnmanaged(u8).initBuffer(&response_storage_buffer);
    const url = (try fetchSingleEndPoint(config.api_key.?, date_string)).*;
    var client = std.http.Client { .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = &url
        },
        .server_header_buffer = &header_buffer,
        .response_storage = .{
            .static = &response_storage
        }
    });

    if (result.status != std.http.Status.ok) {
        try print_error("Fetch error (Status: {d})\nHeaders:\n{s}\nContent:{s}\n", .{result.status, header_buffer[0..headersLength(&header_buffer)], response_storage.items});
        return APODManagerError.FetchError;
    }
    const apod = try std.json.parseFromSlice(APOD, allocator, response_storage.items, .{
        .ignore_unknown_fields = true
    });
    defer apod.deinit();

    const absolute = try std.fs.path.join(allocator, &[_][]const u8 { config.apods_path, date_string ++ ".json" });
    defer allocator.free(absolute);
    const file = try std.fs.createFileAbsolute(absolute, .{ .exclusive = true });
    defer file.close();

    try std.json.stringify(apod.value, .{ .whitespace = .indent_4 }, file.writer());
    try print("{s}.json\n", .{apod.value.date});
}

fn fetchRandom(allocator: Allocator, args: *ArgIterator) Error!void {
    var config = try Configuration.init(allocator);
    defer config.deinit();

    if (config.api_key == null) {
        try print_error("An API Key is required for this operation.", .{});
        return APODManagerError.NoAPIkey;
    }

    const count_string = args.next() orelse {
        try print_error("Missing 'count' argument.", .{});
        return APODManagerError.MissingArgument;
    };
    const count = try std.fmt.parseInt(u8, count_string, 10);

    if (count == 0 or count > 100) {
        try print_error("'count' must be between 1 and 100.", .{});
        return APODManagerError.InvalidArgument;
    }

    var header_buffer: [0x1FFF]u8 = undefined;
    var response_storage_buffer: [0x7FFF]u8 = undefined;
    var response_storage=  std.ArrayListUnmanaged(u8).initBuffer(&response_storage_buffer);
    const url = try fetchRandomEndPoint(allocator,config.api_key.?, count);
    defer allocator.free(url);
    var client = std.http.Client { .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = url
        },
        .server_header_buffer = &header_buffer,
        .response_storage = .{
            .static = &response_storage
        }
    });

    if (result.status != std.http.Status.ok) {
        try print_error("Fetch error (Status: {d})\nHeaders:\n{s}\nContent:{s}\n", .{result.status, header_buffer[0..headersLength(&header_buffer)], response_storage.items});
        return APODManagerError.FetchError;
    }

    const apods = try std.json.parseFromSlice([]APOD, allocator, response_storage.items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer apods.deinit();

    for (apods.value) |apod| {
        const absolute = try std.fs.path.join(allocator, &[_][]const u8 { config.apods_path, (apod.date[0..10]).* ++ ".json" });
        defer allocator.free(absolute);
        const file = try std.fs.createFileAbsolute(absolute, .{});
        defer file.close();

        try std.json.stringify(apod, .{ .whitespace = .indent_4 }, file.writer());
        try print("{s}.json\n", .{apod.date});
    }
}

fn fetchRange(allocator: Allocator, args: *ArgIterator) !void {
    var config = try Configuration.init(allocator);
    defer config.deinit();

    if (config.api_key == null) {
        try print_error("An API Key is required for this operation.", .{});
        return APODManagerError.NoAPIkey;
    }

    const start_date_string = args.next() orelse {
        try print_error("Missing 'start_date' argument.", .{});
        return APODManagerError.MissingArgument;
    };
    const start_date = try (try APODDate.init(start_date_string)).str();

    const end_date_string = args.next() orelse {
        try print_error("Missing 'end_date' argument.", .{});
        return APODManagerError.MissingArgument;
    };
    const end_date = try (try APODDate.init(end_date_string)).str();

    var header_buffer: [0x1FFF]u8 = undefined;
    var response_storage_buffer: [0x7FFF]u8 = undefined;
    var response_storage=  std.ArrayListUnmanaged(u8).initBuffer(&response_storage_buffer);
    const url = (try fetchRangeEndPoint(config.api_key.?, start_date, end_date)).*;
    var client = std.http.Client { .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = &url
        },
        .server_header_buffer = &header_buffer,
        .response_storage = .{
            .static = &response_storage
        }
    });

    if (result.status != std.http.Status.ok) {
        try print_error("Fetch error (Status: {d})\nHeaders:\n{s}\nContent:{s}\n", .{result.status, header_buffer[0..headersLength(&header_buffer)], response_storage.items});
        return APODManagerError.FetchError;
    }

    const apods = try std.json.parseFromSlice([]APOD, allocator, response_storage.items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer apods.deinit();

    for (apods.value) |apod| {
        const absolute = try std.fs.path.join(allocator, &[_][]const u8 { config.apods_path, (apod.date[0..10]).* ++ ".json" });
        defer allocator.free(absolute);
        const file = try std.fs.createFileAbsolute(absolute, .{});
        defer file.close();

        try std.json.stringify(apod, .{ .whitespace = .indent_4 }, file.writer());
        try print("{s}.json\n", .{apod.date});
    }
}

fn details(allocator: Allocator, args: *ArgIterator) Error!void {
    const date_arg = args.next() orelse {
        try print_error("Missing required argument: date YYYY-MM-DD", .{});
        return APODManagerError.MissingArgument;
    };
    const apod = try loadLocal(allocator, try APODDate.init(date_arg));
    defer apod.deinit();

    try print("{D}", .{apod.value});
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
    return command_function.function(allocator, &args);
}
