import importlib.util
import plistlib
import struct
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("verify_bundle", Path(__file__).parents[2] / "Scripts/verify-bundle.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def binary(major, uuid=b"a" * 16):
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2, 48, 0, 0)
    return header + struct.pack("<IIIIII", 0x32, 24, 1, major << 16, 27 << 16, 0) + struct.pack("<II", 0x1B, 24) + uuid


class BundleChecks(unittest.TestCase):
    def test_parser_reads_real_load_command_layout(self):
        self.assertEqual(verifier.slices(binary(15)), [(0x0100000C, (15, 0, 0), (b"a" * 16).hex())])
        self.assertEqual(verifier.slices(b"not a binary"), [])

    def test_uuid_only_symbols_are_not_debug_information(self):
        self.assertFalse(verifier.has_debug_info(binary(15)))

    def test_cached_executable_with_different_uuid_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "MNotch.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "15.0", "CFBundleExecutable": "MNotch"}))
            (app / "Contents/MacOS/MNotch").write_bytes(binary(15))
            current = Path(root) / "current"
            current.write_bytes(binary(15, b"b" * 16))
            with self.assertRaisesRegex(ValueError, "current SwiftPM build UUID"):
                verifier.verify(app, None, current)

    def test_framework_above_advertised_minimum_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "MNotch.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "15.0", "CFBundleExecutable": "MNotch"}))
            (app / "Contents/MacOS/MNotch").write_bytes(binary(15))
            embedded = app / "Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A"
            embedded.mkdir(parents=True)
            (embedded / "MediaRemoteAdapter").write_bytes(binary(26))
            with self.assertRaisesRegex(ValueError, "exceeds app"):
                verifier.verify(app, None)
            (embedded / "MediaRemoteAdapter").write_bytes(binary(15))
            verifier.verify(app, None)

    def test_mismatched_symbols_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "MNotch.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "15.0", "CFBundleExecutable": "MNotch"}))
            (app / "Contents/MacOS/MNotch").write_bytes(binary(15))
            symbols = Path(root) / "symbols"
            dwarf = symbols / "MNotch.app.dSYM/Contents/Resources/DWARF"
            dwarf.mkdir(parents=True)
            (dwarf / "MNotch").write_bytes(binary(15, b"b" * 16))
            with self.assertRaisesRegex(ValueError, "UUID does not match"):
                verifier.verify(app, symbols)
