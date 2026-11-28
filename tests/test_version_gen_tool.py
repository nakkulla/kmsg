import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
# SwiftPM names the built executable differently across toolchains.
VERSION_GEN_BINARY_NAMES = ("VersionGenTool", "VersionGenTool-tool")


def find_version_gen_binary() -> Path | None:
    bin_dir = subprocess.run(
        ["swift", "build", "--show-bin-path"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    for name in VERSION_GEN_BINARY_NAMES:
        candidate = Path(bin_dir) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def resolve_version_gen_binary() -> Path:
    binary = find_version_gen_binary()
    if binary is None:
        build = subprocess.run(
            ["swift", "build", "--product", "VersionGenTool"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            raise RuntimeError(f"swift build --product VersionGenTool failed:\n{build.stdout}\n{build.stderr}")
        binary = find_version_gen_binary()
    if binary is None:
        raise RuntimeError(f"VersionGenTool binary not found after build: {VERSION_GEN_BINARY_NAMES}")
    return binary


class VersionGenToolTests(unittest.TestCase):
    binary: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = resolve_version_gen_binary()

    def run_version_gen(self, version: str) -> tuple[subprocess.CompletedProcess[str], str | None]:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            version_path = tmp / "VERSION"
            output_path = tmp / "GeneratedVersion.swift"
            version_path.write_text(f"{version}\n", encoding="utf-8")

            result = subprocess.run(
                [
                    str(self.binary),
                    str(version_path),
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            output_text = output_path.read_text(encoding="utf-8") if output_path.exists() else None
            return result, output_text

    def test_accepts_major_date_patch_version(self) -> None:
        result, output_text = self.run_version_gen("1.260424.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(output_text)
        self.assertIn('static let current = "1.260424.0"', output_text)

    def test_rejects_legacy_calendar_version(self) -> None:
        result, _ = self.run_version_gen("2026.0422.22")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "VERSION must match MAJOR.YYMMDD.PATCH_COUNT",
            f"{result.stdout}\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
