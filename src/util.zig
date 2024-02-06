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
