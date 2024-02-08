const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

const util = @import("./util.zig");
const Position = util.Position;
const Size = util.Size;
const Key = util.Key;
const KeyCode = util.KeyCode;

const Terminal = @This();

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
        else => {
            const ctrl = std.ascii.isControl(byte);
            const alt = isAltKey(byte);
            var new_byte = byte;
            if (ctrl) new_byte = new_byte | 0x60;
            // TODO: need to handle alt?
            if (alt) new_byte = new_byte;
            return .{
                .code = .{ .Char = new_byte },
                .ctrl = std.ascii.isControl(byte),
                .alt = isAltKey(byte),
            };
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

pub fn writeAt(self: *Terminal, pos: Position, text: []const u8) !void {
    const sw = self.cout.writer();
    try sw.print("\x1b[{d};{d}H{s}", .{ pos.y + 1, pos.x + 1, text });
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
