const std = @import("std");
const util = @import("util.zig");
const Mode = util.Mode;
const Key = util.Key;
const KeyCode = util.KeyCode;

const Self = @This();

pub const ActionInt = u16;

pub const NormalAction = enum(ActionInt) {
    search,
    insert,
    insert_after,
    insert_at_eol,
    insert_newline_above,
    insert_newline_below,
    to_cmd,
    zero,

    move_down,
    move_up,
    move_left,
    move_right,
    add_cur_up,
    add_cur_down,
    backspace,
    delete,
    home,
    end,
    enter,
    quit,
};

pub const EditAction = enum(ActionInt) {
    to_normal,

    move_down,
    move_up,
    move_left,
    move_right,
    add_cur_up,
    add_cur_down,
    backspace,
    delete,
    home,
    end,
    enter,
    quit,
};

pub fn ActionMap(comptime ActionT: type) type {
    return union(enum) {
        const ActionMapT = @This();
        map: std.AutoHashMapUnmanaged(Key, *ActionMapT),
        action: ActionT,

        pub fn newAct(alloc: std.mem.Allocator, action: ActionT) !*ActionMapT {
            const act_map = try alloc.create(ActionMapT);
            act_map.* = .{ .action = action };
            return act_map;
        }

        pub fn newMap(alloc: std.mem.Allocator) !*ActionMapT {
            const act_map = try alloc.create(ActionMapT);
            act_map.* = .{ .map = std.AutoHashMapUnmanaged(Key, *ActionMap){} };
            return act_map;
        }

        pub fn deinit(self: *ActionMapT) void {
            switch (self) {
                .map => self.map.deinit(),
                else => {},
            }
        }
    };
}

arena: std.heap.ArenaAllocator,
normal_actions: ActionMap(NormalAction) = undefined,
edit_actions: ActionMap(EditAction) = undefined,

pub fn init(self: *Self) !void {
    self.normal_actions = .{ .map = std.AutoHashMapUnmanaged(Key, *ActionMap(NormalAction)){} };
    self.edit_actions = .{ .map = std.AutoHashMapUnmanaged(Key, *ActionMap(EditAction)){} };
    try self.setDefaults();
}

pub fn putAction(self: *Self, comptime mode: Mode, key: Key, action: anytype) !void {
    const alloc = self.arena.allocator();
    switch (mode) {
        .normal => try self.normal_actions.map.put(
            alloc,
            key,
            try ActionMap(NormalAction).newAct(alloc, action),
        ),
        .edit => try self.edit_actions.map.put(
            alloc,
            key,
            try ActionMap(EditAction).newAct(alloc, action),
        ),
        else => @compileError("Invalid mode"),
    }
}

fn setDefaults(self: *Self) !void {
    const alloc = self.arena.allocator();
    for (1..10) |n| {
        // 1-9 route back to any normal actions
        // 0 is handled separately since you can't start the cmd with 0
        const char = @as(u8, @intCast(n)) + '0';
        try self.normal_actions.map.put(alloc, Key{ .code = .{ .Char = char } }, &self.normal_actions);
    }
    // Normal Actions
    //
    try self.putAction(.normal, Key{ .code = .{ .Char = '/' } }, .search);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'i' } }, .insert);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'a' } }, .insert_after);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'A' } }, .insert_at_eol);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'O' } }, .insert_newline_above);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'o' } }, .insert_newline_below);
    try self.putAction(.normal, Key{ .code = .{ .Char = ':' } }, .to_cmd);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'q' }, .ctrl = true }, .quit);

    try self.putAction(.normal, Key{ .code = .{ .Arrow = .down } }, .move_down);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'j' } }, .move_down);
    try self.putAction(.normal, Key{ .code = .{ .Arrow = .up } }, .move_up);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'k' } }, .move_up);
    try self.putAction(.normal, Key{ .code = .{ .Arrow = .left } }, .move_left);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'h' } }, .move_left);
    try self.putAction(.normal, Key{ .code = .{ .Arrow = .right } }, .move_right);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'l' } }, .move_right);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'K' }, .alt = true }, .add_cur_up);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'J' }, .alt = true }, .add_cur_down);
    try self.putAction(.normal, Key{ .code = .{ .Backspace = {} } }, .backspace);
    try self.putAction(.normal, Key{ .code = .{ .Delete = {} } }, .delete);
    try self.putAction(.normal, Key{ .code = .{ .Char = 'x' } }, .delete);
    try self.putAction(.normal, Key{ .code = .{ .Home = {} } }, .home);
    try self.putAction(.normal, Key{ .code = .{ .Char = '0' } }, .zero);
    try self.putAction(.normal, Key{ .code = .{ .End = {} } }, .end);
    try self.putAction(.normal, Key{ .code = .{ .Char = '$' } }, .end);
    try self.putAction(.normal, Key{ .code = .{ .Enter = {} } }, .enter);

    //
    // Edit Actions
    try self.putAction(.edit, Key{ .code = .{ .Escape = {} } }, .to_normal);
    try self.putAction(.edit, Key{ .code = .{ .Arrow = .down } }, .move_down);
    try self.putAction(.edit, Key{ .code = .{ .Arrow = .up } }, .move_up);
    try self.putAction(.edit, Key{ .code = .{ .Arrow = .left } }, .move_left);
    try self.putAction(.edit, Key{ .code = .{ .Arrow = .right } }, .move_right);
    try self.putAction(.edit, Key{ .code = .{ .Backspace = {} } }, .backspace);
    try self.putAction(.edit, Key{ .code = .{ .Char = 'K' }, .alt = true }, .add_cur_up);
    try self.putAction(.edit, Key{ .code = .{ .Char = 'J' }, .alt = true }, .add_cur_down);
    try self.putAction(.edit, Key{ .code = .{ .Home = {} } }, .home);
    try self.putAction(.edit, Key{ .code = .{ .End = {} } }, .end);
    try self.putAction(.edit, Key{ .code = .{ .Enter = {} } }, .enter);
}

// normal: struct {
//     insert: Key = Key{ .code = .{ .Char = 'i' } },
//     insert_newline_below: Key = Key{ .code = .{ .Char = 'o' } },
//     insert_newline_above: Key = Key{ .code = .{ .Char = 'O' } },
//     to_cmd: Key = Key{ .code = .{ .Char = ':' } },
//     quit: Key = Key{ .code = .{ .Char = 'q' }, .ctrl = true },
// } = .{},
//
// insert: struct {
//     to_normal: Key = Key{ .code = .{ .Escape = {} } },
// }
