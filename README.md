# FractalGen

A Mandelbrot explorer written in Verilog for the Terasic DE0-CV
(Cyclone V 5CEBA4F23C7). VGA output, PS/2 keyboard and board controls,
sixteen palettes, animated effects, and BMP screenshots to microSD.

| Mode | Resolution | Rendering |
| --- | --- | --- |
| Preview | 640 x 480 | Interactive navigation, 511 iterations |
| HD | 1280 x 1024 at 60 Hz | Progressive rendering, up to 32,767 iterations per sample |
| 4K screenshot | 3840 x 2160 | Off-screen render saved as a BMP |

Seven rendering workers run at 75 MHz with Q8.24 coordinates. HD and 4K use
adaptive antialiasing. Render time depends on the view and iteration count;
coordinate precision limits zoom detail.

## Controls

Pan, zoom, and lens controls work in preview. HD renders the captured view
progressively; palettes and effects can still be changed while it renders.

### Keyboard

| Key | Action |
| --- | --- |
| W / A / S / D | Pan up / left / down / right |
| Enter / Space | Zoom in / out |
| O | Switch between preview and HD |
| C / V | Next / previous palette |
| 1-8 / F1-F8 | Select palettes 0-7 / 8-15 |
| [ / ] | Shift colors |
| - / + | Slower / faster animation; keypad - / + also work |
| L | Toggle the preview lens |
| B / R | Save / restore one bookmark |
| F12 | Save the current image to SD |
| F11 | Render and save a 4K image |
| Esc | Cancel rendering or saving; reset the preview view |

### Board buttons

| Button | Action |
| --- | --- |
| KEY0 / KEY1 | Zoom in / out in preview; hold to repeat |
| KEY2 | Pan upward in preview, once per press |
| KEY3 | Switch between preview and HD |

### Switches

| Switch | Action |
| --- | --- |
| SW0 | Select HD when raised, preview when lowered; acts on position changes |
| SW1 | Burn: animate palette colors |
| SW2 | Stochastic Burn: advance scattered pixels while Burn is enabled |
| SW3 | Prism: enhance colored edges |
| SW4 | Morph: blend between palettes |
| SW5 | Glow: add luminous trails |
| SW6 | Fuzz: add scattered pixel noise |
| SW7 | Make persistent random edits to stored HD pixels |
| SW8 | Smooth + Vivid: interpolate palettes and preserve RGB888 in screenshots |
| SW9 | Reset while raised |

O and KEY3 toggle HD independently of SW0. Moving SW0 sets the mode to its
new position. Effects can be combined. Turning SW7 off stops further edits;
a new render replaces the altered image.

## Screenshots

Screenshots are 24-bit BMPs named `FRAC0000.BMP`, `FRAC0001.BMP`, and so on,
saved to a FAT16 or FAT32 microSD card. F12 waits for an unfinished HD render
before saving. F11 renders 4K off-screen while the monitor keeps its current
resolution. VGA uses RGB444; SW8 preserves eight-bit color channels in BMPs.

See [controls, palettes, and LEDs](docs/controls.md),
[architecture](docs/architecture.md), [renderer details](docs/renderer.md),
and [SD screenshots](docs/sd-screenshots.md).
