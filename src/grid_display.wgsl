
struct GridUniforms {
    mat_model: mat4x4<f32>,
    palette: array<vec4<f32>, 9>,
    grid_width: u32,
    grid_height: u32,
}

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@group(0) @binding(0) var<uniform> global_uniforms: SharedUniforms;
@group(0) @binding(1) var<uniform> grid_uniforms: GridUniforms;
@group(0) @binding(2) var<storage, read> cells: array<u32, CELL_CAPACITY>;

@vertex fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOut {
    let gw = f32(grid_uniforms.grid_width);
    let gh = f32(grid_uniforms.grid_height);

    let vertices = array<vec4<f32>, 4>(
        vec4<f32>(0.0,  gh, 0.0, 1.0),
        vec4<f32>( gw,  gh, 0.0, 1.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
        vec4<f32>( gw, 0.0, 0.0, 1.0),
    );

    let uv = array<vec2<f32>, 4>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
    );

    let mvp = global_uniforms.mat_projection * grid_uniforms.mat_model;
    var output: VertexOut;
    output.position = mvp * vertices[vertex_index];
    output.uv = uv[vertex_index];
    return output;
}

@fragment fn fs_main(
    @location(0) uv: vec2<f32>
) -> @location(0) vec4<f32> {
    // let gw = grid_uniforms.grid_width;
    // let gh = grid_uniforms.grid_height;
    // let gw_ints = gw / 4u;
    // let x = u32(uv.x * f32(gw));
    // let y = u32(uv.y * f32(gh));
    // let int = y * gw_ints + x;
    // let shift = (int % 4u) * 8u;
    // let color = (cells[int] >> shift) & 0xffu;

    let gw = grid_uniforms.grid_width;
    let gh = grid_uniforms.grid_height;
    let x = u32(uv.x * f32(gw));
    let y = u32(uv.y * f32(gh));
    var color = cells[y * gw + x];

    if(color > 0u) {
        return grid_uniforms.palette[color];
    }

    // Create a checkerboard background in place of empty cells.
    let xv = x % 2u == 0u;
    let yv = y % 2u == 0u;
    if((xv && !yv) || (!xv && yv)) {
        return vec4<f32>(0.0);
    } else {
        return vec4<f32>(0.15);
    }
}