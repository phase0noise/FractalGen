# Renderer

## Coordinates and workers

Preview uses 640x480 on-chip storage and 511 iterations. HD traverses a single
1280x1024 raster with adaptive two/four-sample antialiasing and up to 32,767 iterations per sample.
Seven workers run at 75 MHz with Q8.24 coordinates. The iteration limit can
reveal late escapes, but it does not increase coordinate precision.

HD pixel spacing is zoom/1024. Projection uses the full raster coordinates;
worker tags carry the low coordinate bits needed for the eight-pixel assembly
slot. Queue metadata supplies the complete SDRAM destination, including X
beyond 1023 and Y beyond 511. Worker results carry their queue slot through
the arbiter and commit pipeline, so wrapped coordinate tags remain unambiguous.

Each worker tests opposite corners first. If both escape within 32 iterations
and their detailed color indices agree, their two colors form the pixel. A
zero fixed-point sampling step also uses two samples, including deep escapes.
Disagreement, interior samples and slow escapes receive the other two corners.
Two-corner agreement is approximate and can miss a feature between them;
the orbit arithmetic and iteration budgets are unchanged.

Four eight-pixel groups can be outstanding. Dispatch, orbit calculation and
upload proceed independently. Completed groups wait in MLAB lane banks until
every earlier group is published; a full queue applies backpressure. Frame
completion waits for workers, commit stages, queue and SDRAM writes to drain.
Pausing preserves partially dispatched groups. Cancellation invalidates their
metadata and a new capture replaces the stored image.

The lens uses the global pixel location and a 5/4 vertical radius correction
in HD. B/R bookmarks retain the view, lens, four-bit palette selector, color
offset, and animation speed. Physical effect switches keep their current state.

## Storage and scanout

Eight RGB444 pixels occupy three 32-bit SDRAM words. Each HD row occupies
480 words; the full image uses 1,966,080 bytes starting at address zero.
Scanlines are fetched in bursts of 128, 128, 128, and 96 words into two buffers.

A Gray-coded progress counter publishes complete groups. Each scanline
request snapshots that progress so pixels that finish later cannot expose
stale cached data. Unpublished pixels display black. Pending display reads
have priority over uploads, screenshot transfers, and random pixel edits.

SW7 edits one lane of a published eight-pixel group, preserving its neighbors.
The timer allows up to 10,000 edits per second before display contention.
Turning SW7 off stops new edits; a new render replaces the stored image.

## Color path

Preview and HD start from the same stored Ocean colors and use the same
thirteen-stage RGB pipeline. A four-bit selector chooses sixteen palettes.
The palette table is implemented in logic; interpolation uses signed difference
products split by weight nibble and combined before rounding. Luminance and
hue preparation use the input pipeline stages;
both stochastic index candidates are registered before the palette lookup.
Blend weights are selected in the preceding registered stage so selection
and products fit their clock periods. The output remains thirteen stages
later. Color controls, effects, and screenshot exports share the selector.

Escape detail rounds to the nearest index without a spatial threshold. Four
RGB888 subpixel colors are averaged directly into RGB444 by rounding their
channel sum divided by 68 (four samples times the DAC's 17-level expansion).
This preserves full brightness and avoids both double rounding and Bayer dots.
Equal orbits and sample sums have equal colors at every screen location.

SW8 enables Smooth + Vivid. The full six-bit luminance covers sixteen palette
anchors continuously, with two fractional tone bits and eight fractional Burn
phase bits. Ocean also gets a continuous palette. RGB888 arithmetic preserves
the interpolated values through vividness, Morph, Prism and Glow. The live DAC
rounds at the output; screenshots retain the eight-bit result. When SW8
is off, the expanded pipeline reproduces the existing RGB444 effects exactly.
Short edge/trail histories remain RGB444 to conserve memory. Equal input colors
use equal rounding at every position.

Burn moves through a palette; Slow blends neighboring entries using a
fractional phase and uniform nearest rounding for the RGB444 DAC. Stochastic
Burn advances scattered subsets and retains each pixel's step until its
next turn. Still holds the phase.

Morph blends toward Spectrum, Candy, or Aurora. Prism boosts edge differences
against short pixel histories; Glow adds an eight-pixel and sixteen-pixel echo.
These effects enable vividness. Histories advance only on actual pixels and
clear during blanking, so adjacent rows do not share trails. Fuzz adds scattered
noise. Palette changes and these effects leave capture geometry and SDRAM intact.
The physical four-bit VGA DAC has sixteen levels per channel, so very slow fractional
animation can hold a color across several frames before a uniform small step.

VGA timing has a separate path. Display selection changes at frame boundaries;
color processing cannot restart the raster or alter sync.

## SDRAM and checks

The controller runs at 75 MHz, BL2, CL3, with byte masks, open rows, and a
512-cycle refresh cadence. The forwarded chip clock is shifted by half a
controller period. Read data is captured on that shifted clock and consumed
on the next controller edge. Short native reads and row crossings drain with
two overlapping READs starting at the final high halfword. Both return that
same final value through its capture window; no extra data beat is published.
The screenshot exporter also reads sixteen groups plus a discarded guard word,
so requested RGB never occupies the final native burst word. A replayed high
halfword in that word is ignored. The regressions reproduce that failure as
well as early repeated reads and row/bank crossings.

`Mandel.sdc` constrains the clocks, SDRAM delays, and synchronized controls.
`py tools/verify.py` runs the RTL regressions, including independent color
oracles, all sixteen palettes, preview/HD agreement, worker results, address
boundaries, full video frames, SDRAM pin behavior, and screenshots.
`py tools/build.py --timing` writes path reports to `output_files/timing/`.

The programming file is always `output_files/Mandel.sof`. Resource use and
timing slack are reported in the adjacent Quartus summaries.
