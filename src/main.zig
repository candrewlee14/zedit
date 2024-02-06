const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

const Size = struct {
    width: usize,
    height: usize,
};

const Position = struct {
    x: usize,
    y: usize,
};

const Terminal = struct {
    orig_termios: std.os.termios = undefined,
    cout: std.io.BufferedWriter(4096, std.fs.File.Writer),
    cin: std.io.BufferedReader(4096, std.fs.File.Reader),

    pub fn hideCursor(self: *Terminal) !void {
        const sw = self.cout.writer();
        try sw.writeAll("\x1b[?25l");
    }
    pub fn showCursor(self: *Terminal) !void {
        const sw = self.cout.writer();
        try sw.writeAll("\x1b[?25h");
    }

    pub fn getCursorPos(self: *Terminal) !Position {
        const sw = self.cout.writer();
        const sr = self.cin.reader();
        try sw.writeAll("\x1b[6n");
        try self.cout.flush();
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < buf.len - 1) {
            const byte = sr.readByte() catch |err| {
                if (err == error.EndOfStream) {
                    continue;
                } else {
                    return err;
                }
            };
            buf[i] = byte;
            if (byte == 'R') break;
            i += 1;
        }
        buf[i] = 0;
        if (buf[0] != '\x1b' or buf[1] != '[') return error.InvalidUnicodeCodepoint;
        const semi_idx = std.mem.indexOfScalar(u8, &buf, ';') orelse return error.InvalidUnicodeCodepoint;
        const x = try std.fmt.parseUnsigned(usize, buf[2..semi_idx], 10);
        const y = try std.fmt.parseUnsigned(usize, buf[semi_idx + 1 .. i], 10);
        return Position{ .x = x, .y = y };
    }

    pub fn navCurTo(self: *Terminal, pos: Position) !void {
        const sw = self.cout.writer();
        try sw.print("\x1b[{d};{d}H", .{ pos.y + 1, pos.x + 1 });
    }

    pub fn getSize(self: *Terminal) !Size {
        var ws: std.os.linux.winsize = undefined;
        const stdout = std.io.getStdOut();
        if (std.c.ioctl(stdout.handle, c.TIOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
            const sw = self.cout.writer();
            try sw.writeAll("\x1b[999C\x1b[999B");
            try self.cout.flush();
            const cursor_pos = try self.getCursorPos();
            return Size{ .width = cursor_pos.x, .height = cursor_pos.y };
        }
        return Size{ .width = ws.ws_col, .height = ws.ws_row };
    }

    pub fn initScreen(self: *Terminal) !void {
        const alternate_screen_code = "\x1b[?1049h";
        const sw = self.cout.writer();
        try sw.writeAll(alternate_screen_code);
    }

    pub fn deinitScreen(self: *Terminal) void {
        const exit_alternate_screen_code = "\x1b[?1049l";
        const sw = self.cout.writer();
        sw.writeAll(exit_alternate_screen_code) catch unreachable;
    }

    pub fn readKey(self: *Terminal) !Key {
        const sr = self.cin.reader();
        const byte = blk: {
            while (true) {
                break :blk sr.readByte() catch |err| switch (err) {
                    error.EndOfStream => continue,
                    else => return err,
                };
            }
        };
        switch (byte) {
            '\x1b' => {
                const second_byte = sr.readByte() catch |err| {
                    if (err == error.EndOfStream) return .{ .code = .{ .Escape = {} } };
                    return err;
                };
                if (second_byte == '[') {
                    const third_byte = sr.readByte() catch |err| {
                        if (err == error.EndOfStream) return .{ .code = .{ .Escape = {} } };
                        return err;
                    };
                    switch (third_byte) {
                        'A' => return .{ .code = .{ .Arrow = .up } },
                        'B' => return .{ .code = .{ .Arrow = .down } },
                        'C' => return .{ .code = .{ .Arrow = .right } },
                        'D' => return .{ .code = .{ .Arrow = .left } },
                        'H' => return .{ .code = .{ .Home = {} } },
                        'F' => return .{ .code = .{ .End = {} } },
                        '5' => {
                            const fourth_byte = sr.readByte() catch |err| {
                                if (err == error.EndOfStream) return .{ .code = .{ .Escape = {} } };
                                return err;
                            };
                            if (fourth_byte == '~') {
                                return .{ .code = .{ .PageUp = {} } };
                            }
                            return .{ .code = .{ .Escape = {} } };
                        },
                        '6' => {
                            const fourth_byte = sr.readByte() catch |err| {
                                if (err == error.EndOfStream) return .{ .code = .{ .Escape = {} } };
                                return err;
                            };
                            if (fourth_byte == '~') {
                                return .{ .code = .{ .PageDown = {} } };
                            }
                            return .{ .code = .{ .Escape = {} } };
                        },
                        else => return .{ .code = .{ .Escape = {} } },
                    }
                } else if (second_byte == 'O') {
                    const third_byte = sr.readByte() catch |err| {
                        if (err == error.EndOfStream) return .{ .code = .{ .Escape = {} } };
                        return err;
                    };
                    switch (third_byte) {
                        'H' => return .{ .code = .{ .Home = {} } },
                        'F' => return .{ .code = .{ .End = {} } },
                        else => return .{ .code = .{ .Escape = {} } },
                    }
                } else {
                    if (std.ascii.isASCII(second_byte)) {
                        return .{
                            .code = .{ .Char = second_byte },
                            .ctrl = std.ascii.isControl(second_byte),
                            .alt = true,
                        };
                    }
                    return .{ .code = .{ .Escape = {} } };
                }
            },
            127 => return .{ .code = .{ .Backspace = {} } },
            10, '\r' => return .{ .code = .{ .Enter = {} } },
            else => return .{
                .code = .{ .Char = byte },
                .ctrl = std.ascii.isControl(byte),
                .alt = isAltKey(byte),
            },
        }
    }

    pub fn clear(self: *Terminal) !void {
        const sw = self.cout.writer();
        const clear_screen_code = "\x1b[2J";
        try sw.writeAll(clear_screen_code);
        const cursor_home_code = "\x1b[H";
        try sw.writeAll(cursor_home_code);
    }

    pub fn enableRawMode(self: *Terminal) !void {
        const stdout = std.io.getStdOut();
        // save the original terminal settings and set our own
        self.orig_termios = try std.os.tcgetattr(stdout.handle);
        var termios = self.orig_termios;
        // IXON disables software flow control (Ctrl-S and Ctrl-Q)
        // ICRNL disables translating carriage return to newline
        // BRKINT disables sending a SIGINT when receiving a break condition
        // INPCK disables parity checking
        // ISTRIP disables stripping the 8th bit of each input byte
        termios.iflag &= ~(std.os.linux.IXON | std.os.linux.ICRNL | std.os.linux.BRKINT | std.os.linux.INPCK | std.os.linux.ISTRIP);
        // ECHO turns off echoing of typed characters
        // ICANON turns off canonical mode, which means input is read byte-by-byte
        // IEXTEN disables Ctrl-V and Ctrl-O
        // ISIG disables Ctrl-C and Ctrl-Z
        termios.lflag &= ~(std.os.linux.ECHO | std.os.linux.ICANON | std.os.linux.IEXTEN | std.os.linux.ISIG);
        // OPOST turns off output processing, which means output is written byte-by-byte
        termios.oflag &= ~(std.os.linux.OPOST);
        // CS8 sets the character size to 8 bits per byte
        termios.cflag |= (std.os.linux.CS8);
        // PARENB disables parity checking
        // CSIZE sets the character size to 8 bits per byte
        termios.cflag &= ~(std.os.linux.PARENB | std.os.linux.CSIZE);
        // VTIME sets the maximum amount of time to wait before read() returns in tenths of a second
        termios.cc[c.VTIME] = 1;
        // VMIN sets the minimum number of bytes of input needed before read() can return
        termios.cc[c.VMIN] = 0;
        try std.os.tcsetattr(stdout.handle, std.os.TCSA.FLUSH, termios);
    }

    pub fn disableRawMode(self: *Terminal) void {
        const stdout = std.io.getStdOut();
        // restore the original terminal settings
        std.os.tcsetattr(stdout.handle, std.os.TCSA.FLUSH, self.orig_termios) catch unreachable;
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

    pub fn init(self: *Editor) !void {
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

    pub fn refreshScreen(self: *Editor) !void {
        // try self.term.hideCursor();
        try self.term.clear();
        const size = try self.term.getSize();
        for (0..size.height) |i| {
            const sw = self.term.cout.writer();
            // try sw.print("{d} ", .{i + 1});
            // try sw.writeAll("~ ");
            const str_i = self.cur_scroll + i;
            if (str_i < self.lines.items.len) {
                if (self.lines.items[str_i]) |line| {
                    const line_len = line.items.len;
                    if (line_len > size.width) {
                        const more_str = " ...";
                        try sw.writeAll(line.items[0 .. size.width - more_str.len]);
                        try sw.writeAll(more_str);
                    } else {
                        try sw.writeAll(line.items);
                    }
                }
            }
            if (i < size.height - 1) {
                try sw.writeAll("\r\n");
            }
        }
        for (self.cursors.items) |cursor| {
            if (cursor.line < self.cur_scroll and cursor.line >= self.cur_scroll + size.height) continue;
            try self.term.navCurTo(.{ .x = cursor.col, .y = cursor.line - self.cur_scroll });

            const sw = self.term.cout.writer();
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
        try self.term.cout.flush();
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

const Direction = enum(u8) {
    up,
    down,
    left,
    right,
};

const KeyCode = union(enum) {
    Escape: void,
    Home: void,
    End: void,
    PageUp: void,
    PageDown: void,
    Arrow: Direction,
    Delete: void,
    Backspace: void,
    Enter: void,
    Char: u8,
};

const Key = struct {
    code: KeyCode,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
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
    _ = size;
    while (true) {
        try ed.refreshScreen();
        const key = try ed.term.readKey();
        switch (key.code) {
            .Char => |byte| {
                if (key.ctrl) {
                    const new_byte = byte | 0x40;
                    std.debug.print("CTRL+{c} ({d})", .{ new_byte, new_byte });
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
                if (key.ctrl == true and byte == ctrlKey('q')) {
                    break;
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

inline fn ctrlKey(char: u8) u8 {
    return char & 0x1f;
}
inline fn altKey(char: u8) u8 {
    return char | 0x80;
}
inline fn isAltKey(char: u8) bool {
    return char & 0x80 == 0x80;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
