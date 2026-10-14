"""Run RTL simulations with Icarus Verilog."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ROOT / "output_files" / "sim"

TESTS = [
    ("RenderQueue_tb", ["tests/RenderQueue_tb.v", "rtl/RenderQueue.v"], []),
    ("AdaptiveWorker_tb", ["tests/AdaptiveWorker_tb.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/ColorMapper.v"], []),
    ("SdCard_tb", ["tests/SdCard_tb.v", "tests/SpiCardModel.v", "rtl/SdCard.v", "rtl/sd_spi.v"], []),
    ("SdCard_tb", ["tests/SdCard_tb.v", "tests/SpiCardModel.v", "rtl/SdCard.v", "rtl/sd_spi.v"], ["-PSdCard_tb.SDSC=1"]),
    ("FatScreenshot_tb", ["tests/FatScreenshot_tb.v", "tests/SpiCardModel.v", "rtl/FatScreenshot.v", "rtl/SdCard.v", "rtl/sd_spi.v"], []),
    ("BmpStream_tb", ["tests/BmpStream_tb.v", "rtl/BmpStream.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], []),
    ("BmpStream_tb", ["tests/BmpStream_tb.v", "rtl/BmpStream.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpStream_tb.SMOOTH_VIVID=1"]),
    ("BmpHeader_tb", ["tests/BmpHeader_tb.v", "rtl/BmpStream.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], []),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], []),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.TAIL_REPLAY=1"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.TAIL_REPLAY=1", "-PBmpSdram_tb.MODE=2"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.DATA_DELAY=2.5", "-PBmpSdram_tb.CLOCK_DELAY=0", "-PBmpSdram_tb.MODE=2"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.CLOCK_DELAY=0", "-PBmpSdram_tb.CAPTURE_DELAY=3.0", "-PBmpSdram_tb.RELEASE_DELAY=1.5"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.CLOCK_DELAY=0", "-PBmpSdram_tb.CAPTURE_DELAY=3.0", "-PBmpSdram_tb.RELEASE_DELAY=1.5", "-PBmpSdram_tb.MODE=2"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.CLOCK_DELAY=0", "-PBmpSdram_tb.CAPTURE_DELAY=3.0", "-PBmpSdram_tb.REPEAT_READ_DELAY=2.7", "-PBmpSdram_tb.RELEASE_DELAY=1.5"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.CLOCK_DELAY=0", "-PBmpSdram_tb.CAPTURE_DELAY=3.0", "-PBmpSdram_tb.REPEAT_READ_DELAY=2.7", "-PBmpSdram_tb.RELEASE_DELAY=1.5", "-PBmpSdram_tb.MODE=2"]),
    ("BmpSdram_tb", ["tests/BmpSdram_tb.v", "rtl/BmpStream.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "tests/VideoSdramModel.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/ColorMapper.v"], ["-PBmpSdram_tb.CLOCK_DELAY=0", "-PBmpSdram_tb.CAPTURE_DELAY=3.0", "-PBmpSdram_tb.REPEAT_READ_DELAY=2.7", "-PBmpSdram_tb.RELEASE_DELAY=1.5", "-PBmpSdram_tb.MODE=2", "-PBmpSdram_tb.BASE_WORD=4194301"]),
    ("UhdRenderer_tb", ["tests/UhdRenderer_tb.v", "rtl/UhdRenderer.v", "rtl/UnsignedDivide.v"], []),
    ("UhdBoundary_tb", ["tests/UhdBoundary_tb.v", "rtl/UhdRenderer.v", "rtl/UnsignedDivide.v"], []),
    ("ScreenshotControl_tb", ["tests/ScreenshotControl_tb.v", "rtl/ScreenshotControl.v"], []),
    ("MandelScreenshot_tb", ["tests/MandelScreenshot_tb.v", "tests/SpiCardModel.v", "rtl/Mandel.v", "rtl/Coor_gen.v", "rtl/ViewControl.v", "rtl/keyboard.v",
                             "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/ResultArbiter.v", "rtl/ColorMapper.v", "rtl/VGA.v",
                             "rtl/LineBuffer.v", "rtl/HDVideo.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/VideoTimingDelay.v", "rtl/LiveStore.v", "rtl/ScreenshotControl.v",
                             "rtl/UhdRenderer.v", "rtl/UnsignedDivide.v", "rtl/BmpStream.v", "rtl/FatScreenshot.v", "rtl/SdCard.v", "rtl/sd_spi.v"], []),
    ("HDSyncGuard_tb", ["tests/HDSyncGuard_tb.v", "rtl/HDVideo.v"], []),
    ("Engine_compare_tb", ["tests/reference/Engine.v", "rtl/Engine_fast.v", "tests/Engine_compare_tb.v"], []),
    ("Engine_interleaved_tb", ["rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "tests/Engine_interleaved_tb.v"], []),
    ("RenderWorker_tb", ["tests/RenderWorker_tb.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/ColorMapper.v"], []),
    ("SmoothColor_tb", ["tests/SmoothColor_tb.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v"], []),
    ("RefineEngine_tb", ["tests/RefineEngine_tb.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v"], []),
    ("Progressive_tb", ["tests/Progressive_tb.v", "rtl/Coor_gen.v", "rtl/LiveStore.v"], []),
    ("ProgressiveScreenshot_tb", ["tests/Progressive_tb.v", "rtl/Coor_gen.v", "rtl/LiveStore.v"], []),
    ("QueuedProgressive_tb", ["tests/Progressive_tb.v", "rtl/Coor_gen.v", "rtl/LiveStore.v", "rtl/RenderQueue.v"], []),
    ("LiveStoreAddress_tb", ["tests/LiveStoreAddress_tb.v", "rtl/LiveStore.v"], []),
    ("Corruption_tb", ["tests/Corruption_tb.v", "rtl/LiveStore.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], []),
    ("Corruption_tb", ["tests/Corruption_tb.v", "rtl/LiveStore.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], ["-PCorruption_tb.REAL_SDRAM=1"]),
    ("LiveCorruption_tb", ["tests/Corruption_tb.v", "rtl/LiveStore.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], []),
    ("ViewControl_tb", ["tests/ViewControl_tb.v", "rtl/ViewControl.v"], []),
    ("Keyboard_tb", ["tests/Keyboard_tb.v", "rtl/keyboard.v", "rtl/ViewControl.v"], []),
    ("Coor_gen_tb", ["tests/Coor_gen_tb.v", "rtl/Coor_gen.v"], []),
    ("CoorLens_tb", ["tests/CoorLens_tb.v", "rtl/Coor_gen.v"], []),
    ("Seam_tb", ["tests/Seam_tb.v", "rtl/Coor_gen.v"], []),
    ("Seam_tb", ["tests/Seam_tb.v", "rtl/Coor_gen.v"], ["-PSeam_tb.PROGRESSIVE=1", "-PSeam_tb.COLUMNS=4", "-PSeam_tb.TILE_WIDTH=320", "-PSeam_tb.TILE_HEIGHT=512", "-PSeam_tb.IMAGE_HEIGHT=1024", "-PSeam_tb.INITIAL_LEVEL=2"]),
    ("Seam_tb", ["tests/Seam_tb.v", "rtl/Coor_gen.v"], ["-PSeam_tb.PROGRESSIVE=1", "-PSeam_tb.COLUMNS=4", "-PSeam_tb.TILE_WIDTH=320", "-PSeam_tb.TILE_HEIGHT=512", "-PSeam_tb.IMAGE_HEIGHT=1024", "-PSeam_tb.INITIAL_LEVEL=2", "-PSeam_tb.LENS=1"]),
    ("HDColorEffects_tb", ["tests/HDColorEffects_tb.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v"], []),
    ("HDGradient_tb", ["tests/HDGradient_tb.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v"], []),
    ("HDGradient_tb", ["tests/HDGradient_tb.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v"], ["-PHDGradient_tb.PIXEL_CYCLES=3"]),
    ("StochasticBurn_tb", ["tests/StochasticBurn_tb.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v"], []),
    ("MorphEffects_tb", ["tests/MorphEffects_tb.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v"], []),
    ("MorphEffects_tb", ["tests/MorphEffects_tb.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v"], ["-PMorphEffects_tb.PIXEL_CYCLES=3"]),
    ("Preview_tb", ["tests/Preview_tb.v", "rtl/VGA.v", "rtl/ColorMapper.v"], []),
    ("PreviewBorrow_tb", ["tests/Preview_tb.v", "rtl/VGA.v", "rtl/ColorMapper.v"], []),
    ("TileStore_tb", ["tests/TileStore_tb.v", "tests/reference/TileStore.v"], []),
    ("Commit_tb", ["tests/Commit_tb.v", "rtl/Mandel.v", "rtl/Coor_gen.v", "rtl/ViewControl.v", "rtl/keyboard.v",
                   "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v",
                   "rtl/ResultArbiter.v", "rtl/ColorMapper.v", "rtl/VGA.v", "rtl/LineBuffer.v", "rtl/HDVideo.v", "rtl/HDColorEffects.v", "rtl/EffectPalettes.v", "rtl/VideoTimingDelay.v",
                   "tests/reference/TileStore.v", "rtl/LiveStore.v", "rtl/io_sdram.v", "rtl/synch_3.v", "rtl/ScreenshotControl.v",
                   "rtl/UhdRenderer.v", "rtl/UnsignedDivide.v", "rtl/BmpStream.v", "rtl/FatScreenshot.v", "rtl/SdCard.v", "rtl/sd_spi.v"], []),
    ("HDVideo_tb", ["tests/HDVideo_tb.v", "rtl/HDVideo.v", "tests/reference/TileStore.v", "rtl/LiveStore.v", "rtl/LineBuffer.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], []),
    ("HDVideo_tb", ["tests/HDVideo_tb.v", "rtl/HDVideo.v", "tests/reference/TileStore.v", "rtl/LiveStore.v", "rtl/LineBuffer.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], ["-PHDVideo_tb.REAL_SDRAM=1"]),
    ("HDVideo_tb", ["tests/HDVideo_tb.v", "rtl/HDVideo.v", "tests/reference/TileStore.v", "rtl/LiveStore.v", "rtl/LineBuffer.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], ["-PHDVideo_tb.REAL_SDRAM=1", "-PHDVideo_tb.LIVE_STORE=1", "-PHDVideo_tb.PROGRESSIVE_MASK=1"]),
    ("HDVideoCorruption_tb", ["tests/HDVideo_tb.v", "rtl/HDVideo.v", "tests/reference/TileStore.v", "rtl/LiveStore.v", "rtl/LineBuffer.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], []),
    ("HDVideoScreenshot_tb", ["tests/HDVideo_tb.v", "rtl/HDVideo.v", "tests/reference/TileStore.v", "rtl/LiveStore.v", "rtl/LineBuffer.v", "tests/VideoSdramModel.v", "rtl/io_sdram.v", "rtl/synch_3.v"], []),
    ("tb_sdram_boot", ["tests/SdramReference_tb.sv", "rtl/io_sdram.v", "rtl/synch_3.v"], ["-Ptb_sdram_boot.DATA_DELAY=2.5"]),
    ("tb_sdram_boot", ["tests/SdramReference_tb.sv", "rtl/io_sdram.v", "rtl/synch_3.v"], ["-Ptb_sdram_boot.DATA_DELAY=5.4"]),
]
TESTS.append(("EngineCycle_tb", ["tests/EngineCycle_tb.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v"], []))
TESTS.append(("FractalFrame_tb", ["tests/FractalFrame_tb.v", "rtl/UhdRenderer.v", "rtl/UnsignedDivide.v", "rtl/ResultArbiter.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/ColorMapper.v"], []))
TESTS.append(("RenderPerformance_tb", ["tests/RenderPerformance_tb.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/ColorMapper.v"], []))
TESTS.append(("RenderPerformance_tb", ["tests/RenderPerformance_tb.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/ColorMapper.v"], ["-PRenderPerformance_tb.CYCLE_BITS=6"]))
TESTS.append(("RenderPerformance_tb", ["tests/RenderPerformance_tb.v", "rtl/RenderWorker.v", "rtl/SupersampleColor.v", "rtl/Engine_fast.v", "rtl/Engine_interleaved.v", "rtl/ColorMapper.v"], ["-PRenderPerformance_tb.CYCLE_BITS=5"]))
for options in ([], ["-PKeyboardRecovery_tb.FILTER_CYCLES=1"],
                ["-PKeyboardRecovery_tb.TIMEOUT_CYCLES=1048593"],
                ["-PKeyboardRecovery_tb.FILTER_CYCLES=9"]):
    TESTS.append(("KeyboardRecovery_tb", ["tests/KeyboardRecovery_tb.v", "rtl/keyboard.v",
                                         "rtl/ViewControl.v", "rtl/ScreenshotControl.v"], options))
# Both complete top-level benches and focused UHD benches use the same queue.
for _, sources, _ in TESTS:
    if "rtl/UhdRenderer.v" in sources:
        sources.append("rtl/RenderQueue.v")
    elif "tests/Progressive_tb.v" in sources and "rtl/RenderQueue.v" not in sources:
        sources.append("rtl/RenderQueue.v")


def find_tools(executable=None):
    if executable is not None:
        icarus = executable.expanduser().resolve()
        if not icarus.is_file():
            raise SystemExit(f"Icarus executable not found: {icarus}")
    else:
        found = shutil.which("iverilog")
        candidates = (
            Path(found) if found else None,
            Path("C:/iverilog/bin/iverilog.exe"),
            Path("C:/Program Files/iverilog/bin/iverilog.exe"),
        )
        icarus = next((path for path in candidates if path and path.is_file()), None)
        if icarus is None:
            raise SystemExit("Add iverilog to PATH or pass --iverilog /path/to/iverilog")

    sibling = icarus.with_name("vvp.exe" if sys.platform == "win32" else "vvp")
    vvp = str(sibling) if sibling.is_file() else shutil.which("vvp")
    if not vvp:
        raise SystemExit("Install vvp alongside iverilog or add it to PATH")
    return str(icarus), vvp


def run_test(index, test, icarus, vvp):
    top, sources, options = test
    output = SCRATCH / f"{index}_{top}.vvp"
    command = [icarus, "-g2012", "-I", str(ROOT / "rtl"), "-s", top, *options,
               "-o", str(output), *(str(ROOT / source) for source in sources)]
    # Icarus invokes cmd.exe internally on Windows, which rejects UNC working
    # directories. Sources/includes are absolute; only vvp needs ROOT for fixtures.
    compile_dir = Path(icarus).parent if sys.platform == "win32" and str(ROOT).startswith("\\\\") else ROOT
    compiled = subprocess.run(command, cwd=compile_dir, text=True, capture_output=True)
    if compiled.returncode:
        return top, options, compiled
    result = subprocess.run([vvp, str(output)], cwd=ROOT, text=True, capture_output=True)
    result.stderr = compiled.stderr + result.stderr
    return top, options, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", action="append",
                        choices=sorted({top for top, _, _ in TESTS}),
                        help="Run every variant of a bench (repeat to select several)")
    parser.add_argument("--jobs", type=int, default=1,
                        help="Concurrent simulation jobs (default: 1)")
    parser.add_argument("--iverilog", type=Path, help="Path to the Icarus compiler")
    parser.add_argument("--list", action="store_true", help="List benches without running them")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    selected = [(index, test) for index, test in enumerate(TESTS)
                if not args.only or test[0] in args.only]
    if args.list:
        for top in sorted({test[0] for _, test in selected}):
            count = sum(test[0] == top for _, test in selected)
            print(f"{top}: {count} case(s)")
        print(f"{len(selected)} cases total")
        return 0

    icarus, vvp = find_tools(args.iverilog)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / "tests"))
    from reference_render import generate

    SCRATCH.mkdir(parents=True, exist_ok=True)
    generate()
    if any(test[0] in ("EngineCycle_tb", "RenderPerformance_tb", "FractalFrame_tb") for _, test in selected):
        from engine_performance import generate as generate_performance_vectors
        generate_performance_vectors()
    print(f"Running {len(selected)} RTL regressions with {args.jobs} simulation job(s)", flush=True)
    failed = False
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = [executor.submit(run_test, index, test, icarus, vvp)
                   for index, test in selected]
        for future in as_completed(futures):
            top, options, result = future.result()
            print(result.stdout, end="", flush=True)
            if result.returncode or "FAIL" in result.stdout or "PASS" not in result.stdout:
                print(f"FAIL: {top} {' '.join(options)}\n{result.stderr}", flush=True)
                failed = True
            elif result.stderr:
                print(result.stderr, end="", flush=True)
    if failed:
        return 1
    print(f"PASS: all {len(selected)} selected RTL regressions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
