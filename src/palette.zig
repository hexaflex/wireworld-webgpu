//! ColorPalette defines the colors by which a circuit is loaded from- or saved to disk.
//! Palette indices map directly to cell states:
//!
//!    0: Empty cells.
//!    1-5: Notes/annotations next to circuits. Like empty cells, these are ignored by the simulation.
//!    6: Wire defines conductive wires. These carry signals made up of electron head- and tail cells.
//!    7: Tail cells are the trailing end of a signal. These help determine the direction a signal travels in.
//!    8: Head defines the front of a signal traveling along a wire,
//!

const std = @import("std");
const zimg = @import("zigimg");
const Cell = @import("grid.zig").Cell;

test {
    std.testing.refAllDecls(@This());
}

pub const Color = [3]u8;

/// empty defines empty cells.
empty: Color = .{ 0, 0, 0 },

/// notes colors are not simulation states, but can be used by the user to draw
/// annotations next to circuits. Like empty cells, these are ignored by the
/// simulation.
notes1: Color = .{ 182, 182, 182 },
notes2: Color = .{ 50, 50, 50 },
notes3: Color = .{ 255, 0, 0 },
notes4: Color = .{ 0, 0, 255 },
notes5: Color = .{ 255, 255, 0 },

/// wire defines conductive wires. These carry signals made up of
/// electron head- and tail cells.
wire: Color = .{ 1, 91, 150 },

/// tail cells are the trailing end of a signal. These help determine the
/// direction a signal travels in.
tail: Color = .{ 153, 255, 0 },

/// head defines the front of a signal traveling along a wire.
head: Color = .{ 255, 255, 255 },

/// toFloat returns the palette's colors in float form.
/// Meaning each component is mapped to the [0.0, 1.0] range in the order
/// matching Cell state values.
pub inline fn toFloat(self: *const @This()) [@typeInfo(@This()).Struct.fields.len][4]f32 {
    return .{
        colorToFloat(self.empty),
        colorToFloat(self.notes1),
        colorToFloat(self.notes2),
        colorToFloat(self.notes3),
        colorToFloat(self.notes4),
        colorToFloat(self.notes5),
        colorToFloat(self.wire),
        colorToFloat(self.tail),
        colorToFloat(self.head),
    };
}

inline fn colorToFloat(c: Color) [4]f32 {
    return .{
        @intToFloat(f32, c[0]) / 255.0,
        @intToFloat(f32, c[1]) / 255.0,
        @intToFloat(f32, c[2]) / 255.0,
        1.0,
    };
}

/// toState finds the palette entry matching c and equates it to the appropriate cell state.
pub fn toState(self: *const @This(), c: zimg.color.Colorf32) !Cell {
    if (eql(self.empty, c)) return .empty;
    if (eql(self.notes1, c)) return .notes1;
    if (eql(self.notes2, c)) return .notes2;
    if (eql(self.notes3, c)) return .notes3;
    if (eql(self.notes4, c)) return .notes4;
    if (eql(self.notes5, c)) return .notes5;
    if (eql(self.wire, c)) return .wire;
    if (eql(self.tail, c)) return .tail;
    if (eql(self.head, c)) return .head;
    return error.UnknownColor;
}

inline fn eql(a: Color, b: zimg.color.Colorf32) bool {
    return a[0] == @floatToInt(u8, b.r * 255) and
        a[1] == @floatToInt(u8, b.g * 255) and
        a[2] == @floatToInt(u8, b.b * 255);
}
