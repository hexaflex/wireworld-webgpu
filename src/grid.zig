const std = @import("std");
const gpu = @import("gpu");
const zmath = @import("zmath");
const gnorp = @import("gnorp");
const graphics = gnorp.graphics;
const math = gnorp.math;
const Circuit = @import("circuit.zig");
const Palette = @import("palette.zig");

test {
    std.testing.refAllDecls(@This());
}

/// Cell defines possible cell states.
///
/// The order and value of these are 1:1 matches to color palette indices.
/// Additionally, the values are important for the correct functioning of the
/// compute shader applying the Wireworld rules.
///
/// Refer to assets/embed/grid_compute.wgsl for details on how this works.
pub const Cell = enum(u32) {
    /// empty defines empty cells. These are ignored by the simulator.
    empty = 0,

    /// notes are not simulation states, but can be used by the user to draw
    /// annotations next to circuits. Like empty cells, these are ignored by the
    /// simulator.
    notes1 = 1,
    notes2 = 2,
    notes3 = 3,
    notes4 = 4,
    notes5 = 5,

    /// wire defines conductive wires. These carry signals made up of
    /// electron head- and tail cells.
    wire = 6,

    /// tail cells are the trailing end of a signal. These help determine the
    /// direction a signal travels in.
    tail = 7,

    /// head defines the front of a signal traveling along a wire.
    head = 8,
};

const RenderUniforms = extern struct {
    mat_model: zmath.Mat,
    palette: [@typeInfo(Palette).Struct.fields.len][4]f32,
    grid_width: u32,
    grid_height: u32,
};

const ComputeUniforms = extern struct {
    grid_width: u32,
    grid_height: u32,
};

pub const RenderUniformBuffer = graphics.UniformBuffer(RenderUniforms);
pub const ComputeUniformBuffer = graphics.UniformBuffer(ComputeUniforms);

const index_buffer_size = 6 * @sizeOf(u16);

pub const min_zoom = 1.0;
pub const max_zoom = 15.0;

render_uniforms: *RenderUniformBuffer = undefined,
render_pipeline: ?*gpu.RenderPipeline = null,
render_bindgroup: ?*gpu.BindGroup = null,

compute_uniforms: *ComputeUniformBuffer = undefined,
compute_pipeline: ?*gpu.ComputePipeline = null,
compute_bindgroup: ?*gpu.BindGroup = null,
compute_buffer_in: ?*gpu.Buffer = null,
compute_buffer_out: ?*gpu.Buffer = null,
max_compute_invocations: u32 = 1,
workgroup_size: u32 = 64,

transform: math.Transform = math.Transform.init(),
cells: []Cell = undefined,
index_buffer: *gpu.Buffer = undefined,
palette: Palette = undefined,
refcount: usize = 0,
width: u32 = 0,
height: u32 = 0,
step_count: usize = 0,

/// initFromCircuit creates a new grid from the given circuit.
///
/// The grid is expected to maintain a 1-cell border where cell states will
/// always be .empty. Therefor this call will add 2 to the Circuit dimensions
/// to create the border.
pub fn initFromCircuit(c: *const Circuit) !*@This() {
    var self = try initFromSize(c.width, c.height);
    errdefer self.release();
    try self.loadCircuit(1, 1, c);
    return self;
}

/// initFromSize creates an empty grid with the given dimensions.
///
/// The grid is expected to maintain a 1-cell border where cell states will
/// always be .empty. Therefor this call will add 2 to the width and height
/// to create the border.
pub fn initFromSize(width: u32, height: u32) !*@This() {
    var self = try init();
    errdefer self.release();

    try self.resize(width + 2, height + 2);

    self.center(try graphics.getFramebufferSize());
    return self;
}

/// init creates a new, empty grid.
pub fn init() !*@This() {
    var self = try gnorp.allocator.create(@This());
    errdefer gnorp.allocator.destroy(self);

    self.* = .{};

    // Determine the number of compute workgroups we can split cell data
    // over. This allows for parallel processing of the simulation.
    //
    // We divide max_compute_workgroup_size by 2 instead of using the full
    // set of available workgroups, as not to tie up the GPU completely.
    var sl = gpu.SupportedLimits{ .limits = undefined };
    _ = graphics.device.getLimits(&sl);

    if (sl.limits.max_compute_workgroup_size_x < 2)
        return error.InsufficientComputeWorkgroups;

    self.max_compute_invocations = sl.limits.max_compute_invocations_per_workgroup;
    self.workgroup_size = @max(sl.limits.max_compute_workgroup_size_x, 64);

    gnorp.log.debug(@src(), "grid workgroup size: {any}", .{self.workgroup_size});

    // Initialize the remainder of the grid.

    self.render_uniforms = try RenderUniformBuffer.init();
    errdefer self.render_uniforms.release();

    self.compute_uniforms = try ComputeUniformBuffer.init();
    errdefer self.compute_uniforms.release();

    try self.initIndexBuffer();

    self.setPalette(.{});
    self.setZoom(@as(u32, max_zoom) / 2);
    return self.reference();
}

fn deinit(self: *@This()) void {
    if (self.render_pipeline) |v| v.release();
    if (self.render_bindgroup) |v| v.release();
    if (self.compute_buffer_in) |v| v.release();
    if (self.compute_buffer_out) |v| v.release();
    if (self.compute_pipeline) |v| v.release();
    if (self.compute_bindgroup) |v| v.release();

    self.render_uniforms.release();
    self.compute_uniforms.release();
    self.index_buffer.release();

    var alloc = gnorp.allocator;
    alloc.free(self.cells);
    alloc.destroy(self);
}

/// reference increments this object's reference counter and returns itself.
pub inline fn reference(self: *@This()) *@This() {
    return gnorp.resources.reference(self);
}

/// release decrements the object's reference counter and calls deinit()
/// on it if it reaches zero. This is a no-op if the refcount is already zero.
pub fn release(self: *@This()) void {
    gnorp.resources.release(self, deinit);
}

/// toOwnedCircuit returns the grid contents as a Circuit instance.
/// Caller owns the returned memory.
pub inline fn toOwnedCircuit(self: *const @This()) !Circuit {
    return try Circuit.init(self.width, self.height, self.cells);
}

/// getCellCount returns the cell buffer's size in cells.
inline fn getCellCount(self: *const @This()) usize {
    return self.width * self.height;
}

/// getCellSize returns the cell buffer's size in bytes.
inline fn getCellSize(self: *const @This()) usize {
    return self.getCellCount() * @sizeOf(Cell);
}

/// getCellScale returns the dimensions of a single cell, accounting for
/// the current zoon factor.
pub inline fn getCellScale(self: *const @This()) [2]f32 {
    return self.transform.scale;
}

/// indexOf returns the cell index for the given coordinates.
/// Returns null if x/y are out of range. Out of range includes the 1-cell border.
inline fn indexOf(self: *const @This(), x: u32, y: u32) ?usize {
    return if (x > 0 and x < self.width - 1 and y > 0 and y < self.height - 1)
        (y * self.width + x)
    else
        null;
}

/// getCellCoordinates returns the cell at the given pixel location.
/// The returned cell coordinates are clamped to a valid range, even if the
/// given location is outside the grid.
pub fn getCellCoordinates(self: *const @This(), pos: [2]f32) [2]u32 {
    const px = pos[0] - self.transform.position[0];
    const py = pos[1] - self.transform.position[1];
    const sx = self.transform.scale[0];
    const sy = self.transform.scale[1];
    const cx = @floatToInt(i32, px / sx);
    const cy = @floatToInt(i32, py / sy);
    return .{
        @intCast(u32, @max(@min(cx, @intCast(i32, self.width) - 1), 0)),
        @intCast(u32, @max(@min(cy, @intCast(i32, self.height) - 1), 0)),
    };
}

/// getCellAt returns the cell at the given pixel location.
/// The returned cell coordinates are clamped to a valid range,
/// even if the given location is outside the grid.
pub inline fn getCellAt(self: *const @This(), pos: [2]f32) Cell {
    const tile = self.getCellCoordinates(pos);
    return self.getCell(tile[0], tile[1]);
}

/// getCell returns the cell at the given coordinates.
/// Returns .empty if x/y are out of range.
pub inline fn getCell(self: *const @This(), x: u32, y: u32) Cell {
    return if (self.indexOf(x, y)) |index|
        self.cells[index]
    else
        .empty;
}

/// setCellAt sets the cell at the given pixel location.
/// This call is silently ignored if the coordinates are out of range.
///
/// The grid is expected to maintain a 1-cell border where cell states will
/// always be .empty. So callers should take care to write only within that
/// border. The reason for the border is to make the compute shader simpler.
/// It removes the need for a lot of branching statements where it would need
/// to check for grid bounds. Any writes to border cells will be silently
/// ignored.
pub inline fn setCellAt(self: *@This(), pos: [2]f32, cell: Cell) void {
    const tile = self.getCellCoordinates(pos);
    self.setCell(tile[0], tile[1], cell);
}

/// setCell sets the cell at the given coordinates.
/// This call is silently ignored if x/y are out of range.
///
/// The grid is expected to maintain a 1-cell border where cell states will
/// always be .empty. So callers should take care to write only within that
/// border. The reason for the border is to make the compute shader simpler.
/// It removes the need for a lot of branching statements where it would need
/// to check for grid bounds. Any writes to border cells will be silently
/// ignored.
pub fn setCell(self: *@This(), x: u32, y: u32, cell: Cell) void {
    if (self.indexOf(x, y)) |index| {
        self.cells[index] = cell;

        graphics.device.getQueue().writeBuffer(
            self.compute_buffer_in.?,
            index * @sizeOf(Cell),
            self.cells[index .. index + 1],
        );
    }
}

/// loadCircuit loads the given circuit into the grid at the specified
/// coordinates. Any cells falling outside the grid are silently ignored.
///
/// The grid is expected to maintain a 1-cell border where cell states will
/// always be .empty. So callers should take care to write only within
/// that border. The reason for the border is to make the compute shader
/// simpler. It removes the need for a lot of branching statements where
/// it would need to check if it is at an edge cell or not. Any writes to
/// border cells will be silently ignored.
pub fn loadCircuit(self: @This(), x: u32, y: u32, c: *const Circuit) !void {
    const dx = @max(x, 1);
    const dy = @max(y, 1);
    const sx = if (dx == x) @as(u32, 0) else 1;
    const sy = if (dy == y) @as(u32, 0) else 1;
    return self.loadSubCircuit(dx, dy, sx, sy, c);
}

/// loadSubCircuit loads a subset of circuit c into the grid.
fn loadSubCircuit(self: @This(), dx: u32, dy: u32, sx: u32, sy: u32, c: *const Circuit) !void {
    if (dx >= self.width - 1 or dy >= self.height - 1)
        return; // entirely out of bounds.

    if (c.width == 0 or c.height == 0)
        return;

    if (c.cells.len < c.width * c.height)
        return error.InvalidCircuit;

    const cols = @min(self.width - dx - 1, c.width - sx);
    const rows = @min(self.height - dy - 1, c.height - sy);
    if (rows == 0) return;

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        if ((dy + r) == 0) continue;
        if ((dy + r) == self.height - 1) break;

        const dst = (dy + r) * self.width + dx;
        const src = (sy + r) * c.width + sx;
        std.mem.copy(Cell, self.cells[dst .. dst + cols], c.cells[src .. src + cols]);
    }

    graphics.device.getQueue().writeBuffer(self.compute_buffer_in.?, 0, self.cells);
}

/// setPalette sets the color palette to the given values.
pub fn setPalette(self: *@This(), pal: Palette) void {
    self.palette = pal;
    self.transform.dirty = true;
}

/// Scroll moves the grid origin by the given relative offset.
pub fn scroll(self: *@This(), offset: [2]f32) void {
    const pos = self.transform.position;
    self.transform.setPosition(.{ pos[0] + offset[0], pos[1] + offset[1] });
}

/// centerPosition centers the given pixel position on the tilemap in the
/// specified viewport.
pub inline fn centerPosition(self: *@This(), pos: [2]f32, view: [2]f32) void {
    self.transform.setPosition(.{
        (view[0] * 0.5) - pos[0],
        (view[1] * 0.5) - pos[1],
    });
}

/// center centers the grid in the specified viewport.
pub inline fn center(self: *@This(), view: [2]f32) void {
    self.centerCell(self.width / 2, self.height / 2, view);
}

/// centerCell centers the given cell in the specified viewport.
pub fn centerCell(self: *@This(), x: u32, y: u32, view: [2]f32) void {
    const zf = self.transform.scale;
    const cx = @intToFloat(f32, x) * zf[0];
    const cy = @intToFloat(f32, y) * zf[1];

    self.transform.setPosition(.{
        (view[0] * 0.5) - (cx + (zf[0] * 0.5)),
        (view[1] * 0.5) - (cy + (zf[1] * 0.5)),
    });
}

/// setZoom sets the current zoom factor.
/// Value is clamped to the range [min_zoom, max_zoom].
pub fn setZoom(self: *@This(), factor: u32) void {
    const cf = std.math.clamp(@intToFloat(f32, factor), min_zoom, max_zoom);
    self.transform.setScale(.{ cf, cf });
}

/// zoom zooms in/out by the specified amount using the given point as
/// the zoom focus.
pub fn zoom(self: *@This(), delta: i32, focus: [2]f32) void {
    if (delta == 0) return;

    // Zooming needs to center on the given focal point.
    // For this to work, we figure out which position on the grid is currently
    // under the focus point. Then we perform the zoom and scroll back to that
    // position.

    const origin = self.transform.position;
    const abs_focus = [2]f32{
        focus[0] - origin[0],
        focus[1] - origin[1],
    };
    const fdelta = [2]f32{
        @intToFloat(f32, delta),
        @intToFloat(f32, delta),
    };

    const old_scale = self.transform.scale;
    self.transform.setScale(.{
        std.math.clamp(old_scale[0] + fdelta[0], min_zoom, max_zoom),
        std.math.clamp(old_scale[1] + fdelta[1], min_zoom, max_zoom),
    });

    const xy1 = [2]f32{
        abs_focus[0] / old_scale[0],
        abs_focus[1] / old_scale[1],
    };

    self.transform.setPosition(.{
        abs_focus[0] - ((xy1[0] * self.transform.scale[0]) - origin[0]),
        abs_focus[1] - ((xy1[1] * self.transform.scale[1]) - origin[1]),
    });
}

/// update updates the sprite's animation state if needed. Additionally, it
/// ensures the shader has the most up-to-date model matrix value.
pub fn update(self: *@This()) !void {
    if (self.transform.getModelIfUpdated()) |mat| {
        self.render_uniforms.set(&.{
            .mat_model = mat,
            .palette = self.palette.toFloat(),
            .grid_width = self.width,
            .grid_height = self.height,
        });
    }
}

/// draw returns a commandbuffer with the sprite drawing operations.
/// The returned buffer can be submitted to the GPU for execution.
/// Caller must release the buffer after use.
pub fn draw(self: *@This(), encoder: *gpu.CommandEncoder) !void {
    if (self.cells.len == 0) return;

    const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = @typeName(@This()) ++ " render pass",
        .color_attachments = &.{graphics.getColorAttachment(.load)},
    }));

    pass.setIndexBuffer(self.index_buffer, .uint16, 0, index_buffer_size);
    pass.setPipeline(self.render_pipeline.?);
    pass.setBindGroup(0, self.render_bindgroup.?, &.{});
    pass.drawIndexed(6, 1, 0, 0, 0);
    pass.end();
    pass.release();
}

/// step performs n simulation steps. This involves copying buffer data to between
/// RAM and VRAM, which is expensive. This is done before and after the compute
/// passes are run. A higher value for n is therefore more efficient.
pub fn step(self: *@This(), n: usize) void {
    if (n == 0 or self.getCellCount() == 0)
        return;

    self.step_count += n;

    var encoder = graphics.device.createCommandEncoder(null);
    defer encoder.release();

    var in = self.compute_buffer_in.?;
    var out = self.compute_buffer_out.?;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const pass = encoder.beginComputePass(null);

        pass.setPipeline(self.compute_pipeline.?);
        pass.setBindGroup(0, self.compute_bindgroup.?, &.{});
        pass.dispatchWorkgroups(1, 1, 1);
        pass.end();
        pass.release();

        // Copy the output of the current compute pass the input of the next pass.
        encoder.copyBufferToBuffer(out, 0, in, 0, self.getCellSize());
    }

    const commands = encoder.finish(null);
    graphics.device.getQueue().submit(&[_]*gpu.CommandBuffer{commands});
    commands.release();
}

/// clear removes all cells from the grid.
/// This sets the grid dimensions to 0, 0.
pub fn clear(self: *@This()) !void {
    gnorp.allocator.free(self.cells);
    self.cells = &.{};
    self.width = 0;
    self.height = 0;
    try self.initCellBuffers();
    try self.initRenderPipeline();
    try self.initComputePipeline();
}

/// resize grows or shrinks the grid to the given dimensions.
/// height is increased to be a multiple of Grid.workgroup_size if needed.
///
/// This tries to preserve contents where possible. If the new width or height
/// are less than the existing width/height, contents will be truncated.
///
/// Specifying 0 for either width or height will remove all cells.
pub fn resize(self: *@This(), width: u32, height: u32) !void {
    const fh = @intToFloat(f32, height);
    const fws = @intToFloat(f32, self.workgroup_size);
    const new_height = @floatToInt(u32, fws * @divFloor(fh, fws) + fws);
    const new_width = width;

    gnorp.log.debug(@src(), "grid resizing to {} x {}", .{ new_width, new_height });

    // No point in continuing if the size is the same.
    if (new_width == self.width and new_height == self.height)
        return;

    if (new_width == 0 or new_height == 0)
        return self.clear();

    // Compute new capacity.
    const capacity = @as(usize, new_width) * @as(usize, new_height);

    // Allocate buffers with new cell capacity.
    var alloc = gnorp.allocator;
    var cells = try alloc.alloc(Cell, capacity);
    errdefer alloc.free(cells);
    std.mem.set(Cell, cells, .empty);

    // Copy old content over to new buffer.
    const cols = @min(self.width, new_width);
    const rows = @min(self.height, new_height);

    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const dsti = y * new_width;
        const srci = y * self.width;
        std.mem.copy(Cell, cells[dsti .. dsti + cols], self.cells[srci .. srci + cols]);
    }

    // Replace existing buffers.
    alloc.free(self.cells);
    self.cells = cells;
    self.width = new_width;
    self.height = new_height;
    self.transform.dirty = true;
    self.compute_uniforms.set(&.{
        .grid_width = self.width,
        .grid_height = self.height,
    });

    try self.initCellBuffers();
    try self.initRenderPipeline();
    try self.initComputePipeline();
}

/// initComputePipeline initializes the render pipeline and bindgroups.
fn initComputePipeline(self: *@This()) !void {
    if (self.compute_pipeline) |v| {
        v.release();
        self.compute_pipeline = null;
    }
    if (self.compute_bindgroup) |v| {
        v.release();
        self.compute_bindgroup = null;
    }
    if (self.cells.len == 0) return;

    const src = try self.getComputeShaderSrc();
    defer gnorp.allocator.free(src);

    const module = graphics.device.createShaderModuleWGSL(
        @typeName(@This()) ++ " compute shader module",
        src,
    );
    defer module.release();

    const BglEntry = gpu.BindGroupLayout.Entry;
    var compute_bindgroup_layout = graphics.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .label = @typeName(@This()) ++ " compute_bindgroup_layout",
        .entries = &.{
            BglEntry.buffer(0, .{ .compute = true }, .uniform, false, @sizeOf(ComputeUniforms)),
            BglEntry.buffer(1, .{ .compute = true }, .read_only_storage, false, self.getCellSize()),
            BglEntry.buffer(2, .{ .compute = true }, .storage, false, self.getCellSize()),
        },
    }));
    defer compute_bindgroup_layout.release();

    self.compute_pipeline = graphics.device.createComputePipeline(&.{
        .label = @typeName(@This()) ++ " compute_pipeline",
        .layout = graphics.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .label = @typeName(@This()) ++ " compute_pipeline_layout",
            .bind_group_layouts = &.{compute_bindgroup_layout},
        })),
        .compute = gpu.ProgrammableStageDescriptor.init(.{
            .module = module,
            .entry_point = "cs_main",
        }),
    });

    const BgEntry = gpu.BindGroup.Entry;
    self.compute_bindgroup = graphics.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .label = @typeName(@This()) ++ " compute_bindgroup",
        .layout = self.compute_pipeline.?.getBindGroupLayout(0),
        .entries = &.{
            BgEntry.buffer(0, self.compute_uniforms.gpu_buffer, 0, @sizeOf(ComputeUniforms)),
            BgEntry.buffer(1, self.compute_buffer_in.?, 0, self.getCellSize()),
            BgEntry.buffer(2, self.compute_buffer_out.?, 0, self.getCellSize()),
        },
    }));
}

/// initRenderPipeline initializes the render pipeline and bindgroups.
fn initRenderPipeline(self: *@This()) !void {
    if (self.render_pipeline) |v| {
        v.release();
        self.render_pipeline = null;
    }
    if (self.render_bindgroup) |v| {
        v.release();
        self.render_bindgroup = null;
    }
    if (self.cells.len == 0) return;

    const src = try self.getRenderShaderSrc();
    defer gnorp.allocator.free(src);

    const module = graphics.device.createShaderModuleWGSL(
        @typeName(@This()) ++ " render shader module",
        src,
    );
    defer module.release();

    const fragment_state = gpu.FragmentState.init(.{
        .module = module,
        .entry_point = "fs_main",
        .targets = &.{.{
            .format = graphics.getSwapchainFormat(),
            .write_mask = gpu.ColorWriteMaskFlags.all,
        }},
    });

    const vertex_state = gpu.VertexState.init(.{
        .module = module,
        .entry_point = "vs_main",
        .buffers = null,
    });

    var render_bindgroup_layout = graphics.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .label = @typeName(@This()) ++ " render_bindgroup_layout",
        .entries = &.{
            graphics.getSharedBindGroupLayoutEntry(0),
            self.render_uniforms.getBindGroupLayoutEntry(1),
            gpu.BindGroupLayout.Entry.buffer(2, .{ .fragment = true }, .read_only_storage, false, self.getCellSize()),
        },
    }));
    defer render_bindgroup_layout.release();

    self.render_pipeline = graphics.device.createRenderPipeline(&.{
        .label = @typeName(@This()) ++ " render_pipeline",
        .layout = graphics.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .label = @typeName(@This()) ++ " render_pipeline_layout",
            .bind_group_layouts = &.{render_bindgroup_layout},
        })),
        .vertex = vertex_state,
        .fragment = &fragment_state,
        .depth_stencil = null,
        .multisample = .{ .count = gnorp.config.sample_count },
        .primitive = .{ .cull_mode = .back },
    });

    self.render_bindgroup = graphics.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .label = @typeName(@This()) ++ " render_bindgroup_a2b",
        .layout = self.render_pipeline.?.getBindGroupLayout(0),
        .entries = &.{
            graphics.getSharedBindGroupEntry(0),
            self.render_uniforms.getBindGroupEntry(1),
            gpu.BindGroup.Entry.buffer(2, self.compute_buffer_in.?, 0, self.getCellSize()),
        },
    }));
}

fn initIndexBuffer(self: *@This()) !void {
    const index_data = [_]u16{ 0, 1, 2, 2, 1, 3 };

    self.index_buffer = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " index_buffer",
        .usage = .{ .copy_dst = true, .index = true },
        .size = index_buffer_size,
        .mapped_at_creation = true,
    });

    var indices = self.index_buffer.getMappedRange(u16, 0, index_data.len) orelse
        return error.IndexBufferNotMapped;
    std.mem.copy(u16, indices, &index_data);
    self.index_buffer.unmap();
}

fn initCellBuffers(self: *@This()) !void {
    if (self.compute_buffer_in) |v| v.release();
    if (self.compute_buffer_out) |v| v.release();
    if (self.cells.len == 0) return;

    self.compute_buffer_in = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " compute_buffer_in",
        .usage = .{ .copy_src = true, .copy_dst = true, .storage = true },
        .size = self.getCellSize(),
    });

    self.compute_buffer_out = graphics.device.createBuffer(&.{
        .label = @typeName(@This()) ++ " compute_buffer_out",
        .usage = .{ .copy_src = true, .copy_dst = true, .storage = true },
        .size = self.getCellSize(),
    });
}

inline fn getRenderShaderSrc(self: *const @This()) ![:0]const u8 {
    return self.getShaderSrc(@embedFile("shared_uniforms.wgsl") ++
        @embedFile("grid_display.wgsl"));
}

inline fn getComputeShaderSrc(self: *const @This()) ![:0]const u8 {
    return self.getShaderSrc(@embedFile("grid_compute.wgsl"));
}

fn getShaderSrc(self: *const @This(), src: [:0]const u8) ![:0]const u8 {
    const alloc = gnorp.allocator;
    var out = try alloc.dupeZ(u8, src);
    errdefer alloc.free(out);

    try replaceShaderSrc(out, "CELL_CAPACITY", @truncate(u32, self.cells.len));
    try replaceShaderSrc(out, "WORKGROUP_X", self.workgroup_size);
    try replaceShaderSrc(out, "WORKGROUP_Y", 1);
    try replaceShaderSrc(out, "WORKGROUP_Z", 1);
    return out;
}

/// replaceShaderSrc finds each occurrence of @key. First replaces the whole
/// thing with blank spaces and then puts in @value. E.g.:
///
///     ... cells: array<u32, CELL_CAPACITY>;
///
/// becomes:
///
///     ... cells: array<u32, 256u         >;
///
/// This assumes the formatted value will never exceed len(key)-1 in length.
/// If it does happen, error.NoSpaceLeft is returned.
fn replaceShaderSrc(out: [:0]u8, key: []const u8, value: u32) !void {
    while (std.mem.indexOf(u8, out, key)) |index| {
        var arr = out[index .. index + key.len];
        for (arr) |*b| b.* = ' ';
        _ = try std.fmt.bufPrint(arr, "{}u", .{value});
    }
}
