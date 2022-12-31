const std = @import("std");
const gnorp = @import("gnorp");
const App = @import("app.zig");
const Palette = @import("palette.zig");
const build_options = @import("build_options");

pub const GPUInterface = gnorp.getInterface();

test {
    std.testing.refAllDecls(@This());
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try gnorp.init(alloc, .{
        .build_prefix = build_options.build_prefix,
        .content_dir = build_options.content_dir,
        .title = build_options.title ++ " " ++ build_options.version,
        .width = 1200,
        .height = 675,
        .vsync = .no_buffer,
        .fixed_framerate = 0,
    });
    defer gnorp.deinit();

    var app: *App = undefined;
    if (try parseCommandLine(alloc)) |args| {
        defer args.deinit(alloc);
        app = try App.init(args.filename, &args.palette);
    } else {
        app = try App.init(null, null);
    }

    defer app.deinit();
    try gnorp.run(app, App.update, App.draw);
}

/// parseCommandLine reads commandline arguments, if any.
fn parseCommandLine(alloc: std.mem.Allocator) !?Args {
    var cmd = try std.process.argsWithAllocator(alloc);
    defer cmd.deinit();

    if (!cmd.skip())
        return null;

    var args = Args{};
    while (cmd.next()) |str| {
        if (try testColor(&cmd, str, "--pal-empty", &args.palette.empty)) continue;
        if (try testColor(&cmd, str, "--pal-wire", &args.palette.wire)) continue;
        if (try testColor(&cmd, str, "--pal-head", &args.palette.head)) continue;
        if (try testColor(&cmd, str, "--pal-tail", &args.palette.tail)) continue;
        if (try testColor(&cmd, str, "--pal-notes1", &args.palette.notes1)) continue;
        if (try testColor(&cmd, str, "--pal-notes2", &args.palette.notes2)) continue;
        if (try testColor(&cmd, str, "--pal-notes3", &args.palette.notes3)) continue;
        if (try testColor(&cmd, str, "--pal-notes4", &args.palette.notes4)) continue;
        if (try testColor(&cmd, str, "--pal-notes5", &args.palette.notes5)) continue;
        args.filename = try alloc.dupe(u8, str);
        break;
    }

    return if (args.filename.len > 0) args else null;
}

inline fn testColor(
    cmd: *std.process.ArgIterator,
    key_have: []const u8,
    key_want: []const u8,
    clr: *Palette.Color,
) !bool {
    if (!std.ascii.endsWithIgnoreCase(key_have, key_want)) return false;
    const hex = cmd.next() orelse return error.MissingColorValue;
    clr.* = try parseColor(hex);
    return true;
}

/// parseColor attempts to parse the given string into an RGB color.
/// The string is expected to be in the hexadecimal form: "#RRGGBB".
fn parseColor(hex: []const u8) !Palette.Color {
    if (hex.len != 7) return error.InvalidColor;
    if (hex[0] != '#') return error.InvalidColor;
    const r = try std.fmt.parseUnsigned(u8, hex[1..3], 16);
    const g = try std.fmt.parseUnsigned(u8, hex[3..5], 16);
    const b = try std.fmt.parseUnsigned(u8, hex[5..], 16);
    return .{ r, g, b };
}

const Args = struct {
    filename: []const u8 = "",
    palette: Palette = .{},

    pub fn deinit(self: *const @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.filename);
    }
};
