const std = @import("std");
const WindowImpl = @import("./WindowImpl.zig");
const Terminal = @import("./Term.zig");
const util = @import("util.zig");
const Rect = util.Rect;

pub var logger: Logger = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    logger = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    try logger.init();
}

pub fn deinit() void {
    logger.deinit();
}

pub const Logger = struct {
    arena: std.heap.ArenaAllocator,
    window: WindowImpl = undefined,
    logs: std.ArrayListUnmanaged([]const u8) = undefined,

    pub fn init(self: *Logger) !void {
        const alloc = self.arena.allocator();
        const vtable = try alloc.create(WindowImpl.VTable);
        vtable.* = .{ .render = Logger.render };
        self.window = .{ .ptr = @ptrCast(self), .vtable = vtable, .with_border = true };
        self.logs = try std.ArrayListUnmanaged([]const u8).initCapacity(alloc, 1024);
    }
    pub fn deinit(self: *Logger) void {
        self.arena.deinit();
    }
    pub fn log(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.arena.allocator();
        const log_str = std.fmt.allocPrint(alloc, fmt, args) catch unreachable;
        self.logs.append(alloc, log_str) catch unreachable;
    }
    fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
        const self: *Logger = @alignCast(@ptrCast(ctx));
        const sw = term.cout.writer();
        // only render the last rect.size.height lines
        const slice = if (self.logs.items.len > rect.size.height)
            self.logs.items[self.logs.items.len - rect.size.height ..]
        else
            self.logs.items;
        for (slice, 0..) |log_str, y| {
            try term.navCurTo(.{ .x = rect.origin.x, .y = rect.origin.y + y });
            const trim_log_str = log_str[0..@min(log_str.len, rect.size.width)];
            try sw.writeAll(trim_log_str);
            for (trim_log_str.len..rect.size.width) |_| {
                try sw.writeByte(' ');
            }
        }
        for (slice.len..rect.size.height) |y| {
            try term.navCurTo(.{ .x = rect.origin.x, .y = rect.origin.y + y });
            for (0..rect.size.width) |_| {
                try sw.writeByte(' ');
            }
        }
    }
};
