#!/usr/bin/env python3

import os
import platform
import subprocess
import sys
import unittest
from pathlib import Path

from rules_python.python.runfiles import runfiles


class PipRepositoryAnnotationsTest(unittest.TestCase):
    maxDiff = None

    def wheel_pkg_dir(self) -> str:
        env = os.environ.get("WHEEL_PKG_DIR")
        self.assertIsNotNone(env)
        return env

    def test_build_content_and_data(self):
        r = runfiles.Create()
        rpath = r.Rlocation(
            "pip_repository_annotations_example/external/{}/generated_file.txt".format(
                self.wheel_pkg_dir()
            )
        )
        generated_file = Path(rpath)
        self.assertTrue(generated_file.exists())

        content = generated_file.read_text().rstrip()
        self.assertEqual(content, "Hello world from build content file")

    def test_copy_files(self):
        r = runfiles.Create()
        rpath = r.Rlocation(
            "pip_repository_annotations_example/external/{}/copied_content/file.txt".format(
                self.wheel_pkg_dir()
            )
        )
        copied_file = Path(rpath)
        self.assertTrue(copied_file.exists())

        content = copied_file.read_text().rstrip()
        self.assertEqual(content, "Hello world from copied file")

    def test_copy_executables(self):
        r = runfiles.Create()
        rpath = r.Rlocation(
            "pip_repository_annotations_example/external/{}/copied_content/executable{}".format(
                self.wheel_pkg_dir(),
                ".exe" if platform.system() == "windows" else ".py",
            )
        )
        executable = Path(rpath)
        self.assertTrue(executable.exists())

        proc = subprocess.run(
            [sys.executable, str(executable)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout = proc.stdout.decode("utf-8").strip()
        self.assertEqual(stdout, "Hello world from copied executable")

    def test_data_exclude_glob(self):
        current_wheel_version = "0.37.1"

        r = runfiles.Create()
        dist_info_dir = (
            "pip_repository_annotations_example/external/{}/wheel-{}.dist-info".format(
                self.wheel_pkg_dir(),
                current_wheel_version,
            )
        )

        # `WHEEL` is expected to be there to show dist-info files are included in the runfiles
        wheel_path = r.Rlocation("{}/WHEEL".format(dist_info_dir))

        # However, `RECORD` was explicitly excluded, so it should be missing
        record_path = r.Rlocation("{}/RECORD".format(dist_info_dir))

        # Because windows does not have `--enable_runfiles` on by default, the
        # `runfiles.Rlocation` results will be different on this platform vs
        # unix platforms. See `@rules_python//python/runfiles` for more details.
        if platform.system() == "Windows":
            self.assertIsNotNone(wheel_path)
            self.assertIsNone(record_path)
        else:
            self.assertTrue(Path(wheel_path).exists())
            self.assertFalse(Path(record_path).exists())


if __name__ == "__main__":
    unittest.main()
