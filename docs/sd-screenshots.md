# SD screenshots

F12 saves the current 640x480 preview or a complete 1280x1024 HD image.
If HD is still rendering, it finishes first. F11 renders a separate 3840x2160
image while the monitor keeps its current resolution. Both use the selected
palette and effects. Esc cancels; held function keys start one job.

## Files and cards

Use a FAT16 or FAT32 card in the DE0-CV microSD slot. The writer accepts a
filesystem at sector zero or in the first MBR partition. It creates
`FRAC0000.BMP`, `FRAC0001.BMP`, etc. in the root directory, choosing a number
above existing FRAC files. Existing files are preserved. FAT12, exFAT, and GPT
are unsupported.

The files are top-down, uncompressed 24-bit BMPs with a 54-byte header.
With SW8 on, screenshots retain full RGB888 interpolation from Smooth + Vivid.
With SW8 off, RGB444 channels expand to eight bits by multiplication by 17.

| Image | File size |
| --- | --- |
| 640x480 preview | 921,654 bytes |
| 1280x1024 HD | 3,932,214 bytes |
| 3840x2160 screenshot | 24,883,254 bytes |

Allocation requires a contiguous free cluster run large enough for the image.
A fragmented card can report no space even with sufficient free bytes.
A full FAT16 root directory also reports an error.

LED7 stays on during a job and LED8 blinks. LED6 retains an error until another
save request or reset. Card initialization runs again for every job.

## Rendering and transfers

The screenshot snapshots the full four-bit palette selector, effects,
color offset, view, lens, and animation phases. The BMP path replays those
settings at a held phase; Fuzz produces new noise during export.

The 4K renderer reuses the seven orbit workers, with adaptive two/four-sample
antialiasing and up to 32,767 iterations per sample. Four groups can be in
flight while an independent uploader writes completed groups in order.
Its Q8.24 raster uses quotient/remainder
steps to preserve floor(x*zoom/2160). Lens radius and its scale product use
separate clock cycles while preserving the exact coordinates and sample
spacing. The 16:9 output covers more horizontal space than HD at the same
vertical zoom.

The HD buffer starts at byte zero and uses 1,966,080 bytes. The 4K buffer starts
at byte 4,194,304 and uses 12,441,600 bytes, ending below 16 MiB within the
board's 64 MiB SDRAM. BMP bytes stream to SD without a second expanded buffer.

Worker results drain before transfers begin. Rendering and SDRAM corruption
pause during saving, then resume. Preview exports borrow the RAM port during
blanking; HD/4K exports cache sixteen eight-pixel groups per native read.
One extra word is requested and discarded, so useful packed pixels never
occupy the burst tail. A final-high-halfword replay therefore changes only
the discarded word. Partial chunks end at the image row boundary.
Scanline fetches retain priority.
SDRAM short bursts hold their final high halfword with overlapping high-first
drain reads, including at row crossings, so the final two pixels of each packed
group retain their original colors. Preview exports register the RAM byte
before palette conversion.

## Filesystem writes

Card checks and cluster allocation finish before a long 4K render starts.
Image sectors are written before FAT links and the directory entry. Mirrored
FAT copies and FAT32 reserved entry bits are preserved; valid FSInfo free
counts are invalidated for the host to recount.

Cancellation finishes the current data sector and leaves its clusters free.
Once metadata commit starts, it completes. Sector and metadata errors are
reported. A failed save can be retried after inserting a supported card.

The metadata cache uses MLAB memory. The renderer reuses the existing DSP
workers. Regression cases cover FAT16/FAT32 allocation and naming, SD pins,
all sixteen BMP palettes, stalled transfers, packed SDRAM boundaries, minimum
hold windows and fast repeated-column reads, position-independent color
rounding, and an actual keyboard-to-card capture with independent expected
image bytes.
