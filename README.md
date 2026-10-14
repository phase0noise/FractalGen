# FractalGen

A Mandelbrot explorer for the Terasic DE0-CV, written in Verilog for the
Cyclone V 5CEBA4F23C7. Connect a VGA monitor and PS/2 keyboard to navigate,
change palettes, and save screenshots to microSD.

| Mode | Resolution | Rendering |
| --- | --- | --- |
| Preview | 640 x 480 | Interactive navigation, 511 iterations |
| HD | 1280 x 1024 at 60 Hz | Progressive rendering, up to 32,767 iterations per sample |
| 4K screenshot | 3840 x 2160 | Off-screen render saved as a BMP |

Seven workers run at 75 MHz with Q8.24 coordinates. HD and 4K use adaptive
antialiasing. Sixteen palettes, animated effects, and RGB888 screenshot output
are available. Render time depends on the view and iteration count.

## Run on the board

The prebuilt programming image is included at
[`output_files/Mandel.sof`](output_files/Mandel.sof), alongside its source
hashes and Quartus resource/timing summaries.

1. Open `Mandel.cdf` in Quartus Programmer, select USB-Blaster, and program
   the board. The `.sof` configuration is lost when power is removed.
2. Connect VGA and a PS/2 keyboard. Start with the switches down, raise SW9
   briefly, then lower it to reset.
3. Try SW8 for Smooth + Vivid and SW1 for palette animation. Press **3** or
   **F3** for a different palette.
4. Press **O** or **KEY3** for HD. The monitor must support 1280 x 1024 at 60 Hz.

## Controls

| Key | Action |
| --- | --- |
| W / A / S / D | Pan |
| Enter / Space | Zoom in / out |
| O | Toggle HD rendering |
| C / V | Next / previous palette |
| [ / ] | Shift colors |
| - / + | Change animation speed |
| L | Toggle the preview lens |
| B / R | Save / restore one bookmark |
| F12 | Save the current image to SD |
| F11 | Render and save a 4K image |
| Esc | Cancel rendering or saving; reset the preview view |

Use a FAT16 or FAT32 microSD card. Screenshots are 24-bit BMPs named
`FRAC0000.BMP`, `FRAC0001.BMP`, and so on. The [control reference](docs/controls.md)
lists all keys, board switches, palettes, and status LEDs.

## Build and simulate

Use Quartus Prime Lite 23.1 with Cyclone V device support. Open `Mandel.qpf`
and compile, or run the Python helper from the project root:

```powershell
py tools/build.py
py tools/build.py --check
```

The helper builds from a fresh source copy and checks all four timing corners
before replacing the programming image. `--check` verifies the included image
against the current project sources. The Quartus project and top-level entity
are named `Mandel`.

For simulation, install Python 3.10 or newer and Icarus Verilog:

```powershell
py tools/verify.py --jobs 3
```

On Linux, use `python3` in place of `py`.

## Project files

- `rtl/`: FPGA HDL and shared constants.
- `Mandel.qpf`, `Mandel.qsf`, `Mandel.sdc`, `Mandel.cdf`: Quartus project, pins,
  timing constraints, and programming chain.
- `output_files/`: programming image, build manifest, and fit/timing summaries.
- `tests/`: HDL benches, simulation models, and reference calculations.
- `tools/`: build, timing, and simulation helpers.
- `docs/`: [architecture](docs/architecture.md), [renderer](docs/renderer.md),
  [SD screenshots](docs/sd-screenshots.md), and [development](docs/development.md).
