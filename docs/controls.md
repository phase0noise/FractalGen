# Controls

Navigation operates in preview. HD captures the current view and displays
completed pixels as workers finish. Return to preview before changing its
position, zoom, or lens. Palette and effect controls remain available in HD.

## Keyboard

| Key | Action |
| --- | --- |
| W / A / S / D | Pan up / left / down / right |
| Enter / Space | Zoom in / out |
| O | Enter HD rendering or return to preview |
| Esc | Cancel HD or a screenshot; reset the view in preview |
| L | Toggle the lens in preview |
| B / R | Save / restore one bookmark |
| C / V | Next / previous palette, wrapping through all sixteen |
| 1-8 | Select palettes 0-7 |
| F1-F8 | Select palettes 8-15 |
| [ / ] | Shift palette colors backward / forward |
| - / + | Slower / faster animation; keypad - / + also work |
| F12 | Save preview or a completed HD image to SD |
| F11 | Render and save a separate 3840x2160 image to SD |

A bookmark stores position, zoom, lens, palette, color offset, and animation
speed. Restoring it returns to preview. Effect switches keep their physical
positions. Bookmarks are lost on reset.

O, B, R, L, C, V, F11, and F12 act once per press. Navigation and color shifts
accept keyboard repeat. Animation speed clamps at Still, Slow, Fast, or Wild;
Still holds the current phase. Q also resets the view or leaves HD as a
legacy shortcut.

F12 waits for an unfinished HD render before saving. F11 keeps the monitor's
current resolution while rendering off-screen. Saving captures the selected
palette and effects at a held animation phase; Fuzz generates new export
noise. See [SD screenshots](sd-screenshots.md) for cancellation details.

## Board buttons and switches

| Button | Action |
| --- | --- |
| KEY0 / KEY1 | Zoom in / out in preview; hold to repeat |
| KEY2 | Pan upward in preview, once per press |
| KEY3 | Enter HD rendering or return to preview |

| Switch | Action |
| --- | --- |
| SW0 | Set the HD request when the switch changes position |
| SW1 | Burn: animate palette phase |
| SW2 | Stochastic Burn: advance scattered subsets of pixels while Burn is enabled |
| SW3 | Prism: enhance colored edges |
| SW4 | Morph: blend between palettes |
| SW5 | Glow: add luminous trails |
| SW6 | Fuzz: scattered pixel noise |
| SW7 | Persistent random edits to stored HD pixels |
| SW8 | Smooth + Vivid: interpolate palettes and retain RGB888 in screenshots |
| SW9 | Reset while raised |

O and KEY3 toggle the HD request independently of SW0. A later SW0 edge sets
the request to that switch's position. Effects combine. SW7 changes SDRAM
contents; turning it off stops new edits, and a new render replaces the image.

SW8 retains eight-bit channels through color effects. VGA rounds them to the
board's RGB444 DAC; BMPs preserve the extra precision. Morph, Prism, and Glow
also enable vividness. Equal input colors receive equal rounding throughout
the image.

## Palettes

| Key | Palette | Key | Palette |
| --- | --- | --- | --- |
| 1 | Ocean | F1 | Neon Tide |
| 2 | Blue | F2 | Ember Ice |
| 3 | Vivid Spectrum | F3 | Acid |
| 4 | Aurora | F4 | Violet Fire |
| 5 | Inferno | F5 | Peacock |
| 6 | Candy | F6 | Ruby Mint |
| 7 | Emerald | F7 | Copper Blue |
| 8 | Solar Gold | F8 | Prism Bands |

## Status LEDs

| LEDs | Meaning |
| --- | --- |
| 0-3 | Palette index, 0-15 in binary |
| 4-5 | Animation speed, 0-3 in binary |
| 6 | Latched SD error; otherwise worker availability, or scanline underflow after HD completes |
| 7 | HD requested or screenshot busy |
| 8 | Blinks during work; stays lit when HD completes |
| 9 | A bookmark is stored |

An SD error stays latched until the next save request or reset.
