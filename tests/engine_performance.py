"""Independent exact-orbit oracle and repeatable diagnostic render workloads."""
from pathlib import Path
import json
from math import ceil
from random import Random

from reference_render import signed32, quality_pixel

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output_files/sim"


def orbit(x, y, budget):
    # Start at z=0, retain every exact state to find the earliest recurrence.
    # Unlike the RTL, this oracle has unbounded checkpoint storage.
    zx = zy = 0
    seen = {(0, 0): 0}
    for step in range(1, budget + 1):
        rr, ii, ri = zx*zx >> 24, zy*zy >> 24, zx*zy >> 24
        zx, zy = signed32(rr-ii+x), signed32(2*ri+y)
        magnitude = (zx*zx >> 24)+(zy*zy >> 24)
        if magnitude > 4 << 24:
            return step, magnitude, None, None
        old = seen.get((zx, zy))
        if old is not None:
            return None, 0, old, step-old
        seen[zx, zy] = step
    return None, 0, None, None


def steps(result, budget, bits):
    escaped, _, prefix, period = result
    if escaped is not None:
        return escaped
    if period is None:
        return budget
    if bits == 0:
        if period > 16:
            return budget
        checkpoint = (prefix//16+1)*16-1
        return min(budget, checkpoint+period)
    checkpoint, window = 0, 1
    maximum = 1 << bits
    while checkpoint < prefix or window < period:
        if window == maximum:
            if period > maximum:
                return budget
            checkpoint += max(1, ceil((prefix-checkpoint)/window))*window
            break
        checkpoint += window
        window = min(maximum, 2*window)
    return min(budget, checkpoint+period)


def color(result, detail):
    escaped, magnitude, _, _ = result
    if escaped is None:
        return 254
    index = (escaped-1) & 255
    if index >= 254:
        index -= 254
    if detail and min(15, (magnitude-(4 << 24)) >> 23) >= 8 and index < 253:
        index += 1
    return index


def generate():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    scenes = (("overview", -.75, 0., 2.8),
              ("period_three", -.122561166876, .744861766619, .04),
              ("boundary", -.743643887, .131825904, .00004))
    width, height = 8, 6
    rows, profiles, points, frame_rows, views = [], [], [], [], []
    for scene, (name, cx, cy, span) in enumerate(scenes):
        center_x, center_y, zoom = (round(value*(1 << 24)) for value in (cx, cy, span))
        views.append(f"{center_x & 0xffffffff:08x} {center_y & 0xffffffff:08x} {zoom:08x}\n")
        sample_step = (zoom//height) >> 1
        totals = {bits: 0 for bits in (0, 4, 5, 6, 7, 8, 10, 16)}
        periods = {}
        for y in range(height):
            for x in range(width):
                re = center_x-width//2*zoom//height+x*zoom//height
                im = center_y+height//2*zoom//height-y*zoom//height
                palette, phase = scene & 3, (x*37+y*13) & 255
                wanted = quality_pixel(x,y,re,im,sample_step,palette,phase,32767,adaptive=True)
                word = (x << 73)|(y << 64)|((re & 0xffffffff) << 32)|(im & 0xffffffff)
                rows.append(f"{scene} {word:021x} {sample_step:08x} {palette} {phase:02x} {wanted:09x}\n")
                frame_rows.append(f"{quality_pixel(x,y,re,im,sample_step,0,0,32767,adaptive=True):09x}\n")
                quarter = sample_step >> 1
                for dx, dy in ((-quarter,quarter),(quarter,-quarter),(quarter,quarter),(-quarter,-quarter)):
                    result = orbit(re+dx, im+dy, 32767)
                    for bits in totals:
                        totals[bits] += steps(result,32767,bits)+1
                    if result[3] is not None:
                        periods[result[3]] = periods.get(result[3],0)+1
                points.append((re,im))
        profiles.append(dict(scene=name, all_four_sample_orbit_steps=totals, periods=periods))
    (OUTPUT / "engine_render_vectors.txt").write_text("".join(rows),encoding="ascii")
    (OUTPUT / "frame_expected.hex").write_text("".join(frame_rows),encoding="ascii")
    (OUTPUT / "frame_views.txt").write_text("".join(views),encoding="ascii")
    profiles_path = OUTPUT / "engine_profiles.json"
    profiles_path.write_text(json.dumps(profiles,indent=2))
    # Include named cycles, late escapes and exact cusp/bulb boundaries.
    points += [(0,0),(-1 << 24,0),(-2 << 24,0),(1 << 22,0),((1 << 22)+1,0),
               (-20971520,0),(-20971520-1,0),(0,1 << 24),
               (round(-.122561166876*(1 << 24)),round(.744861766619*(1 << 24))),
               (-12582912,1677720),(-12398378,220117)]
    rng = Random(0xB4E17)
    points += [(rng.randrange(-2 << 24,1 << 24),rng.randrange(-1 << 24,1 << 24)) for _ in range(64)]
    # Cover all budgets and both detail conventions, including late 16-bit wraps.
    engine_rows = []
    for index,(re,im) in enumerate(points):
        level, detail = index % 4, index % 2
        budget = (8191,16383,32767,65535)[level]
        result = orbit(re,im,budget)
        engine_rows.append(f"{re & 0xffffffff:08x} {im & 0xffffffff:08x} {level} {detail} {color(result,detail):02x} {result[3] or 0}\n")
    (OUTPUT / "engine_cycle_vectors.txt").write_text("".join(engine_rows),encoding="ascii")
    print(f"Generated {len(rows)} diagnostic pixels and {len(engine_rows)} independent engine vectors",flush=True)
    for profile in profiles:
        print(json.dumps(profile),flush=True)


if __name__ == "__main__":
    generate()
