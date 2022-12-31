const std = @import("std");
const glfw = @import("glfw");
const gpu = @import("gpu");
const build_options = @import("build_options");
const gnorp = @import("gnorp");
const graphics = gnorp.graphics;
const input = gnorp.input;
const log = gnorp.log;
const timer = gnorp.timer;
const Grid = @import("grid.zig");
const Palette = @import("palette.zig");
const Circuit = @import("circuit.zig");

test {
    std.testing.refAllDecls(@This());
}

const DrawMode = enum {
    none,
    draw,
    erase,
};

const min_step_count = 1;
const max_step_count = 20;

grid: *Grid = undefined,
title_timer: u64 = 0,
step_count: usize = 1,
drawing_tool: Grid.Cell = .wire,
drawing_mode: DrawMode = .none,
running: bool = false,
dragging: bool = false,

/// init initializes the application. Optionally loading the given simulation
/// file. The palette can be used specify a custom color palette if the input
/// image does not match the builtin palette this program uses.
pub fn init(filename: ?[]const u8, palette: ?*const Palette) !*@This() {
    var self = try gnorp.allocator.create(@This());
    errdefer gnorp.allocator.destroy(self);
    self.* = .{};

    graphics.window.setUserPointer(self);
    graphics.window.setKeyCallback(keyCallback);
    graphics.window.setScrollCallback(scrollCallback);
    graphics.window.setMouseButtonCallback(mouseButtonCallback);

    if (filename) |file| {
        var sim = try Circuit.initFromFile(file, palette orelse &Palette{});
        defer sim.deinit();

        self.grid = try Grid.initFromCircuit(&sim);
    } else {
        self.grid = try Grid.initFromSize(256, 256);
    }

    return self;
}

pub fn deinit(self: *@This()) void {
    self.grid.release();
    graphics.window.setUserPointer(null);
    graphics.window.setKeyCallback(null);
    graphics.window.setScrollCallback(null);
    graphics.window.setMouseButtonCallback(null);
    gnorp.allocator.destroy(self);
}

pub fn update(self: *@This()) !void {
    if (self.dragging) {
        self.grid.scroll(.{
            -input.cursor_delta[0],
            -input.cursor_delta[1],
        });
    }

    switch (self.drawing_mode) {
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

fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    var self = window.getUserPointer(@This()) orelse unreachable;
    self.mouseButtonCallbackZig(button, action, mods) catch |err| {
        log.err("mouseButtonCallback: {}", .{err});
        gnorp.close();
    };
}

fn mouseButtonCallbackZig(self: *@This(), button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) !void {
    _ = mods;

    switch (action) {
        .press => switch (button) {
            .left => self.drawing_mode = .draw,
            .right => self.drawing_mode = .erase,
            else => {},
        },
        .release => switch (button) {
            .left, .right => self.drawing_mode = .none,
            else => {},
        },
        else => {},
    }
}

fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    var self = window.getUserPointer(@This()) orelse unreachable;
    self.scrollCallbackZig(xoffset, yoffset) catch |err| {
        log.err("scrollCallback: {}", .{err});
        gnorp.close();
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
        gnorp.close();
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
            .e => self.grid.step(1),
            .n => if (mods.control) {
                self.running = false;
                try self.grid.clear();
                try self.grid.resize(100, 100);
                self.grid.center(try graphics.getFramebufferSize());
            },
            .q => self.running = !self.running,
            .s => self.step_count = @max(self.step_count - 1, min_step_count),
            .v => self.grid.center(try graphics.getFramebufferSize()),
            .w => self.step_count = @min(self.step_count + 1, max_step_count),
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
