"""Independent integer Mandelbrot/color reference and RTL test-vector generator."""
from pathlib import Path
import random
import struct

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output_files" / "sim"


def signed32(n):
    return ((n + (1 << 31)) % (1 << 32)) - (1 << 31)


def escape(re, im, limit=8191):
    zr, zi = re, im
    seen = set()
    for iteration in range(limit):
        rr, ii, ri = zr * zr >> 24, zi * zi >> 24, zr * zi >> 24
        if rr + ii > 4 << 24:
            return iteration, rr + ii
        if (zr, zi) in seen:
            return None, 0
        seen.add((zr, zi))
        zr, zi = signed32(rr - ii + re), signed32(2 * ri + im)
    return None, 0


def palette_color(index, palette, phase):
    if index >= 254:
        return (0, 0, 0)
    p = (index + phase) & 255
    sat = lambda n: max(0, min(255, n))
    tri = lambda n: 255 - 2 * ((n & 255) - 128) if (n & 255) >= 128 else 2 * (n & 255)
    if palette == 0:
        if p < 64:
            return 0, p, sat(64 + 3 * p)
        if p < 128:
            return 0, sat(64 + 3 * (p - 64)), 255
        if p < 192:
            s = p - 128
            return sat(4 * s), sat(255 - s - (s >> 1)), sat(255 - 4 * s)
        s = p - 192
        return 255, sat(160 + s + (s >> 1)), sat(4 * s)
    if palette == 1:
        return sat(2 * p), sat(p) if p < 128 else sat(2 * (p - 128)), 0 if p < 192 else sat(4 * (p - 192))
    if palette == 2:
        return tri(p + 85), tri(p), tri(p - 85)
    return tri(p + 64), tri(p) >> 2, sat(96 + (tri(p - 32) >> 1))


def quality_samples(re, im, step, palette, phase, limit):
    colors = []
    indices, iterations = [], []
    quarter = step >> 1
    for sy in range(2):
        for sx in range(2):
            iteration, magnitude = escape(re + (quarter if sx else -quarter),
                                          im + (-quarter if sy else quarter), limit)
            if iteration is None:
                index = 254
            else:
                index = iteration & 255
                if index >= 254:
                    index -= 254
                fraction = min(15, (magnitude - (4 << 24)) >> 23)
                if fraction >= 8 and index < 253:
                    index += 1
            colors.append(palette_color(index, palette, phase))
            indices.append(index)
            iterations.append(iteration)
    return colors, indices, iterations


def quality_pixel(x, y, re, im, step, palette, phase, limit=8191, adaptive=False):
    colors, indices, iterations = quality_samples(re, im, step, palette, phase, limit)
    quick_agree = (all(iterations[k] is not None and iterations[k] < 32 for k in (0, 3))
                   and indices[0] == indices[3])
    if adaptive and (step >> 1 == 0 or quick_agree):
        colors = [colors[0], colors[3]] * 2
    result = 0
    for channel in range(3):
        quantized = (sum(c[channel] for c in colors) + 34) // 68
        result = (result << 4) | quantized
    return (x << 25) | (y << 16) | result


def generate():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    cases = []
    for palette in range(4):
        for i, (re, im) in enumerate(((0, 0), (-16777216, 0), (4194304, 0),
                                     (-12582912, 1677720), (-12398378, 220117),
                                     (33554432, 16777216))):
            cases.append((101 + i, 77 + i, re, im, 1048576 if i == 2 else 16384, palette, 173 if i & 1 else 0))
    # Cover every low-coordinate location and partially black boundary pixels.
    for i in range(16):
        cases.append((320 + (i & 3), 240 + (i >> 2), 4194304, 0, 1048576, i & 3, 0))
    rng = random.Random(8191)
    late = None
    for _ in range(1500):
        re = round((-0.743643887 + rng.uniform(-0.00001, 0.00001)) * (1 << 24))
        im = round((0.131825904 + rng.uniform(-0.00001, 0.00001)) * (1 << 24))
        iteration, _ = escape(re, im)
        if iteration is not None and iteration > 1023:
            late = (re, im, iteration)
            cases.append((321, 241, re, im, 0, 2, 37))
            break
    if late is None:
        raise AssertionError("No late-escaping regression point found")
    # One Q8.24 unit outside the cardioid cusp escapes at iteration 15233.
    # It is black at 8191 and colored at 32767: a visible depth regression.
    cases += [(321, 241, 4194305, 0, 0, 2, 37, False),
              (321, 241, 4194305, 0, 0, 2, 37, True),
              (211, 83, 33554432, 16777216, 16384, 1, 173, True),
              (212, 84, 0, 0, 16384, 3, 0, True)]
    rows, adaptive_rows = [], []
    for case in cases:
        x, y, re, im, step, palette, phase = case[:7]
        deep = bool(case[7]) if len(case)>7 else False
        word = (x << 73) | (y << 64) | ((re & 0xffffffff) << 32) | (im & 0xffffffff)
        expected = quality_pixel(x, y, re, im, step, palette, phase, 32767 if deep else 8191)
        vector = (((((word << 32) | step) << 2 | palette) << 8 | phase) << 35) | expected
        vector |= int(deep) << 160
        rows.append(f"{vector:041x}")
        limit = 32767 if deep else 8191
        _, indices, iterations = quality_samples(re, im, step, palette, phase, limit)
        two = step >> 1 == 0 or (indices[0] == indices[3] and
              all(iterations[k] is not None and iterations[k] < 32 for k in (0, 3)))
        adaptive_expected = quality_pixel(x, y, re, im, step, palette, phase, limit, adaptive=True)
        adaptive_vector = (vector & ~((1 << 35) - 1)) | adaptive_expected | (int(two) << 161)
        adaptive_rows.append(f"{adaptive_vector:041x}")
    (OUTPUT / "overrender_cases.hex").write_text("\n".join(rows) + "\n")
    (OUTPUT / "adaptive_cases.hex").write_text("\n".join(adaptive_rows) + "\n")
    # Small, fast off-screen capture through the actual seven workers. Its
    # expected orbit colors and BMP bytes come from this independent model.
    width, height, zoom = 16, 8, 46976205
    pixels = []
    for y in range(height):
        for x in range(width):
            re = (5 << 24) - zoom * (width // 2) // height + x * zoom // height
            im = zoom // 2 - y * zoom // height
            pixels.append(quality_pixel(x, y, re, im, (zoom // height) >> 1, 0, 0, 32767, adaptive=True) & 0xfff)
    (OUTPUT / "screenshot_pixels.hex").write_text("\n".join(f"{p:03x}" for p in pixels) + "\n")
    palettes = [int(p, 16) for p in (ROOT / "tests" / "effect_palettes.hex").read_text().split()]
    bmp = bytearray(54)
    struct.pack_into("<2sIHHI", bmp, 0, b"BM", 54 + width * height * 3, 0, 0, 54)
    struct.pack_into("<IiiHHII", bmp, 14, 40, width, -height, 1, 24, 0, width * height * 3)
    for p in pixels:
        lum = ((p >> 8) & 15) + 2 * ((p >> 4) & 15) + (p & 15)
        blue = palettes[16 + lum // 4]
        next_blue = palettes[16 + (lum // 4 + 1) % 16]
        weight = (lum % 4) * 64
        channels = [((((blue >> shift) & 15) * (256 - weight) +
                     ((next_blue >> shift) & 15) * weight) * 17 + 128) // 256
                    for shift in (0, 4, 8)] if p else [0, 0, 0]
        minimum = min(channels)
        bmp.extend(min(255, c + (c - minimum) // 2) for c in channels)
    (OUTPUT / "screenshot_bmp.hex").write_text("\n".join(f"{b:02x}" for b in bmp) + "\n")
    print(f"Generated {len(rows)} independent quality-render vectors; late escape {late[2]}, deep cusp escape 15233")


def find_deep():
    for delta in range(1, 17):
        iteration, _ = escape((1 << 22) + delta, 0, 32767)
        if iteration is not None and iteration > 8191:
            print(f"Deep regression point: ({(1 << 22) + delta}, 0), escape iteration {iteration}", flush=True)
            return
    rng = random.Random(32767)
    checked = set()
    for _ in range(8000):
        re = round((-0.743643887 + rng.uniform(-0.00002, 0.00002)) * (1 << 24))
        im = round((0.131825904 + rng.uniform(-0.00002, 0.00002)) * (1 << 24))
        if (re, im) in checked:
            continue
        checked.add((re, im))
        iteration, _ = escape(re, im, 32767)
        if iteration is not None and iteration > 8191:
            print(f"Deep regression point: ({re}, {im}), escape iteration {iteration}", flush=True)
            return
    raise SystemExit("No deep regression point found in this search region")


if __name__ == "__main__":
    import sys
    find_deep() if "--find-deep" in sys.argv else generate()
