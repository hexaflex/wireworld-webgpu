## Wireworld-webgpu

**Note**: Experimental repository -- Work in progress.

**Requirements**: Zig 0.10

This program implements the rules for the [Wireworld cellular automata][1]. This particular version is an experiment whereby the simulation is run entirely on the GPU using a compute shader. Simulations can be loaded from external image files or drawn directly in the program.

The program uses [WebGPU][2] and [GLFW 3.3][3] through [mach][4] core libraries. It has been tested on a `GeForce GTX 750 Ti` with driver version `NVIDIA 510.85.02`. On this system, the `testdata/primes.png` simulation runs up to about 600Hz before the application starts being sluggish. At this speed, it takes about 5 minutes to compute one prime number. A potato could probably do it faster, but it works.

[1]: https://en.wikipedia.org/wiki/Wireworld
[2]: https://www.w3.org/TR/webgpu/
[3]: https://www.glfw.org/Version-3.3-released.html
[4]: https://github.com/hexops/mach


![screenshot of primes.png simulation](https://github.com/hexaflex/wireworld-webgpu/blob/trunk/screenshot1.jpg?raw=true)


### Usage

  $ git clone https://github.com/hexaflex/wireworld-webgpu
  $ cd wireworld-webgpu
  $ git submodule update --init --recursive
  $ zig build run -- testdata/primes.png


The program can load simulations from an image file. The image is expected to be drawn using a known color palette. The loader uses this palette to determine what kind of cell state a specific pixel represents.

The default palette is as follows:

 Cell State    | RGB Color  | Purpose
 :-------------|:-----------|:-------------------------------------------------
 Empty         | #000000    | Background cell  - ignored by simulator.
 Annotation 1  | #b6b6b6    | Annotation color - ignored by simulator.
 Annotation 2  | #323232    | Annotation color - ignored by simulator.
 Annotation 3  | #ff0000    | Annotation color - ignored by simulator.
 Annotation 4  | #0000ff    | Annotation color - ignored by simulator.
 Annotation 5  | #ffff00    | Annotation color - ignored by simulator.
 Wire          | #015b96    | Signal carrier.
 Electron Head | #ffffff    | Head of a signal.
 Electron Tail | #99ff00    | Tail of a signal - determines signal direction.


---

For your convenience, the `testdata/palette.gpl` file contains a GIMP Palette with the default colors recognized by this program. Empty cells and cells with annotations colors are ignored by the simulator.

The color palette can be changed by providing custom RGB values through the respective `-pal-???` commandline flags. These should match the colors used in the input image. Pixels with unrecognized colors in the input image are ignored and treated as an empty cell. The color should come in the hexadecimal notation: `#rrggbb`. The commandline flags for the colors are `--pal-empty`. `--pal-wire`, `--pal-head`, `--pal-tail`, `--pal-notes1`, `--pal-notes2`, `--pal-notes3`, `--pal-notes4` and `--pal-notes5`.

Refer to the `testdata` directory for examples of images with Wireworld simulations.


### Keyboard shortcuts

  Key               | Description
 -------------------|------------------------------------
  Escape            | Close the program.
  Q                 | Start/Stop the simulation.
  E                 | Perform a single simulation step.
  W                 | Double the simulation speed.
  S                 | Halve the simulation speed.
  F5                | Reset the simulation (reloads the original input image).
  ---               | 
  Ctrl-N            | Create a new, blank simulation.
  1                 | Select Wire draw tool.
  2                 | Select Electron Head draw tool.
  3                 | Select Electron Tail draw tool.
  4                 | Select Annotation Color 1 draw tool.
  5                 | Select Annotation Color 2 draw tool.
  6                 | Select Annotation Color 3 draw tool.
  7                 | Select Annotation Color 4 draw tool.
  8                 | Select Annotation Color 5 draw tool.
  Hold LMB          | Fill cell under cursor with selected draw tool.
  Hold RMB          | Clear cell under mouse cursor.
  ---               | 
  Space + Mousemove | Pan the camera left/right/up/down. 
  Mouse Scroll      | Zoom in/out. 
  V                 | Center the simulation in the window.


---

### TODO

* Add cell selection controls.
* Add controls for mass- cell manipulation like fill, cut/copy/paste, rotate, flip, etc.
* Add controls to resize a simulation.
* Add undo/redo history and controls.
* Add UI with for simulation and drawing controls.
* Add means to load, save and import circuits.
* Add means to save and load versioned simulation snapshots.
* Add commandline handling so the program can load a simulation, optionally with custom palette, at program launch.
* Figure out a way to determine optimal workgroup size and divide workload up as applicable. Currently only one workgroup dimension is used at 100% capacity.

---

### License

Unless otherwise stated, this project and its contents are provided under a
3-Clause BSD license. Refer to the LICENSE file for its contents.