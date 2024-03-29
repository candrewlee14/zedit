pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Position = struct {
    x: usize,
    y: usize,
};

pub const Mode = enum {
    normal,
    select,
    edit,
    command,

    pub fn to3Char(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NOR",
            .select => "SEL",
            .edit => "EDT",
            .command => "CMD",
        };
    }
};

pub const Key = struct {
    code: KeyCode,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    pub fn eql(self: Key, other: Key) bool {
        // zig fmt: off
        return self.code == other.code 
            and self.ctrl == other.ctrl 
            and self.shift == other.shift 
            and self.alt == other.alt;
        // zig fmt: on
    }
};

pub const KeyCode = union(enum) {
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
pub const Direction = enum(u8) {
    up,
    down,
    left,
    right,
};

pub const Rect = struct {
    origin: Position = .{ .x = 0, .y = 0 },
    size: Size = .{ .width = 0, .height = 0 },
};

pub const Cursor = struct {
    line: usize,
    col: usize,
    // selection_len: ?usize = null,

    pub fn lessThan(_: void, self: Cursor, other: Cursor) bool {
        return self.line < other.line or (self.line == other.line and self.col < other.col);
    }
};
