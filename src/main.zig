const std = @import("std");

const GPA = std.heap.DebugAllocator(.{});
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.ArgIterator;
const argsWithAllocator = std.process.argsWithAllocator;
const StaticStringMap = std.StaticStringMap;
const print = std.debug.print;
const panic = std.debug.panic;

const Error = Allocator.Error;

const CommandFunctionPointer = *const fn(Allocator, ArgIterator) Error!void;

const command_map = StaticStringMap(CommandFunctionPointer).initComptime(.{

});

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
        try print_error("", .{});
        return;
    };
    return command_function(allocator, args);
}
