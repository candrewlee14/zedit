const std = @import("std");
const Terminal = @import("./Term.zig");
const util = @import("./util.zig");
const Rect = util.Rect;
const Size = util.Size;
const Cursor = util.Cursor;

const FileBuf = @import("./FileBuf.zig");
const WindowImpl = @import("./WindowImpl.zig");

pub fn assertTty() void {
    if (!std.io.getStdOut().isTty() or !std.io.getStdIn().isTty()) {
        std.debug.print("This program is intended to be run interactively.\n", .{});
        std.os.exit(1);
    }
}

const Action = union(enum) {};

const Tabline = struct {
    arena: std.heap.ArenaAllocator,
    window: WindowImpl = undefined,

    pub fn init(self: *Tabline) !void {
        const alloc = self.arena.allocator();
        const vtable = try alloc.create(WindowImpl.VTable);
        vtable.* = .{
            .render = Tabline.render,
            .getChildren = Tabline.getChildren,
            .layoutChildren = Tabline.layoutChildren,
        };
        self.window = .{
            .ptr = @ptrCast(self),
            .vtable = vtable,
            .rect = Rect{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = 0, .height = 1 },
            },
        };
    }
    pub fn deinit(self: *Tabline) void {
        self.arena.deinit();
    }
    fn getChildren(ctx: *anyopaque) []*const WindowImpl {
        _ = ctx;
        return &.{};
    }
    fn layoutChildren(ctx: *anyopaque) anyerror!void {
        _ = ctx;
        return;
    }

    fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
        _ = term;
        const self: *Tabline = @alignCast(@ptrCast(ctx));
        const ed = @fieldParentPtr(Editor, "tabline", self);
        var i: usize = 0;
        const count = ed.file_bufs.count();
        const sw = ed.term.cout.writer();
        var x: usize = 0;
        try ed.term.navCurTo(.{ .x = 0, .y = 0 });
        while (i < count) : (i += 1) {
            const file_buf = ed.file_bufs.at(i);
            const name = file_buf.name;
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

    tabline: Tabline = undefined,

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

        const size = try self.term.getSize();
        const vtable = try alloc.create(WindowImpl.VTable);
        vtable.* = .{
            .render = Editor.render,
            .getChildren = Editor.getChildren,
            .layoutChildren = Editor.layoutChildren,
        };
        self.window = .{
            .ptr = @ptrCast(self),
            .vtable = vtable,
            .rect = Rect{
                .origin = .{ .x = 0, .y = 0 },
                .size = size,
            },
            .with_border = false,
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
        self.tabline.window.rect.size.width = self.window.rect.size.width;
    }

    fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
        _ = rect;
        _ = term;
        _ = ctx;
        return;
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
        const fb = ed.file_bufs.at(ed.focused_file_buf);
        ed.window.rect = Rect{
            .origin = .{ .x = 0, .y = 0 },
            .size = size,
        };
        try ed.term.clear();
        try ed.window.render(&ed.term);
        try ed.term.cout.flush();
        const key = try ed.term.readKey();
        switch (key.code) {
            .Char => |byte| {
                if (key.ctrl) {
                    const new_byte = byte | 0x40;
                    std.debug.print("CTRL+{c} ({d})", .{ new_byte, new_byte });
                    if (new_byte == 'q' or new_byte == 'Q') break;
                } else if (key.alt) {
                    std.debug.print("ALT+{c} ({d})", .{ byte, byte });
                    if (byte == 'J') {
                        try fb.addCursors(1);
                    } else if (byte == 'K') {
                        try fb.addCursors(-1);
                    }
                } else {
                    try fb.insertText(&.{byte});
                }
            },
            .End => try fb.endline(),
            .Backspace => try fb.backspace(),
            .Enter => try fb.moveNewline(),
            .Home => try fb.homeline(),
            .Arrow => |dir| switch (dir) {
                .up => try fb.moveCursors(-1, 0),
                .down => try fb.moveCursors(1, 0),
                .left => try fb.moveCursors(0, -1),
                .right => try fb.moveCursors(0, 1),
            },
            else => {
                std.debug.print("{any}\n\r", .{key});
            },
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
