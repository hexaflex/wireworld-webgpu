const std = @import("std");
const glfw = @import("glfw");
const gpu = @import("gpu");
const zmath = @import("zmath");
const build_options = @import("build_options");
const gnorp = @import("gnorp");
const graphics = gnorp.graphics;
const input = gnorp.input;
const log = gnorp.log;
const timer = gnorp.timer;
const math = gnorp.math;
const Grid = @import("grid.zig");
const Palette = @import("palette.zig");
const Circuit = @import("circuit.zig");

test {
    std.testing.refAllDecls(@This());
}

const Mode = enum {
    none,
    draw,
    erase,
};

const min_step_count = 1;
const max_step_count = 20;

init_filename: ?[]const u8 = null,
init_palette: Palette = .{},

grid: *Grid = undefined,
title_timer: u64 = 0,
step_count: usize = 1,
drawing_tool: Grid.Cell = .wire,
mode: Mode = .none,
dragging: bool = false,
running: bool = false,

/// init initializes the application. Optionally loading the given simulation
/// file. The palette can be used specify a custom color palette if the input
/// image does not match the builtin palette this program uses.
pub fn init(filename: ?[]const u8, palette: ?Palette) !*@This() {
    var self = try gnorp.allocator.create(@This());
    errdefer gnorp.allocator.destroy(self);
    self.* = .{};

    graphics.window.setUserPointer(self);
    graphics.window.setKeyCallback(keyCallback);
    graphics.window.setScrollCallback(scrollCallback);
    graphics.window.setMouseButtonCallback(mouseButtonCallback);
    graphics.window.setFramebufferSizeCallback(framebufferSizeCallback);

    if (filename) |file| {
        self.init_filename = try gnorp.allocator.dupe(u8, file);
        self.init_palette = palette orelse .{};

        var sim = try Circuit.initFromFile(file, &self.init_palette);
        defer sim.deinit();

        self.grid = try Grid.initFromCircuit(&sim);
    } else {
        self.grid = try Grid.initFromSize(254, 253);
    }

    const fb = try graphics.window.getFramebufferSize();
    try self.framebufferSizeCallbackZig(fb.width, fb.height);
    return self;
}

pub fn deinit(self: *@This()) void {
    if (self.init_filename) |f|
        gnorp.allocator.free(f);

    self.grid.release();

    graphics.window.setUserPointer(null);
    graphics.window.setKeyCallback(null);
    graphics.window.setScrollCallback(null);
    graphics.window.setMouseButtonCallback(null);
    graphics.window.setFramebufferSizeCallback(null);
    gnorp.allocator.destroy(self);
}

pub fn update(self: *@This()) !void {
    if (self.dragging) {
        self.grid.scroll(.{
            -input.cursor_delta[0],
            -input.cursor_delta[1],
        });
    }

    switch (self.mode) {
        .erase => self.grid.setCellAt(input.cursor_pos, .empty),
        .draw => self.grid.setCellAt(input.cursor_pos, self.drawing_tool),
        else => {},
    }

    if (self.running)
        self.grid.step(self.step_count);

    try self.grid.update();
    try self.updateTitle();
}

pub fn draw(self: *@This()) !void {
    var encoder = graphics.device.createCommandEncoder(null);
    defer encoder.release();

    try self.grid.draw(encoder);

    const commands = encoder.finish(null);
    defer commands.release();

    graphics.device.getQueue().submit(&[_]*gpu.CommandBuffer{
        commands,
    });
}

fn framebufferSizeCallback(window: glfw.Window, width: u32, height: u32) void {
    var self = window.getUserPointer(@This()) orelse unreachable;
    self.framebufferSizeCallbackZig(width, height) catch |err| {
        log.err("framebufferSizeCallback: {}", .{err});
    };
}

fn framebufferSizeCallbackZig(_: *@This(), width: u32, height: u32) !void {
    const fw = @intToFloat(f32, width);
    const fh = @intToFloat(f32, height);
    graphics.setProjectionMatrix(zmath.orthographicOffCenterLh(0, fw, 0, fh, 0, 1));
    graphics.setViewMatrix(zmath.identity());
}

fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    var self = window.getUserPointer(@This()) orelse unreachable;
    self.mouseButtonCallbackZig(button, action, mods) catch |err| {
        log.err("mouseButtonCallback: {}", .{err});
    };
}

fn mouseButtonCallbackZig(self: *@This(), button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) !void {
    _ = mods;

    switch (action) {
        .press => switch (button) {
            .left => self.mode = .draw,
            .right => self.mode = .erase,
            else => {},
        },
        .release => switch (button) {
            .left, .right => self.mode = .none,
            else => {},
        },
        else => {},
    }
}

fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    var self = window.getUserPointer(@This()) orelse unreachable;
    self.scrollCallbackZig(xoffset, yoffset) catch |err| {
        log.err("scrollCallback: {}", .{err});
    };
}

fn scrollCallbackZig(self: *@This(), xoffset: f64, yoffset: f64) !void {
    _ = xoffset;
    self.grid.zoom(@floatToInt(i32, yoffset), input.cursor_pos);
}

fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    var self = window.getUserPointer(@This()) orelse unreachable;
    self.keyCallbackZig(key, scancode, action, mods) catch |err| {
        log.err("keyCallback: {}", .{err});
    };
}

inline fn keyCallbackZig(self: *@This(), key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) !void {
    _ = scancode;

    switch (action) {
        .press => switch (key) {
            .space => self.dragging = true,
            else => {},
        },
        .release => switch (key) {
            .space => self.dragging = false,
            .escape => gnorp.close(),
            .one => self.drawing_tool = .wire,
            .two => self.drawing_tool = .head,
            .three => self.drawing_tool = .tail,
            .four => self.drawing_tool = .notes1,
            .five => self.drawing_tool = .notes2,
            .six => self.drawing_tool = .notes3,
            .seven => self.drawing_tool = .notes4,
            .eight => self.drawing_tool = .notes5,
            .q => self.running = !self.running,
            .e => self.grid.step(1),
            .minus => self.step_count = @max(self.step_count - 1, min_step_count),
            .equal => self.step_count = @min(self.step_count + 1, max_step_count),
            .n => if (mods.control) {
                self.running = false;
                self.grid.release();
                self.grid = try Grid.initFromSize(254, 253);
            },
            .F5 => if (self.init_filename) |file| {
                var sim = try Circuit.initFromFile(file, &self.init_palette);
                defer sim.deinit();

                self.running = false;
                self.grid.release();
                self.grid = try Grid.initFromCircuit(&sim);
            },
            .v => {
                const vp = try graphics.getFramebufferSize();
                self.grid.center(vp);
            },
            else => {},
        },
        else => {},
    }
}

fn updateTitle(self: *@This()) !void {
    if ((timer.frame_time - self.title_timer) > std.time.ms_per_s) {
        const alloc = gnorp.allocator;
        self.title_timer = timer.frame_time;

        const title = try std.fmt.allocPrintZ(
            alloc,
            "{s} {s} - fps: {}, cell: {any}, running: {}, freq: {d}Hz (x{d})",
            .{
                build_options.title,
                build_options.version,
                timer.frame_rate,
                self.grid.getCellCoordinates(input.cursor_pos),
                self.running,
                self.grid.step_count,
                self.step_count,
            },
        );
        defer alloc.free(title);
        self.grid.step_count = 0;
        try graphics.window.setTitle(title);
    }
}
