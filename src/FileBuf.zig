const std = @import("std");
const Terminal = @import("./Term.zig");
const util = @import("./util.zig");
const Cursor = util.Cursor;
const Size = util.Size;
const Rect = util.Rect;
const WindowImpl = @import("./WindowImpl.zig");

const log = @import("./log.zig");
const logger = &log.logger;

const Self = @This();

arena: std.heap.ArenaAllocator,
name: []const u8,
lines: std.ArrayListUnmanaged(?std.ArrayListUnmanaged(u8)) = undefined,
cur_scroll: usize = 0,
cursors: std.ArrayListUnmanaged(Cursor) = undefined,
window: WindowImpl = undefined,

pub fn init(self: *Self) !void {
    const alloc = self.arena.allocator();
    self.lines = try std.ArrayListUnmanaged(?std.ArrayListUnmanaged(u8)).initCapacity(alloc, 100);
    try self.lines.append(
        alloc,
        try std.ArrayListUnmanaged(u8).initCapacity(alloc, 64),
    );

    self.cursors = try std.ArrayListUnmanaged(Cursor).initCapacity(alloc, 16);
    try self.cursors.append(alloc, .{ .line = 0, .col = 0 });

    // set up the window
    const vtable = try alloc.create(WindowImpl.VTable);
    vtable.* = .{ .render = Self.render };
    self.window = .{ .ptr = @ptrCast(self), .vtable = vtable, .with_border = true };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn render(ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void {
    const self: *Self = @alignCast(@ptrCast(ctx));
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
        try term.navCurTo(.{
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
    try self.printCursorInfo(term);
}

pub fn insertText(self: *Self, text: []const u8) !void {
    const alloc = self.arena.allocator();
    for (self.cursors.items) |*cursor| {
        while (cursor.line >= self.lines.items.len) {
            try self.lines.append(alloc, try std.ArrayListUnmanaged(u8).initCapacity(alloc, 64));
        }
        const line = &(self.lines.items[cursor.line].?);
        if (cursor.col >= line.items.len) {
            try line.appendNTimes(alloc, ' ', cursor.col - line.items.len);
        }
        try line.insertSlice(alloc, cursor.col, text);
        cursor.col += text.len;
    }
}

inline fn updateCurScroll(self: *Self, cursor: Cursor, size: Size) void {
    if (cursor.line >= self.cur_scroll + size.height) {
        self.cur_scroll = cursor.line - size.height + 1;
    } else if (cursor.line < self.cur_scroll) {
        self.cur_scroll = cursor.line;
    }
}

pub fn moveCursors(self: *Self, dline: isize, dcol: isize) !void {
    const size = self.window.rect.size;
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

pub fn addCursorIfNoDuplicates(self: *Self, cursor: Cursor, checks: []const Cursor) !void {
    const alloc = self.arena.allocator();
    var any_same_col = false;
    for (checks) |cur| {
        if (cur.line == cursor.line and cur.col == cursor.col) {
            any_same_col = true;
            break;
        }
    }
    if (!any_same_col) {
        try self.cursors.append(alloc, cursor);
    }
    std.mem.sortUnstable(Cursor, self.cursors.items, {}, Cursor.lessThan);
}

pub fn addCursors(self: *Self, dline: isize) !void {
    std.debug.assert(dline == 1 or dline == -1);
    const item_count = self.cursors.items.len;
    std.mem.sortUnstable(Cursor, self.cursors.items[0..item_count], {}, Cursor.lessThan);
    var i: usize = 0;
    // Once upon a time, the following line was a for loop over the cursors, but I found out the hard way
    // that the append that happens in this block would invalidate that slice and give us bad memory
    while (i < item_count) : (i += 1) {
        const cursor = &self.cursors.items[i];
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
            const alloc = self.arena.allocator();
            try self.cursors.append(alloc, new_cursor);
        }
    }
    std.mem.sortUnstable(Cursor, self.cursors.items, {}, Cursor.lessThan);
}

pub fn printCursorInfo(self: *Self, term: *Terminal) !void {
    const size = self.window.rect.size;
    for (self.cursors.items, 0..) |cursor, i| {
        const sw = term.cout.writer();
        // goto right side top of screen
        try sw.print("\x1b[{d};{d}H", .{ i + 1, size.width - 10 });
        try sw.print("({d}, {d}) ", .{ cursor.line, cursor.col });
    }
}

pub fn insertLine(self: *Self, idx: usize, new_line: std.ArrayListUnmanaged(u8)) !void {
    const alloc = self.arena.allocator();
    try self.lines.insert(alloc, idx, new_line);
    for (self.cursors.items) |*cursor| {
        if (cursor.line >= idx) {
            cursor.line += 1;
        }
    }
}

pub fn removeLine(self: *Self, idx: usize) !void {
    _ = self.lines.orderedRemove(idx);
    for (self.cursors.items) |*cursor| {
        if (cursor.line >= idx) {
            // TODO: if the cursor == idx, should we just delete the cursor?
            cursor.line -|= 1;
        }
    }
}

pub fn moveNewline(self: *Self) !void {
    const alloc = self.arena.allocator();
    const size = self.window.rect.size;
    // assume all cursors are sorted top to bottom
    var idx: usize = self.cursors.items.len;
    while (idx > 0) : (idx -= 1) {
        const i = idx - 1;
        const cursor = &self.cursors.items[i];
        const cur_line_o = &self.lines.items[cursor.line];
        if (cur_line_o.*) |*cur_line| {
            if (cursor.col < cur_line.items.len) {
                var new_line = try std.ArrayListUnmanaged(u8).initCapacity(alloc, 64);
                try new_line.appendSlice(alloc, cur_line.items[cursor.col..]);
                try cur_line.resize(alloc, cursor.col);
                try self.insertLine(cursor.line + 1, new_line);
            } else {
                try self.insertLine(cursor.line + 1, try std.ArrayListUnmanaged(u8).initCapacity(alloc, 64));
            }
        }
        cursor.line += 1;
        self.updateCurScroll(cursor.*, size);
        while (cursor.line >= self.lines.items.len) {
            try self.lines.append(
                alloc,
                try std.ArrayListUnmanaged(u8).initCapacity(alloc, 64),
            );
        }
        cursor.col = 0;
    }
}

pub fn backspace(self: *Self) !void {
    const alloc = self.arena.allocator();
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
            try prev_line.appendSlice(alloc, cur_line.items);
            _ = self.lines.orderedRemove(cursor.line);
            // move all cursors on or past the deleted line up one
            for (self.cursors.items, 0..) |*move_cur, j| {
                if (i != j and cursor.line <= move_cur.line) {
                    if (cursor.line == move_cur.line) {
                        move_cur.col = prev_line_len + move_cur.col;
                    }
                    move_cur.line -|= 1;
                }
            }
            cursor.line -|= 1;
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

pub fn endline(self: *Self) !void {
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

pub fn homeline(self: *Self) !void {
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
