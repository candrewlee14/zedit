const std = @import("std");
const util = @import("util.zig");
const Key = util.Key;
const KeyCode = util.KeyCode;

const Self = @This();

const NormalAction = enum {
    search,
    insert,
    insert_newline_above,
    insert_newline_below,
    to_cmd,

    move_down,
    move_up,
    move_left,
    move_right,
    add_cur_up,
    add_cur_down,
    backspace,
    home,
    end,
    enter,
    quit,
};

const EditAction = enum {
    to_normal,

    move_down,
    move_up,
    move_left,
    move_right,
    add_cur_up,
    add_cur_down,
    backspace,
    home,
    end,
    enter,
    quit,
};

normal_actions: std.AutoHashMap(Key, NormalAction) = undefined,
edit_actions: std.AutoHashMap(Key, EditAction) = undefined,

pub fn init(self: *Self, alloc: std.mem.Allocator) !void {
    self.normal_actions = std.AutoHashMap(Key, NormalAction).init(alloc);
    self.edit_actions = std.AutoHashMap(Key, EditAction).init(alloc);
    try self.setDefault();
}

pub fn deinit(self: *Self) void {
    self.normal_actions.deinit();
}

fn setDefault(self: *Self) !void {
    // Normal Actions
    try self.normal_actions.put(Key{ .code = .{ .Char = '/' } }, .search);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'i' } }, .insert);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'o' } }, .insert_newline_below);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'O' } }, .insert_newline_below);
    try self.normal_actions.put(Key{ .code = .{ .Char = ':' } }, .to_cmd);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'q' }, .ctrl = true }, .quit);

    try self.normal_actions.put(Key{ .code = .{ .Arrow = .down } }, .move_down);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'j' } }, .move_down);
    try self.normal_actions.put(Key{ .code = .{ .Arrow = .up } }, .move_up);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'k' } }, .move_up);
    try self.normal_actions.put(Key{ .code = .{ .Arrow = .left } }, .move_left);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'h' } }, .move_left);
    try self.normal_actions.put(Key{ .code = .{ .Arrow = .right } }, .move_right);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'l' } }, .move_right);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'K' }, .alt = true }, .add_cur_up);
    try self.normal_actions.put(Key{ .code = .{ .Char = 'J' }, .alt = true }, .add_cur_down);
    try self.normal_actions.put(Key{ .code = .{ .Backspace = {} } }, .backspace);
    try self.normal_actions.put(Key{ .code = .{ .Home = {} } }, .home);
    try self.normal_actions.put(Key{ .code = .{ .End = {} } }, .end);
    try self.normal_actions.put(Key{ .code = .{ .Enter = {} } }, .enter);

    // Edit Actions
    try self.edit_actions.put(Key{ .code = .{ .Escape = {} } }, .to_normal);

    try self.edit_actions.put(Key{ .code = .{ .Arrow = .down } }, .move_down);
    try self.edit_actions.put(Key{ .code = .{ .Arrow = .up } }, .move_up);
    try self.edit_actions.put(Key{ .code = .{ .Arrow = .left } }, .move_left);
    try self.edit_actions.put(Key{ .code = .{ .Arrow = .right } }, .move_right);
    try self.edit_actions.put(Key{ .code = .{ .Backspace = {} } }, .backspace);
    try self.edit_actions.put(Key{ .code = .{ .Char = 'K' }, .alt = true }, .add_cur_up);
    try self.edit_actions.put(Key{ .code = .{ .Char = 'J' }, .alt = true }, .add_cur_down);
    try self.edit_actions.put(Key{ .code = .{ .Home = {} } }, .home);
    try self.edit_actions.put(Key{ .code = .{ .End = {} } }, .end);
    try self.edit_actions.put(Key{ .code = .{ .Enter = {} } }, .enter);
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
