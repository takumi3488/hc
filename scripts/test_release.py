from __future__ import annotations

import hashlib
import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import release


@unittest.skipUnless(os.name == "posix", "the fake compiler fixture uses a POSIX script")
class ZigCacheTests(unittest.TestCase):
    def test_preseeded_default_cache_compiler_is_replaced_before_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            host = "x86_64-linux"
            version = "0.17.0"
            archive_name = f"zig-{host}-{version}.tar.xz"
            compiler_relative = Path(f"zig-{host}-{version}") / "zig"
            fake_marker = root / "fake-ran"
            verified_marker = root / "verified-ran"
            fake_compiler = (
                "#!/bin/sh\n"
                "printf 'fake\\n' > \"$HC_FAKE_MARKER\"\n"
                "printf '0.17.0\\n'\n"
            ).encode()
            verified_compiler = (
                "#!/bin/sh\n"
                "printf 'verified\\n' > \"$HC_VERIFIED_MARKER\"\n"
                "printf '0.17.0\\n'\n"
            ).encode()
            archive_buffer = io.BytesIO()
            with tarfile.open(fileobj=archive_buffer, mode="w:xz") as archive:
                entry = tarfile.TarInfo(compiler_relative.as_posix())
                entry.mode = 0o755
                entry.size = len(verified_compiler)
                archive.addfile(entry, io.BytesIO(verified_compiler))
            archive_bytes = archive_buffer.getvalue()
            expected_sha256 = hashlib.sha256(archive_bytes).hexdigest()

            cache = root / f"hc-zig-{host}-{version}"
            cache.mkdir(mode=0o700)
            cached_compiler = cache / compiler_relative
            cached_compiler.parent.mkdir(mode=0o700)
            (cache / "zig.sha256").write_text(expected_sha256 + "\n", encoding="ascii")
            cached_compiler.write_bytes(fake_compiler)
            cached_compiler.chmod(0o755)

            with (
                patch.dict(
                    os.environ,
                    {
                        "ZIG": "",
                        "HC_FAKE_MARKER": str(fake_marker),
                        "HC_VERIFIED_MARKER": str(verified_marker),
                    },
                ),
                patch.object(release, "host_archive", return_value=host),
                patch.object(release, "ZIG_DOWNLOADS", {host: (f"https://example.invalid/{archive_name}", expected_sha256)}),
                patch.object(release.tempfile, "gettempdir", return_value=temporary),
                patch.object(release.shutil, "which", return_value=None),
                patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(archive_bytes)) as urlopen,
            ):
                compiler, version = release.resolve_zig()

            self.assertEqual(version, "0.17.0")
            self.assertEqual(Path(compiler), cached_compiler)
            self.assertTrue(verified_marker.is_file())
            self.assertFalse(fake_marker.exists())
            urlopen.assert_called_once()


if __name__ == "__main__":
    unittest.main()
