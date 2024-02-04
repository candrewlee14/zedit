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
        try sw.print("\x1b[{d};{d}H", .{ pos.y, pos.x });
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
                    return .{ .code = .{ .Escape = {} } };
                }
            },
            127 => return .{ .code = .{ .Backspace = {} } },
            10, '\r' => return .{ .code = .{ .Enter = {} } },
            else => return .{
                .code = .{ .Char = byte },
                .ctrl = std.ascii.isControl(byte),
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
        termios.lflag &= ~(std.os.linux.ECHO | std.os.linux.ICANON);
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
            const sw = self.term.cout.writer();
            try sw.print("\x1b[{d};{d}H", .{ cursor.line + 1, cursor.col + 1 });
            // print white block
            try sw.writeAll("\xe2\x96\x88");
        }

        try self.term.cout.flush();
    }

    pub fn moveCursors(self: *Editor, dline: isize, dcol: isize) !void {
        for (self.cursors.items) |*cursor| {
            var new_line = @as(isize, @intCast(cursor.line)) + dline;
            new_line = @max(new_line, 0);
            new_line = @min(new_line, @as(isize, @intCast(self.lines.items.len - 1)));
            var new_col = @as(isize, @intCast(cursor.col)) + dcol;
            new_col = @max(new_col, 0);
            cursor.line = @intCast(new_line);

            const line_o = self.lines.items[cursor.line];
            if (line_o) |line| {
                new_col = @min(new_col, @as(isize, @intCast(line.items.len)));
            } else {
                new_col = 0;
            }
            cursor.col = @intCast(new_col);
        }
    }

    pub fn moveNewline(self: *Editor) !void {
        for (self.cursors.items) |*cursor| {
            cursor.line += 1;
            cursor.col = 0;
        }
    }

    pub fn backspace(self: *Editor) !void {
        for (self.cursors.items) |*cursor| {
            if (cursor.col > 0) {
                cursor.col -= 1;
                const line = &(self.lines.items[cursor.line].?);
                _ = line.orderedRemove(cursor.col);
            }
        }
    }
    pub fn endline(self: *Editor) !void {
        for (self.cursors.items) |*cursor| {
            const line = &(self.lines.items[cursor.line].?);
            cursor.col = line.items.len;
        }
    }
    pub fn homeline(self: *Editor) !void {
        for (self.cursors.items) |*cursor| {
            cursor.col = 0;
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

    try ed.init();
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
                } else {
                    // std.debug.print("{c} ({d})", .{ byte, byte });
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
    ed.deinit();
    try ed.term.showCursor();
    const sw = ed.term.cout.writer();
    try sw.writeAll("Goodbye from zedit!\n");
    try ed.term.cout.flush();
}

inline fn ctrlKey(char: u8) u8 {
    return char & 0x1f;
}
inline fn altKey(char: u8) u8 {
    return char | 0x80;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
