const std = @import("std");
const Terminal = @import("./Term.zig");
const util = @import("./util.zig");
const Rect = util.Rect;
const Size = util.Size;

pub const WindowImpl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        render: *const fn (ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void,
    };

    pub fn render(self: *WindowImpl, term: *Terminal, rect: Rect, with_border: bool) anyerror!void {
        if (with_border) {
            for (0..rect.size.height) |i| {
                if (i == 0) {
                    try term.writeAt(.{ .x = rect.origin.x, .y = rect.origin.y }, "┌");
                    try term.writeAt(.{ .x = rect.origin.x + rect.size.width - 1, .y = rect.origin.y }, "┐");
                    for (1..rect.size.width - 1) |j| {
                        try term.writeAt(.{ .x = rect.origin.x + j, .y = rect.origin.y }, "─");
                    }
                } else if (i == rect.size.height - 1) {
                    try term.writeAt(.{ .x = rect.origin.x, .y = rect.origin.y + i }, "└");
                    try term.writeAt(.{ .x = rect.origin.x + rect.size.width - 1, .y = rect.origin.y + i }, "┘");
                    for (1..rect.size.width - 1) |j| {
                        try term.writeAt(.{ .x = rect.origin.x + j, .y = rect.origin.y + i }, "─");
                    }
                } else {
                    try term.writeAt(.{ .x = rect.origin.x, .y = rect.origin.y + i }, "│");
                    try term.writeAt(.{ .x = rect.origin.x + rect.size.width - 1, .y = rect.origin.y + i }, "│");
                }
            }
            try self.vtable.render(self.ptr, term, Rect{
                .origin = .{ .x = rect.origin.x + 1, .y = rect.origin.y + 1 },
                .size = Size{
                    .width = rect.size.width - 2,
                    .height = rect.size.height - 2,
                },
            });
        } else {
            try self.vtable.render(self.ptr, term, rect);
        }
    }
};

pub fn assertTty() void {
    if (!std.io.getStdOut().isTty() or !std.io.getStdIn().isTty()) {
        std.debug.print("This program is intended to be run interactively.\n", .{});
        std.os.exit(1);
    }
}

const Action = union(enum) {};

const Cursor = struct {
    line: usize,
    col: usize,
    // selection_len: ?usize = null,

    pub fn lessThan(_: void, self: Cursor, other: Cursor) bool {
        return self.line < other.line or (self.line == other.line and self.col < other.col);
    }
};

const Editor = struct {
    term: Terminal,
    lines: std.ArrayList(?std.ArrayListUnmanaged(u8)),
    action_queue: std.fifo.LinearFifo(Action, .{ .Static = 4096 }),
    cur_scroll: usize = 0,
    cursors: std.ArrayList(Cursor),
    window: WindowImpl = undefined,

    pub fn init(self: *Editor) !void {
        const vtable = try self.lines.allocator.create(WindowImpl.VTable);
        vtable.render = Editor.render;
        self.window = .{
            .ptr = @ptrCast(self),
            .vtable = vtable,
        };
        try self.lines.append(try std.ArrayListUnmanaged(u8).initCapacity(self.lines.allocator, 64));
        try self.term.initScreen();
        try self.term.hideCursor();
        try self.term.enableRawMode();
        try self.term.clear();
        try self.term.showCursor();
        try self.term.cout.flush();
        try self.cursors.append(.{ .line = 0, .col = 0 });
    }

    pub fn deinit(self: *Editor) void {
        self.lines.allocator.destroy(self.window.vtable);
        self.term.deinitScreen();
        self.term.disableRawMode();
        for (self.lines.items) |*line_o| {
            if (line_o.*) |*line| {
                line.deinit(self.lines.allocator);
            }
        }
        self.lines.deinit();
        self.cursors.deinit();
        self.action_queue.deinit();
    }

    pub fn insertText(self: *Editor, text: []const u8) !void {
        for (self.cursors.items) |*cursor| {
            while (cursor.line >= self.lines.items.len) {
                try self.lines.append(try std.ArrayListUnmanaged(u8).initCapacity(self.lines.allocator, 64));
            }
            const line = &(self.lines.items[cursor.line].?);
            if (cursor.col >= line.items.len) {
                try line.appendNTimes(self.lines.allocator, ' ', cursor.col - line.items.len);
            }
            try line.insertSlice(self.lines.allocator, cursor.col, text);
            cursor.col += text.len;
        }
    }

    fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
        const self: *Editor = @alignCast(@ptrCast(ctx));
        const size = rect.size;
        for (0..size.height) |i| {
            const sw = term.cout.writer();
            try term.navCurTo(.{ .x = rect.origin.x, .y = rect.origin.y + i });
            const str_i = self.cur_scroll + i;
            if (str_i < self.lines.items.len) {
                if (self.lines.items[str_i]) |line| {
                    const line_len = line.items.len;
                    if (line_len > size.width) {
                        const more_str = "...";
                        try sw.writeAll(line.items[0 .. size.width - more_str.len - 1]);
                        try sw.writeAll(more_str);
                    } else {
                        try sw.writeAll(line.items);
                    }
                }
            }
        }
        for (self.cursors.items) |cursor| {
            if (cursor.line < self.cur_scroll and cursor.line >= self.cur_scroll + size.height) continue;
            try self.term.navCurTo(.{
                .x = rect.origin.x + cursor.col,
                .y = rect.origin.y + cursor.line - self.cur_scroll,
            });

            const sw = term.cout.writer();
            // this sets the background white and foreground black
            try sw.writeAll("\x1b[47m");
            try sw.writeAll("\x1b[30m");
            if (cursor.line >= self.lines.items.len) {
                try sw.writeAll(" ");
            } else {
                if (self.lines.items[cursor.line]) |line| {
                    const line_len = line.items.len;
                    if (cursor.col < line_len) {
                        // TODO: this should be a unicode codepoint, not just a byte
                        try sw.writeByte(line.items[cursor.col]);
                    } else {
                        try sw.writeAll(" ");
                    }
                } else {
                    try sw.writeAll(" ");
                }
            }
            try sw.writeAll("\x1b[0m");
        }
        try self.printCursorInfo();
    }

    inline fn updateCurScroll(self: *Editor, cursor: Cursor, size: Size) void {
        if (cursor.line >= self.cur_scroll + size.height) {
            self.cur_scroll = cursor.line - size.height + 1;
        } else if (cursor.line < self.cur_scroll) {
            self.cur_scroll = cursor.line;
        }
    }

    pub fn moveCursors(self: *Editor, dline: isize, dcol: isize) !void {
        const size = try self.term.getSize();
        var idx: usize = self.cursors.items.len;
        while (idx > 0) : (idx -= 1) {
            const i = idx - 1;
            const cursor = &self.cursors.items[i];
            var new_line = @as(isize, @intCast(cursor.line)) + dline;
            new_line = @max(new_line, 0);
            new_line = @min(new_line, @as(isize, @intCast(self.lines.items.len - 1)));
            var new_col = @as(isize, @intCast(cursor.col)) + dcol;
            new_col = @max(new_col, 0);
            cursor.line = @intCast(new_line);

            self.updateCurScroll(cursor.*, size);

            const line_o = self.lines.items[cursor.line];
            if (line_o) |line| {
                new_col = @min(new_col, @as(isize, @intCast(line.items.len)));
            } else {
                new_col = 0;
            }
            cursor.col = @intCast(new_col);
            // remove duplicates (assuming sorted)
            if (i < self.cursors.items.len - 1 and self.cursors.items[i + 1].line == cursor.line) {
                _ = self.cursors.orderedRemove(i);
            }
        }
    }

    pub fn addCursorIfNoDuplicates(self: *Editor, cursor: Cursor, checks: []const Cursor) !void {
        var any_same_col = false;
        for (checks) |cur| {
            if (cur.line == cursor.line and cur.col == cursor.col) {
                any_same_col = true;
                break;
            }
        }
        if (!any_same_col) {
            try self.cursors.append(cursor);
        }
        std.mem.sortUnstable(Cursor, self.cursors.items, {}, Cursor.lessThan);
    }

    pub fn addCursors(self: *Editor, dline: isize) !void {
        std.debug.assert(dline == 1 or dline == -1);
        const item_count = self.cursors.items.len;
        std.mem.sortUnstable(Cursor, self.cursors.items[0..item_count], {}, Cursor.lessThan);
        for (self.cursors.items[0..item_count], 0..) |cursor, i| {
            const new_line = @as(isize, @intCast(cursor.line)) + dline;
            if (new_line < 0) continue;
            if (new_line > @as(isize, @intCast(self.lines.items.len - 1))) continue;
            const new_cursor = Cursor{ .line = @intCast(new_line), .col = cursor.col };

            var check_idx: usize = i;
            // find the first cursor that is on the same line in the sorted cursors list
            if (dline > 0) {
                while (check_idx < item_count and self.cursors.items[check_idx].line < new_cursor.line) {
                    check_idx += 1;
                }
            } else if (dline < 0) {
                while (check_idx > 0 and self.cursors.items[check_idx].line > new_cursor.line) {
                    check_idx -= 1;
                }
            } else unreachable;
            // check if any of the same-line cursors are in the same col (duplicates)
            var any_same_col = false;
            while (check_idx >= 0 and check_idx < item_count and self.cursors.items[check_idx].line == new_cursor.line) {
                const check_cur = self.cursors.items[check_idx];
                if (check_cur.col == new_cursor.col) {
                    any_same_col = true;
                    break;
                }
                if (dline > 0) {
                    check_idx += 1;
                } else if (dline < 0) {
                    if (check_idx > 0) break;
                    check_idx -= 1;
                } else unreachable;
            }
            // if there are no duplicates, add the new cursor
            if (!any_same_col) {
                try self.cursors.append(new_cursor);
            }
        }
        std.mem.sortUnstable(Cursor, self.cursors.items, {}, Cursor.lessThan);
    }

    pub fn printCursorInfo(self: *Editor) !void {
        const size = try self.term.getSize();
        for (self.cursors.items, 0..) |cursor, i| {
            const sw = self.term.cout.writer();
            // goto right side top of screen
            try sw.print("\x1b[{d};{d}H", .{ i + 1, size.width - 10 });
            try sw.print("({d}, {d}) ", .{ cursor.line, cursor.col });
        }
    }

    pub fn insertLine(self: *Editor, idx: usize, new_line: std.ArrayListUnmanaged(u8)) !void {
        try self.lines.insert(idx, new_line);
        for (self.cursors.items) |*cursor| {
            if (cursor.line >= idx) {
                cursor.line += 1;
            }
        }
    }

    pub fn removeLine(self: *Editor, idx: usize) !void {
        _ = self.lines.orderedRemove(idx);
        for (self.cursors.items) |*cursor| {
            if (cursor.line >= idx) {
                // TODO: if the cursor == idx, should we just delete the cursor?
                cursor.line -= 1;
            }
        }
    }

    pub fn moveNewline(self: *Editor) !void {
        const size = try self.term.getSize();
        // assume all cursors are sorted top to bottom
        var idx: usize = self.cursors.items.len;
        while (idx > 0) : (idx -= 1) {
            const i = idx - 1;
            const cursor = &self.cursors.items[i];
            const cur_line_o = &self.lines.items[cursor.line];
            if (cur_line_o.*) |*cur_line| {
                if (cursor.col < cur_line.items.len) {
                    var new_line = try std.ArrayListUnmanaged(u8).initCapacity(self.lines.allocator, 64);
                    try new_line.appendSlice(self.lines.allocator, cur_line.items[cursor.col..]);
                    try cur_line.resize(self.lines.allocator, cursor.col);
                    try self.insertLine(cursor.line + 1, new_line);
                }
            }
            cursor.line += 1;
            self.updateCurScroll(cursor.*, size);
            while (cursor.line >= self.lines.items.len) {
                try self.lines.append(try std.ArrayListUnmanaged(u8).initCapacity(self.lines.allocator, 64));
            }
            cursor.col = 0;
        }
    }

    pub fn backspace(self: *Editor) !void {
        // assume all cursors are sorted top to bottom
        var idx1: usize = self.cursors.items.len;
        while (idx1 > 0) : (idx1 -= 1) {
            const i = idx1 - 1;
            const cursor = &self.cursors.items[i];
            if (cursor.col > 0) {
                cursor.col -= 1;
                const line = &(self.lines.items[cursor.line].?);
                _ = line.orderedRemove(cursor.col);
            } else if (cursor.line > 0) {
                const prev_line = &(self.lines.items[cursor.line - 1].?);
                const prev_line_len = prev_line.items.len;
                cursor.col = prev_line_len;
                const cur_line = &(self.lines.items[cursor.line].?);
                try prev_line.appendSlice(self.lines.allocator, cur_line.items);
                _ = self.lines.orderedRemove(cursor.line);
                // move all cursors on or past the deleted line up one
                for (self.cursors.items, 0..) |*move_cur, j| {
                    if (i != j and cursor.line <= move_cur.line) {
                        if (cursor.line == move_cur.line) {
                            move_cur.col = prev_line_len + move_cur.col;
                        }
                        move_cur.line -= 1;
                    }
                }
                cursor.line -= 1;
            }
            // last cursor can be ignored
            if (i < self.cursors.items.len - 1) {
                var any_same_col = false;
                for (self.cursors.items[i + 1 ..]) |*check_cur| {
                    if (check_cur.line == cursor.line and check_cur.col == cursor.col) {
                        any_same_col = true;
                        break;
                    }
                }
                if (any_same_col) {
                    _ = self.cursors.orderedRemove(i);
                }
            }
        }
    }

    pub fn endline(self: *Editor) !void {
        var idx: usize = self.cursors.items.len;
        while (idx > 0) : (idx -= 1) {
            const i = idx - 1;
            const cursor = &self.cursors.items[i];
            const line = &(self.lines.items[cursor.line].?);
            cursor.col = line.items.len;
            // remove duplicates (assuming sorted)
            if (i < self.cursors.items.len - 1 and self.cursors.items[i + 1].line == cursor.line) {
                _ = self.cursors.orderedRemove(i);
            }
        }
    }

    pub fn homeline(self: *Editor) !void {
        var idx: usize = self.cursors.items.len;
        while (idx > 0) : (idx -= 1) {
            const i = idx - 1;
            const cursor = &self.cursors.items[i];
            cursor.col = 0;
            // remove duplicates (assuming sorted)
            if (i < self.cursors.items.len - 1 and self.cursors.items[i + 1].line == cursor.line) {
                _ = self.cursors.orderedRemove(i + 1);
            }
        }
    }
};

pub fn main() !void {
    assertTty();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var ed: Editor = .{
        .term = .{
            .cout = std.io.bufferedWriter(std.io.getStdOut().writer()),
            .cin = std.io.bufferedReader(std.io.getStdIn().reader()),
        },
        .lines = try std.ArrayList(?std.ArrayListUnmanaged(u8)).initCapacity(alloc, 1024),
        .cursors = try std.ArrayList(Cursor).initCapacity(alloc, 32),
        .action_queue = std.fifo.LinearFifo(Action, .{ .Static = 4096 }).init(),
    };

    const sw = ed.term.cout.writer();
    defer ed.term.cout.flush() catch @panic("flushing cout failed");
    defer ed.term.showCursor() catch @panic("showing cursor failed");
    defer sw.writeAll("Goodbye from zedit!\n") catch @panic("writing goodbye message failed");

    try ed.init();
    defer ed.deinit();
    try ed.term.hideCursor();

    const size = try ed.term.getSize();
    while (true) {
        try ed.term.clear();
        try ed.window.render(&ed.term, Rect{ .origin = .{ .x = 0, .y = 0 }, .size = size }, true);
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
                        try ed.addCursors(1);
                    } else if (byte == 'K') {
                        try ed.addCursors(-1);
                    }
                } else {
                    try ed.insertText(&.{byte});
                }
            },
            .End => try ed.endline(),
            .Backspace => try ed.backspace(),
            .Enter => try ed.moveNewline(),
            .Home => try ed.homeline(),
            .Arrow => |dir| switch (dir) {
                .up => try ed.moveCursors(-1, 0),
                .down => try ed.moveCursors(1, 0),
                .left => try ed.moveCursors(0, -1),
                .right => try ed.moveCursors(0, 1),
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
