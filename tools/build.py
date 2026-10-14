"""Compile Mandel.qpf and report resource use and timing."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output_files"
BUILD_STATE = ".build_state.json"
TIMING_KINDS = ("Setup", "Hold", "Recovery", "Removal", "Minimum Pulse Width")
ARTIFACT_NAMES = ("Mandel.sof", "Mandel.fit.summary", "Mandel.sta.summary")
TIMING_REPORTS = (
    "setup_paths", "coordinate_paths", "worker_paths", "commit_paths",
    "preview_paths", "transfer_paths", "video_paths", "control_paths",
    "sdram_input_paths", "sdram_output_paths", "unconstrained_paths",
    "cold_setup_paths", "cold_system_paths",
)


def quartus_tool(name, bin_dir=None):
    if bin_dir is not None:
        executable = shutil.which(name, path=str(bin_dir.expanduser().resolve()))
        if executable:
            return executable
        raise SystemExit(f"{name} not found in {bin_dir}")
    executable = shutil.which(name)
    if executable:
        return executable
    candidates = sorted(Path("C:/intelFPGA_lite").glob(f"*/quartus/bin64/{name}.exe"))
    if candidates:
        return str(candidates[-1])
    raise SystemExit(f"Add {name} to PATH or install Quartus Prime Lite")


def digest(path):
    data = path.read_bytes()
    if path.suffix != ".sof":
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def project_sources():
    sources = {"Mandel.qpf", "Mandel.qsf"}
    qsf = (ROOT / "Mandel.qsf").read_text()
    for match in re.finditer(
            r'^set_global_assignment -name (?:VERILOG_FILE|VERILOG_INCLUDE_FILE|SDC_FILE|MIF_FILE) '
            r'("[^"]+"|\S+)\s*$', qsf, re.M):
        sources.add(match.group(1).strip('"'))
    for name in sources:
        path = (ROOT / name).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise ValueError(f"Missing or external project source: {name}")
    return sorted(sources)


def timing_checks(summary):
    checks = re.findall(r"Type\s*:\s*(.*?)\nSlack\s*:\s*([-\d.]+)", summary)
    if not checks:
        raise ValueError("No timing checks found")
    corners = {name.split(" Model ", 1)[0] for name, _ in checks}
    expected = {f"{speed} 1100mV {temp}C" for speed in ("Slow", "Fast") for temp in (0, 85)}
    if not expected.issubset(corners):
        raise ValueError("Missing device timing corners")
    for corner in expected:
        for kind in TIMING_KINDS:
            if not any(name.startswith(f"{corner} Model {kind} ") for name, _ in checks):
                raise ValueError(f"Missing {kind} checks for {corner}")
    violations = [(name, float(slack)) for name, slack in checks if float(slack) < 0]
    if violations:
        raise ValueError("Timing requirements failed: " + "; ".join(
            f"{slack:.3f} ns ({name})" for name, slack in violations))
    return {kind: min(float(slack) for name, slack in checks if f" {kind} " in name)
            for kind in TIMING_KINDS}


def check_build():
    manifest = json.loads((OUTPUT / "build_manifest.json").read_text())
    if set(manifest["sources"]) != set(project_sources()):
        raise ValueError("Project source list changed; rebuild before programming")
    for name, sha in manifest["sources"].items():
        if digest(ROOT / name) != sha:
            raise ValueError(f"Source changed since compilation: {name}; rebuild before programming")
    if set(manifest["artifacts"]) != set(ARTIFACT_NAMES):
        raise ValueError("Build manifest is missing required artifacts")
    for name, sha in manifest["artifacts"].items():
        if digest(OUTPUT / name) != sha:
            raise ValueError(f"Build artifact changed: {name}")
    timing_checks((OUTPUT / "Mandel.sta.summary").read_text())
    print("PASS: programming file matches current sources and passes all four timing corners")
    print(f"Programming file: {OUTPUT / 'Mandel.sof'}")
    return manifest


def compile_project(bin_dir, log_path):
    executable = quartus_tool("quartus_sh", bin_dir)
    # A fresh working copy avoids stale incremental databases.
    work_root = OUTPUT / ".work"
    work_root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="mandel-", dir=work_root)).resolve()
    source_names = project_sources()
    for name in source_names:
        target = work / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    attempt = OUTPUT / "builds" / stamp
    attempt.mkdir(parents=True)
    shutil.copytree(work, attempt / "sources")
    print(f"Local project: {work}\nReports and sources: {attempt}", flush=True)
    with log_path.open("w") as log_file:
        result = subprocess.run([executable, "--flow", "compile", "Mandel"],
                                cwd=work, stdout=log_file, stderr=subprocess.STDOUT)
    shutil.copy2(log_path, attempt / "build.log")
    if (work / "output_files").is_dir():
        shutil.copytree(work / "output_files", attempt, dirs_exist_ok=True)
    for line in log_path.read_text(errors="replace").splitlines():
        if any(key in line for key in ("Error (", "Critical Warning", "Worst-case", "Full Compilation", "Elapsed time")):
            print(line)
    try:
        if result.returncode:
            raise ValueError(f"Quartus compilation failed with exit code {result.returncode}")
        worst = timing_checks((attempt / "Mandel.sta.summary").read_text())
        fit = (attempt / "Mandel.fit.summary").read_text()
        if not re.search(r"Fitter Status\s*:\s*Successful", fit):
            raise ValueError("Missing successful device fit")
        if not (attempt / "Mandel.sof").is_file():
            raise ValueError("Quartus did not produce a programming file")
        source_hashes = {name: digest(work / name) for name in source_names}
        if project_sources() != source_names or any(digest(ROOT / name) != sha for name, sha in source_hashes.items()):
            raise ValueError("Sources changed during compilation; rebuild the current source")
    except (ValueError, OSError) as error:
        rejected = attempt / "Mandel.sof"
        if rejected.is_file():
            rejected.replace(attempt / "Mandel.REJECTED.sof")
        print(f"BUILD FAILED: {error}\nPrevious successful programming file preserved. Reports: {attempt}")
        return 1

    # Preserve the previous release before publishing the new matching image.
    previous = attempt / "previous"
    previous.mkdir()
    for artifact in attempt.glob("Mandel.*"):
        old = OUTPUT / artifact.name
        if old.is_file():
            shutil.copy2(old, previous / old.name)
        shutil.copy2(artifact, old)
    old_manifest = OUTPUT / "build_manifest.json"
    if old_manifest.is_file():
        shutil.copy2(old_manifest, previous / old_manifest.name)
    manifest = {
        "built_utc": stamp,
        "sources": source_hashes,
        "artifacts": {name: digest(OUTPUT / name) for name in ARTIFACT_NAMES},
        "worst_slack_ns": worst,
    }
    (OUTPUT / "build_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(OUTPUT / "build_manifest.json", attempt / "build_manifest.json")
    state = {"local_project": str(work), "archive": str(attempt)}
    (OUTPUT / BUILD_STATE).write_text(json.dumps(state, indent=2) + "\n")
    print((OUTPUT / "Mandel.fit.summary").read_text(errors="replace"))
    for kind, slack in worst.items():
        print(f"Worst {kind.lower()} slack: {slack:.3f} ns")
    check_build()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--status", action="store_true", help="Show the latest build log lines")
    action.add_argument("--timing", action="store_true", help="Report paths from the fitted design")
    action.add_argument("--check", action="store_true", help="Check the programming file matches current sources and timing")
    parser.add_argument("--quartus-bin", type=Path, help="Directory containing Quartus tools")
    args = parser.parse_args()
    if args.check:
        try:
            check_build()
        except (ValueError, OSError, KeyError) as error:
            print(f"BUILD CHECK FAILED: {error}")
            return 1
        return 0
    log_path = OUTPUT / ("timing.log" if args.timing else "build.log")
    if args.status:
        if log_path.is_file():
            print("\n".join(log_path.read_text(errors="replace").splitlines()[-10:]))
        else:
            print("No build log yet")
        return 0

    OUTPUT.mkdir(exist_ok=True)
    print(f"Building {ROOT / 'Mandel.qpf'}" if not args.timing else "Reading fitted timing", flush=True)
    print(f"Log: {log_path}", flush=True)
    if not args.timing:
        return compile_project(args.quartus_bin, log_path)
    work = ROOT
    manifest_path = OUTPUT / "build_manifest.json"
    if manifest_path.is_file():
        check_build()
        state_path = OUTPUT / BUILD_STATE
        if not state_path.is_file():
            raise SystemExit("Local fitted database is unavailable; rebuild before --timing")
        work = Path(json.loads(state_path.read_text())["local_project"])
        if not (work / "db").is_dir():
            raise SystemExit("Local fitted database is unavailable; rebuild before --timing")
    command = [quartus_tool("quartus_sta", args.quartus_bin), "-t",
               str(ROOT / "tools/timing_report.tcl")]
    with log_path.open("w") as log_file:
        result = subprocess.run(command, cwd=work, stdout=log_file, stderr=subprocess.STDOUT)
    if work != ROOT and (work / "output_files/timing").is_dir():
        shutil.copytree(work / "output_files/timing", OUTPUT / "timing", dirs_exist_ok=True)

    if args.timing:
        for name in TIMING_REPORTS:
            report = OUTPUT / "timing" / f"{name}.txt"
            if report.is_file():
                lines = report.read_text(errors="replace").splitlines()
                print(f"{name}:")
                if name == "unconstrained_paths":
                    print("\n".join(lines[:19]))
                else:
                    for line in lines:
                        if "Worst case slack" in line or re.match(r"; -?\d+\.\d+ ;", line):
                            print(line)
        return result.returncode

    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
