const std = @import("std");
const Cell = @import("grid.zig").Cell;
const gnorp = @import("gnorp");
const zimg = @import("zigimg");
const gpu = @import("gpu");
const Palette = @import("palette.zig");

test {
    std.testing.refAllDecls(@This());
}

cells: []const Cell = &.{},
width: u32 = 0,
height: u32 = 0,

/// init creates a new circuit with the given values.
/// This call copies the given cell memory.
///
/// Asserts that cells contains enough data for the given dimensions.
pub fn init(width: u32, height: u32, cells: []const Cell) !@This() {
    std.debug.assert(width * height <= cells.len);
    return @This(){
        .width = width,
        .height = height,
        .cells = try gnorp.allocator.dupe(Cell, cells[0 .. width * height]),
    };
}

/// initFromImage loads a circuit from the given image file. The given palette is used to
/// identify the cell states in the given image.
pub fn initFromFile(filename: []const u8, palette: *const Palette) !@This() {
    gnorp.log.debug(@src(), "loading circuit from: {s}", .{filename});

    var img = try zimg.Image.fromFilePath(gnorp.allocator, filename);
    defer img.deinit();

    if (img.isAnimation())
        return error.AnimatedImagesNotSupported;

    gnorp.log.debug(@src(), "  size: {} x {}, format: {s}", .{ img.width, img.height, @tagName(img.pixels) });

    const width = @truncate(u32, img.width);
    const height = @truncate(u32, img.height);
    const cells = try toCells(&img, palette);

    return @This(){
        .width = width,
        .height = height,
        .cells = cells,
    };
}

pub fn deinit(self: *@This()) void {
    gnorp.allocator.free(self.cells);
    self.* = undefined;
}

/// toCells converts the given image to a set of cells.
fn toCells(img: *zimg.Image, palette: *const Palette) ![]Cell {
    var cells = try gnorp.allocator.alloc(Cell, img.width * img.height);
    errdefer gnorp.allocator.free(cells);

    switch (img.pixels) {
        .indexed4 => |*x| return toCellsIndexed(palette, x.palette, x.indices, cells),
        .indexed8 => |*x| return toCellsIndexed(palette, x.palette, x.indices, cells),
        .indexed16 => |*x| return toCellsIndexed(palette, x.palette, x.indices, cells),
        .grayscale1 => |x| return toCellsColors(palette, x, cells),
        .grayscale2 => |x| return toCellsColors(palette, x, cells),
        .grayscale4 => |x| return toCellsColors(palette, x, cells),
        .grayscale8 => |x| return toCellsColors(palette, x, cells),
        .grayscale16 => |x| return toCellsColors(palette, x, cells),
        .grayscale8Alpha => |x| return toCellsColors(palette, x, cells),
        .grayscale16Alpha => |x| return toCellsColors(palette, x, cells),
        .rgb565 => |x| return toCellsColors(palette, x, cells),
        .rgb555 => |x| return toCellsColors(palette, x, cells),
        .rgb24 => |x| return toCellsColors(palette, x, cells),
        .rgba32 => |x| return toCellsColors(palette, x, cells),
        .bgr24 => |x| return toCellsColors(palette, x, cells),
        .bgra32 => |x| return toCellsColors(palette, x, cells),
        .rgb48 => |x| return toCellsColors(palette, x, cells),
        .rgba64 => |x| return toCellsColors(palette, x, cells),
        .float32 => |x| {
            var i: usize = 0;
            while (i < cells.len) : (i += 1) {
                cells[i] = try palette.toState(x[i]);
            }
            return cells;
        },
        else => return error.UnsupportedFormat,
    }
}

fn toCellsIndexed(dstpal: *const Palette, srcpal: anytype, indices: anytype, cells: []Cell) ![]Cell {
    var i: usize = 0;
    while (i < cells.len) : (i += 1) {
        cells[i] = try dstpal.toState(srcpal[indices[i]].toColorf32());
    }
    return cells;
}

fn toCellsColors(pal: *const Palette, colors: anytype, cells: []Cell) ![]Cell {
    var i: usize = 0;
    while (i < cells.len) : (i += 1) {
        cells[i] = try pal.toState(colors[i].toColorf32());
    }
    return cells;
}
