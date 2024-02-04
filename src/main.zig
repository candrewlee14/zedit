const std = @import("std");

const State = struct {
    orig_termios: std.os.termios = undefined,

    pub fn initScreen(self: *State) !void {
        _ = self;
        const stdout = std.io.getStdOut();
        const sw = stdout.writer();
        const alternate_screen_code = "\x1b[?1049h";
        try sw.writeAll(alternate_screen_code);
    }
    pub fn deinitScreen(self: *State) void {
        _ = self;
        const stdout = std.io.getStdOut();
        const sw = stdout.writer();
        const exit_alternate_screen_code = "\x1b[?1049l";
        sw.writeAll(exit_alternate_screen_code) catch unreachable;
    }
    pub fn enableRawMode(self: *State) !void {
        const stdout = std.io.getStdOut();
        // save the original terminal settings and set our own
        self.orig_termios = try std.os.tcgetattr(stdout.handle);
        var termios = self.orig_termios;
        termios.lflag &= ~std.os.linux.ICANON;
        try std.os.tcsetattr(stdout.handle, std.os.TCSA.FLUSH, termios);
    }
    pub fn disableRawMode(self: *State) void {
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

pub fn main() !void {
    assertTty();
    var state: State = .{};
    try state.initScreen();
    defer state.deinitScreen();
    try state.enableRawMode();
    defer state.disableRawMode();

    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    var reader = std.io.getStdIn().reader();
    while (try reader.readByte() != 'q') {
        std.debug.print(" Press 'q' to quit.\n", .{});
    }
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();
    //
    // try stdout.print("Run `zig build test` to run the tests.\n", .{});
    //
    // try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
