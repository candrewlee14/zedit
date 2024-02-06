pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Position = struct {
    x: usize,
    y: usize,
};

pub const Key = struct {
    code: KeyCode,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
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
    origin: Position,
    size: Size,
};

pub const Cursor = struct {
    line: usize,
    col: usize,
    // selection_len: ?usize = null,

    pub fn lessThan(_: void, self: Cursor, other: Cursor) bool {
        return self.line < other.line or (self.line == other.line and self.col < other.col);
    }
};
