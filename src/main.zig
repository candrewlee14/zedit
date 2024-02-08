const std = @import("std");
const Terminal = @import("./Term.zig");

const util = @import("./util.zig");
const Rect = util.Rect;
const Size = util.Size;
const Cursor = util.Cursor;
const Key = util.Key;
const Mode = util.Mode;

const Config = @import("./Config.zig");

const FileBuf = @import("./FileBuf.zig");
const WindowImpl = @import("./WindowImpl.zig");

const log = @import("./log.zig");
const logger: *log.Logger = &log.logger;

pub fn assertTty() void {
    if (!std.io.getStdOut().isTty() or !std.io.getStdIn().isTty()) {
        std.debug.print("This program is intended to be run interactively.\n", .{});
        std.os.exit(1);
    }
}

const Action = union(enum) {};

const Statusline = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    window: WindowImpl = undefined,

    pub fn init(self: *Statusline) !void {
        const alloc = self.arena.allocator();
        const vtable = try alloc.create(WindowImpl.VTable);
        vtable.* = .{ .render = Self.render };
        self.window = .{ .ptr = @ptrCast(self), .vtable = vtable };
    }
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
    fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
        const self: *Self = @alignCast(@ptrCast(ctx));
        const ed = @fieldParentPtr(Editor, "statusline", self);
        try term.navCurTo(.{ .x = rect.origin.x, .y = rect.origin.y });
        const sw = term.cout.writer();
        try sw.writeAll(ed.mode.to3Char());
    }
};

const Tabline = struct {
    arena: std.heap.ArenaAllocator,
    window: WindowImpl = undefined,

    pub fn init(self: *Tabline) !void {
        const alloc = self.arena.allocator();
        const vtable = try alloc.create(WindowImpl.VTable);
        vtable.* = .{ .render = Tabline.render };
        self.window = .{ .ptr = @ptrCast(self), .vtable = vtable };
    }
    pub fn deinit(self: *Tabline) void {
        self.arena.deinit();
    }
    fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
        const self: *Tabline = @alignCast(@ptrCast(ctx));
        const ed = @fieldParentPtr(Editor, "tabline", self);
        var i: usize = 0;
        const count = ed.file_bufs.count();
        const sw = term.cout.writer();
        var x: usize = 0;
        try term.navCurTo(.{ .x = rect.origin.x, .y = rect.origin.y });
        while (i < count) : (i += 1) {
            const file_buf = ed.file_bufs.at(i);
            const name = file_buf.name orelse "untitled";
            try sw.writeAll(" ");
            if (x + name.len < rect.size.width) {
                if (i == ed.focused_file_buf) {
                    try sw.writeAll("\x1b[47m");
                    try sw.writeAll("\x1b[30m");
                }
                try sw.writeAll(name);
                if (i == ed.focused_file_buf) {
                    try sw.writeAll("\x1b[0m");
                }
            } else if (rect.size.width > 3) {
                try sw.writeAll("...");
                x += 3;
            }
        }
    }
};

const Editor = struct {
    arena: std.heap.ArenaAllocator,
    term: Terminal,
    action_queue: std.fifo.LinearFifo(Action, .{ .Static = 4096 }),
    window: WindowImpl = undefined,

    mode: Mode = .normal,
    config: Config = undefined,

    tabline: Tabline = undefined,
    statusline: Statusline = undefined,

    children_win_cache: std.ArrayListUnmanaged(*const WindowImpl) = undefined,
    focused_file_buf: usize = 0,
    file_bufs: std.SegmentedList(FileBuf, 8) = undefined,

    pub fn init(self: *Editor) !void {
        const alloc = self.arena.allocator();
        try self.term.initScreen();
        try self.term.hideCursor();
        try self.term.enableRawMode();
        try self.term.clear();
        try self.term.cout.flush();

        try self.config.init(alloc);

        self.children_win_cache = try std.ArrayListUnmanaged(*const WindowImpl).initCapacity(alloc, 8);
        self.file_bufs = std.SegmentedList(FileBuf, 8){};

        // set up file buffer 0
        try self.file_bufs.append(alloc, FileBuf{
            .name = "untitled",
            .arena = std.heap.ArenaAllocator.init(alloc),
        });
        const file_buf0 = self.file_bufs.at(0);
        try file_buf0.init();
        try self.children_win_cache.append(alloc, &file_buf0.window);

        // set up file buffer 1
        try self.file_bufs.append(alloc, FileBuf{
            .name = "untitled2",
            .arena = std.heap.ArenaAllocator.init(alloc),
        });
        const file_buf1 = self.file_bufs.at(1);
        try file_buf1.init();
        try self.children_win_cache.append(alloc, &file_buf1.window);

        // set up tabline
        self.tabline = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
        try self.tabline.init();
        try self.children_win_cache.append(alloc, &self.tabline.window);

        // set up statusline
        self.statusline = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
        try self.statusline.init();
        // TODO: uncomment
        try self.children_win_cache.append(alloc, &self.statusline.window);

        // set up global logger window
        try self.children_win_cache.append(alloc, &logger.window);

        // set up window with full size
        const size = try self.term.getSize();
        const vtable = try alloc.create(WindowImpl.VTable);
        vtable.* = .{ .getChildren = Editor.getChildren, .layoutChildren = Editor.layoutChildren };
        self.window = .{
            .ptr = @ptrCast(self),
            .vtable = vtable,
            .rect = Rect{ .origin = .{ .x = 0, .y = 0 }, .size = size },
        };
    }

    pub fn deinit(self: *Editor) void {
        self.arena.deinit();

        self.term.deinitScreen();
        self.term.disableRawMode();
        const sw = self.term.cout.writer();
        sw.writeAll("Goodbye from zedit!\n") catch {};
        self.term.showCursor() catch {};
        self.term.cout.flush() catch {};
    }

    fn getChildren(ctx: *anyopaque) []*const WindowImpl {
        const self: *Editor = @alignCast(@ptrCast(ctx));
        return self.children_win_cache.items;
    }

    fn layoutChildren(ctx: *anyopaque) anyerror!void {
        const self: *Editor = @alignCast(@ptrCast(ctx));
        const count = self.file_bufs.count();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const file_buf: *FileBuf = self.file_bufs.at(i);
            file_buf.window.active = i == self.focused_file_buf;

            var x: usize = 0;
            var width: usize = self.window.rect.size.width;
            if (file_buf.window.with_border) {
                x = 1;
                width -= 2;
            }
            file_buf.window.rect = .{
                .origin = .{ .x = x, .y = 1 },
                .size = .{
                    .width = width,
                    .height = self.window.rect.size.height - 2,
                },
            };
        }
        self.tabline.window.rect.size = .{
            .width = self.window.rect.size.width,
            .height = 1,
        };
        // put logger on the right side
        const logger_width = 30;
        logger.window.rect = .{
            .origin = .{ .x = self.window.rect.size.width - logger_width, .y = 0 },
            .size = .{ .width = logger_width, .height = self.window.rect.size.height },
        };

        self.statusline.window.rect = .{
            .origin = .{ .x = 0, .y = self.window.rect.size.height - 1 },
            .size = .{ .width = self.window.rect.size.width, .height = 1 },
        };
    }

    /// Returns if we should quit
    pub fn handleKey(self: *Editor, key: Key) !bool {
        const fb: *FileBuf = self.file_bufs.at(self.focused_file_buf);
        switch (self.mode) {
            .normal => {
                if (self.config.normal_actions.get(key)) |action| switch (action) {
                    .insert => {
                        try fb.boundCursor();
                        self.mode = .edit;
                    },
                    .insert_after => {
                        try fb.moveCursors(0, 1);
                        try fb.boundCursor();
                        self.mode = .edit;
                    },
                    .insert_at_eol => {
                        try fb.endline();
                        self.mode = .edit;
                    },
                    .move_up => try fb.moveCursors(-1, 0),
                    .move_down => try fb.moveCursors(1, 0),
                    .move_left => try fb.moveCursors(0, -1),
                    .move_right => try fb.moveCursors(0, 1),
                    .enter => try fb.normalEnter(),
                    .insert_newline_above => {
                        try fb.createNewLine(0);
                        self.mode = .edit;
                    },
                    .insert_newline_below => {
                        try fb.createNewLine(1);
                        self.mode = .edit;
                    },
                    .delete => {
                        try fb.moveCursors(0, 1);
                        try fb.backspace();
                    },
                    .add_cur_up => try fb.addCursors(-1),
                    .add_cur_down => try fb.addCursors(1),
                    .home => try fb.homeline(),
                    .end => try fb.endline(),
                    .quit => return true,
                    else => logger.log("{any}", .{action}),
                    // handle non-configured actions
                } else switch (key.code) {
                    .Char => |byte| {
                        if (key.ctrl) logger.log("CTRL+{c} ({d})", .{ byte, byte });
                    },
                    else => logger.log("{any}", .{key.code}),
                }
            },
            .edit => {
                if (self.config.edit_actions.get(key)) |action| switch (action) {
                    .to_normal => self.mode = .normal,
                    .move_up => try fb.moveCursors(-1, 0),
                    .move_down => try fb.moveCursors(1, 0),
                    .move_left => try fb.moveCursors(0, -1),
                    .move_right => try fb.moveCursors(0, 1),
                    .enter => try fb.addNewline(),
                    .add_cur_up => try fb.addCursors(-1),
                    .add_cur_down => try fb.addCursors(1),
                    .backspace => try fb.backspace(),
                    .home => try fb.homeline(),
                    .end => try fb.endline(),
                    .delete => {
                        try fb.moveCursors(0, 1);
                        try fb.backspace();
                    },
                    .quit => return true,
                    // else => logger.log("{any}", .{action}),
                    // handle non-configured actions
                } else switch (key.code) {
                    .Char => |byte| {
                        try fb.insertText(&.{byte});
                    },
                    else => logger.log("{any}", .{key.code}),
                }
            },
            else => @panic("Unimplemented mode"),
        }
        return false;
    }
};

pub fn main() !void {
    assertTty();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .leak => @panic("Memory leak detected!"),
        .ok => {},
    };
    const alloc = gpa.allocator();
    try log.init(alloc);
    defer log.deinit();

    var ed: Editor = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .term = .{
            .cout = std.io.bufferedWriter(std.io.getStdOut().writer()),
            .cin = std.io.bufferedReader(std.io.getStdIn().reader()),
        },
        .action_queue = std.fifo.LinearFifo(Action, .{ .Static = 4096 }).init(),
    };
    try ed.init();
    defer ed.deinit();

    while (true) {
        const size = try ed.term.getSize();
        ed.window.rect = Rect{
            .origin = .{ .x = 0, .y = 0 },
            .size = size,
        };
        try ed.term.clear();
        try ed.window.render(&ed.term);
        try ed.term.cout.flush();
        const key = try ed.term.readKey();
        if (try ed.handleKey(key)) break;
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
