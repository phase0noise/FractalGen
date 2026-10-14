"""Exercise build publication and stale-source detection without Quartus."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("mandel_build", Path(__file__).resolve().parents[1] / "tools/build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


def summary(slack="0.125"):
    return "".join(f"Type : {speed} 1100mV {temp}C Model {kind} 'test_clock'\nSlack : {slack}\n"
                   for speed in ("Slow", "Fast") for temp in (0, 85) for kind in build.TIMING_KINDS)


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = (Path(self.temp.name) / "source").resolve()
        self.root.mkdir()
        self.output = self.root / "output_files"
        self.output.mkdir()
        self.work = (Path(self.temp.name) / "local").resolve()
        self.work.mkdir()
        (self.root / "Mandel.qpf").write_text('PROJECT_REVISION = "Mandel"\n')
        (self.root / "Mandel.qsf").write_text('set_global_assignment -name VERILOG_FILE Mandel.v\n')
        (self.root / "Mandel.v").write_text("module Mandel; endmodule\n")
        (self.output / "Mandel.sof").write_bytes(b"previous working image")
        for name, value in (("ROOT", self.root), ("OUTPUT", self.output)):
            mock = patch.object(build, name, value)
            mock.start()
            self.addCleanup(mock.stop)

    def compile(self, *, timing=None, status=0, change_source=False, missing_fit=False):
        def run(command, cwd, stdout, stderr):
            self.assertEqual(cwd, self.work)
            self.assertEqual((cwd / "Mandel.v").read_bytes(), (self.root / "Mandel.v").read_bytes())
            artifacts = cwd / "output_files"
            artifacts.mkdir()
            (artifacts / "Mandel.sof").write_bytes(b"new image")
            if not missing_fit:
                (artifacts / "Mandel.fit.summary").write_text("Fitter Status : Successful\n")
            (artifacts / "Mandel.sta.summary").write_text(summary() if timing is None else timing)
            if change_source:
                (self.root / "Mandel.v").write_text("module Mandel; wire changed; endmodule\n")
            return subprocess.CompletedProcess(command, status)

        with patch.object(build, "quartus_tool", return_value="quartus_sh"), \
                patch.object(build.tempfile, "mkdtemp", return_value=str(self.work)), \
                patch.object(build.subprocess, "run", side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()):
            return build.compile_project(None, self.output / "build.log")

    def assert_preserved(self):
        self.assertEqual((self.output / "Mandel.sof").read_bytes(), b"previous working image")
        self.assertFalse((self.output / "build_manifest.json").exists())
        self.assertEqual(len(list((self.output / "builds").glob("*/Mandel.REJECTED.sof"))), 1)

    def test_quartus_failure_preserves_release(self):
        self.assertEqual(self.compile(status=1), 1)
        self.assert_preserved()

    def test_negative_slack_preserves_release(self):
        self.assertEqual(self.compile(timing=summary("-0.002")), 1)
        self.assert_preserved()

    def test_incomplete_timing_preserves_release(self):
        self.assertEqual(self.compile(timing=summary().replace("Fast 1100mV 0C Model", "Unknown Model")), 1)
        self.assert_preserved()

    def test_missing_fit_preserves_release(self):
        self.assertEqual(self.compile(missing_fit=True), 1)
        self.assert_preserved()

    def test_edit_during_compile_preserves_release(self):
        self.assertEqual(self.compile(change_source=True), 1)
        self.assert_preserved()

    def test_success_records_sources_and_archives_previous_release(self):
        self.assertEqual(self.compile(), 0)
        with contextlib.redirect_stdout(io.StringIO()):
            manifest = build.check_build()
        self.assertEqual((self.output / "Mandel.sof").read_bytes(), b"new image")
        state = json.loads((self.output / build.BUILD_STATE).read_text())
        self.assertEqual((Path(state["archive"]) / "previous/Mandel.sof").read_bytes(), b"previous working image")
        self.assertNotIn("archive", manifest)
        self.assertNotIn("local_project", manifest)
        self.assertEqual(set(manifest["artifacts"]), set(build.ARTIFACT_NAMES))
        (self.root / "Mandel.v").write_text("changed after build")
        with self.assertRaisesRegex(ValueError, "Source changed"):
            build.check_build()

    def test_modified_programming_file_is_rejected(self):
        self.assertEqual(self.compile(), 0)
        (self.output / "Mandel.sof").write_bytes(b"unrelated image")
        with self.assertRaisesRegex(ValueError, "Build artifact changed"):
            build.check_build()

    def test_checkout_line_endings_preserve_build_hashes(self):
        self.assertEqual(self.compile(), 0)
        for path in (self.root / "Mandel.v", self.output / "Mandel.fit.summary",
                     self.output / "Mandel.sta.summary"):
            path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        with contextlib.redirect_stdout(io.StringIO()):
            build.check_build()

    def test_manifest_without_image_hash_is_rejected(self):
        self.assertEqual(self.compile(), 0)
        path = self.output / "build_manifest.json"
        manifest = json.loads(path.read_text())
        del manifest["artifacts"]["Mandel.sof"]
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "missing required artifacts"):
            build.check_build()


if __name__ == "__main__":
    unittest.main()
