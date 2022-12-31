
struct GridUniforms {
    grid_width: u32,
    grid_height: u32,
}

@group(0) @binding(0) var<uniform> grid_uniforms: GridUniforms;
@group(0) @binding(1) var<storage, read> cells_in: array<u32, CELL_CAPACITY>;
@group(0) @binding(2) var<storage, read_write> cells_out: array<u32, CELL_CAPACITY>;

@compute
@workgroup_size(WORKGROUP_X, WORKGROUP_Y, WORKGROUP_Z)
fn cs_main(
    @builtin(local_invocation_id) local_invocation_id: vec3<u32>,
) {
    let CELL_WIRE = 6u;
    let CELL_TAIL = 7u;
    let CELL_HEAD = 8u;

    // Each workitem processes a subset of rows in the grid in parallel.
    // The number of rows per work item being grid_height / WORKGROUP_X.
    //
    // We divide up rows instead of columns, because the grid is stored as
    // a contiguous block of memory. Meaning rows immediately follow one
    // another. By splitting the workload into rows, we can ensure optimal
    // memory locality in so far as that is relevant.

    let gw = grid_uniforms.grid_width;
    let gh = grid_uniforms.grid_height;
    let block_height = gh / WORKGROUP_X;
    let row_start = local_invocation_id.x * block_height;
    let start = row_start * gw;
    let end = start + block_height * gw;

    for(var i = start; i <= end; i++) {
        switch (cells_in[i]) {
            case 6u: { cells_out[i] = checkNeighbours(i); }
            case 7u: { cells_out[i] = CELL_WIRE; }
            case 8u: { cells_out[i] = CELL_TAIL; }
            default: { cells_out[i] = cells_in[i]; }
        }
    }
}

/// checkNeighbours counts the number of HEAD cells surrounding cell n.
/// Returns CELL_HEAD iff there are exactly 1 or 2. Otherwise returns
/// CELL_WIRE.
fn checkNeighbours(n: u32) -> u32 {
    let row_up = n - grid_uniforms.grid_width;
    let row_down = n + grid_uniforms.grid_width;

    // We can easily and quickly count only the HEAD cells because of their
    // value (8). It is the only state value with more than three bits. So if we
    // shift each cell state right by three bits, only HEAD cells will remain
    // with a value of one. Now it is simply a matter of summing then.
    let count =
        (cells_in[row_up   - 1u] >> 3u) + 
        (cells_in[row_up       ] >> 3u) + 
        (cells_in[row_up   + 1u] >> 3u) +
        (cells_in[n        - 1u] >> 3u) + 
        (cells_in[n        + 1u] >> 3u) +
        (cells_in[row_down - 1u] >> 3u) + 
        (cells_in[row_down     ] >> 3u) + 
        (cells_in[row_down + 1u] >> 3u);

    let CELL_WIRE = 6u;
    let CELL_HEAD = 8u;

    if(count == 1u || count == 2u) {
        return CELL_HEAD;
    }

    return CELL_WIRE;
}