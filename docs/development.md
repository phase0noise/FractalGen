# Development

Run commands from the project root. The helpers use Python 3.10 or newer and
the standard library. Examples use `py` on Windows; use `python3` on Linux.

## Quartus

Install Quartus Prime Lite 23.1 with Cyclone V device support.

```powershell
py tools/build.py
py tools/build.py --check
py tools/build.py --status
py tools/build.py --timing
```

Tools are found on PATH or under `C:/intelFPGA_lite`. To select an installation:

```powershell
py tools/build.py --quartus-bin C:/intelFPGA_lite/23.1std/quartus/bin64
```

Each compile uses a fresh project under `output_files/.work/`. Reports and
source snapshots go to `output_files/builds/`. These working files are ignored
by Git. A failed compile or timing check preserves the previous programming image.

Only these release files are tracked:

| File | Contents |
| --- | --- |
| `output_files/Mandel.sof` | Cyclone V programming image |
| `output_files/Mandel.fit.summary` | Device fit and resource use |
| `output_files/Mandel.sta.summary` | Timing checks for all four device corners |
| `output_files/build_manifest.json` | Source/artifact SHA-256 hashes and worst timing slack |

`--check` rejects changed sources, mismatched artifacts, missing timing checks,
and negative slack. Text hashes use LF line endings so a Windows checkout
does not invalidate them. The `.sof` is hashed as binary.

`--timing` requires the fitted database from a local compile. Its location is
kept in the ignored `output_files/.build_state.json`. Rebuild if the working
files were removed or the project was freshly cloned. Detailed reports are
written to `output_files/timing/`.

The design uses most of the device's logic and all M10K/DSP blocks. Check the
fit and every timing corner after changing HDL or constraints. A successful
compile and simulation still need a board check for VGA, PS/2, SDRAM, and SD.

## Simulation

Install Icarus Verilog with `iverilog` and `vvp` on PATH.

```powershell
py tools/verify.py --list
py tools/verify.py --jobs 3
py tools/verify.py --only Keyboard_tb --only HDColorEffects_tb
py tools/verify.py --iverilog C:/iverilog/bin/iverilog.exe --jobs 3
py -B -m unittest discover -s tests -p test_build.py -v
```

A bench can have several parameter variants; `--only` runs all variants of
the selected bench. The runner generates independent reference fixtures and
writes simulator output to `output_files/sim/`.

The tests cover keyboard recovery, fixed-point orbits, adaptive sampling,
ordered result queues, video timing, SDRAM transfers, color effects, and
SD/FAT/BMP output. `tests/reference/` holds the original engine and alternate
tile store used by the comparison and video benches.

Build-helper tests check image preservation on failure, incomplete timing
reports, source changes, artifact hashes, and checkout line endings without
requiring Quartus.
