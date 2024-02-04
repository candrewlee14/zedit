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
    cout: std.io.BufferedWriter(4096, std.fs.File.Writer),
    cin: std.io.BufferedReader(4096, std.fs.File.Reader),

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

    pub fn readKey(self: *Terminal) !u8 {
        const sr = self.cin.reader();
        while (true) {
            return sr.readByte() catch |err| switch (err) {
                error.EndOfStream => continue,
                else => return err,
            };
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
    if (!std.io.getStdOut().isTty()) {
        std.debug.print("This program is intended to be run interactively.\n", .{});
        std.os.exit(1);
    }
}

const Editor = struct {
    term: Terminal,

    pub fn init(self: *Editor) !void {
        try self.term.initScreen();
        try self.term.enableRawMode();
        try self.term.clear();
        try self.term.cout.flush();
    }

    pub fn deinit(self: *Editor) void {
        self.term.deinitScreen();
        self.term.disableRawMode();
    }
};

pub fn main() !void {
    assertTty();
    var ed: Editor = .{
        .term = .{
            .cout = std.io.bufferedWriter(std.io.getStdOut().writer()),
            .cin = std.io.bufferedReader(std.io.getStdIn().reader()),
        },
    };
    try ed.init();
    defer ed.deinit();

    const size = try ed.term.getSize();
    std.debug.print("Screen size: {d}x{d}\n\r", .{ size.width, size.height });
    while (true) {
        const byte = try ed.term.readKey();
        if (std.ascii.isControl(byte)) {
            std.debug.print("{d}\n\r", .{byte});
        } else {
            std.debug.print("{d} ({c})\n\r", .{ byte, byte });
        }
        const getCursorPos = try ed.term.getCursorPos();
        std.debug.print("{d},{d}\n\r", .{ getCursorPos.x, getCursorPos.y });
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
