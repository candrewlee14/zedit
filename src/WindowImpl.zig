const std = @import("std");
const Terminal = @import("./Term.zig");
const util = @import("./util.zig");
const Rect = util.Rect;
const Size = util.Size;
const WindowImpl = @This();

ptr: *anyopaque,
vtable: *const VTable,

rect: Rect = .{},
with_border: bool = false,
active: bool = true,

pub const VTable = struct {
    render: ?*const fn (ctx: *anyopaque, term: *Terminal, rect: Rect) anyerror!void = null,
    getChildren: ?*const fn (ctx: *anyopaque) []*const WindowImpl = null,
    layoutChildren: ?*const fn (ctx: *anyopaque) anyerror!void = null,
};

/// Recursively render the window and its children
pub fn render(self: *const WindowImpl, term: *Terminal) anyerror!void {
    const rect = self.rect;
    if (self.with_border) {
        for (0..rect.size.height) |i| {
            if (i == 0) {
                try term.writeAt(.{ .x = rect.origin.x, .y = rect.origin.y }, "┌");
                try term.writeAt(.{ .x = rect.origin.x + rect.size.width - 1, .y = rect.origin.y }, "┐");
                for (1..rect.size.width - 1) |j| {
                    try term.writeAt(.{ .x = rect.origin.x + j, .y = rect.origin.y }, "─");
                }
            } else if (i == rect.size.height - 1) {
                try term.writeAt(.{ .x = rect.origin.x, .y = rect.origin.y + i }, "└");
                try term.writeAt(.{ .x = rect.origin.x + rect.size.width - 1, .y = rect.origin.y + i }, "┘");
                for (1..rect.size.width - 1) |j| {
                    try term.writeAt(.{ .x = rect.origin.x + j, .y = rect.origin.y + i }, "─");
                }
            } else {
                try term.writeAt(.{ .x = rect.origin.x, .y = rect.origin.y + i }, "│");
                try term.writeAt(.{ .x = rect.origin.x + rect.size.width - 1, .y = rect.origin.y + i }, "│");
            }
        }
        if (self.vtable.render) |self_render| {
            try self_render(self.ptr, term, Rect{
                .origin = .{ .x = rect.origin.x + 1, .y = rect.origin.y + 1 },
                .size = Size{
                    .width = rect.size.width - 2,
                    .height = rect.size.height - 2,
                },
            });
        }
    } else {
        if (self.vtable.render) |self_render| try self_render(self.ptr, term, rect);
    }
    if (self.vtable.layoutChildren) |layoutChildren| try layoutChildren(self.ptr);
    if (self.vtable.getChildren) |getChildren| {
        for (getChildren(self.ptr)) |child| {
            if (self.with_border) {
                std.debug.assert(child.rect.origin.x > rect.origin.x);
                std.debug.assert(child.rect.origin.y > rect.origin.y);
                std.debug.assert(child.rect.origin.x + child.rect.size.width < rect.origin.x + rect.size.width);
                std.debug.assert(child.rect.origin.y + child.rect.size.height < rect.origin.y + rect.size.height);
            } else {
                std.debug.assert(child.rect.origin.x >= rect.origin.x);
                std.debug.assert(child.rect.origin.y >= rect.origin.y);
                std.debug.assert(child.rect.origin.x + child.rect.size.width <= rect.origin.x + rect.size.width);
                std.debug.assert(child.rect.origin.y + child.rect.size.height <= rect.origin.y + rect.size.height);
            }
            if (child.active) try child.render(term);
        }
    }
}

pub fn clear(self: *const WindowImpl, term: *Terminal) anyerror!void {
    // print spaces to fill internal rect
    const rect = self.rect;
    const sw = term.cout.writer();
    for (0..rect.size.height) |y| {
        if (self.with_border and (y == 0 or y == rect.size.height - 1)) continue;
        term.navCurTo(.{ rect.origin.x + if (self.with_border) 1 else 0, rect.origin.y + y });
        sw.writeByteNTimes(' ', rect.size.width - if (self.with_border) 2 else 0);
    }
}
