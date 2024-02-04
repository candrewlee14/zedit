const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

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

    pub fn getCursorPos(self: *Terminal) !Position {
        _ = self;
        const stdout = std.io.getStdOut();
        const stdin = std.io.getStdIn();
        const sw = stdout.writer();
        const sr = stdin.reader();
        try sw.writeAll("\x1b[6n");
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
        const x = try std.fmt.parseUnsigned(usize, buf[2..], 10);
        const y = try std.fmt.parseUnsigned(usize, buf[semi_idx + 1 ..], 10);
        return Position{ .x = x, .y = y };
    }

    pub fn getSize(self: *Terminal) !Size {
        var ws: std.os.linux.winsize = undefined;
        const stdout = std.io.getStdOut();
        const sw = stdout.writer();
        if (std.c.ioctl(stdout.handle, c.TIOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
            try sw.writeAll("\x1b[999C\x1b[999B");
            const cursor_pos = try self.getCursorPos();
            return Size{ .width = cursor_pos.x, .height = cursor_pos.y };
        }
        return Size{ .width = ws.ws_col, .height = ws.ws_row };
    }

    pub fn initScreen(self: *Terminal) !void {
        _ = self;
        const stdout = std.io.getStdOut();
        const sw = stdout.writer();
        const alternate_screen_code = "\x1b[?1049h";
        try sw.writeAll(alternate_screen_code);
    }

    pub fn deinitScreen(self: *Terminal) void {
        _ = self;
        const stdout = std.io.getStdOut();
        const sw = stdout.writer();
        const exit_alternate_screen_code = "\x1b[?1049l";
        sw.writeAll(exit_alternate_screen_code) catch unreachable;
    }

    pub fn readKey(self: *Terminal) !u8 {
        _ = self;
        const stdin = std.io.getStdIn();
        const reader = stdin.reader();
        while (true) {
            return reader.readByte() catch |err| switch (err) {
                error.EndOfStream => continue,
                else => return err,
            };
        }
    }

    pub fn clear(self: *Terminal) !void {
        _ = self;
        const stdout = std.io.getStdOut();
        const sw = stdout.writer();
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
    if (!std.io.getStdOut().isTty()) {
        std.debug.print("This program is intended to be run interactively.\n", .{});
        std.os.exit(1);
    }
}

const Editor = struct {
    terminal: Terminal = .{},

    pub fn init(self: *Editor) !void {
        try self.terminal.initScreen();
        try self.terminal.enableRawMode();
        try self.terminal.clear();
    }

    pub fn deinit(self: *Editor) void {
        self.terminal.deinitScreen();
        self.terminal.disableRawMode();
    }
};

pub fn main() !void {
    assertTty();
    var ed: Editor = .{};
    try ed.init();
    defer ed.deinit();

    std.debug.print("All your {s} are belong to us.\n\r", .{"codebase"});
    const size = try ed.terminal.getSize();
    std.debug.print("Screen size: {d}x{d}\n\r", .{ size.width, size.height });
    while (true) {
        const byte = try ed.terminal.readKey();
        if (std.ascii.isControl(byte)) {
            std.debug.print("{d}\n\r", .{byte});
        } else {
            std.debug.print("{d} ({c})\n\r", .{ byte, byte });
        }
        if (byte == ctrlKey('q')) break;
    }
}

inline fn ctrlKey(char: u8) u8 {
    return char & 0x1f;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
