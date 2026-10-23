#!/usr/bin/env python3
"""Verify every embedded Mach-O deployment target and our archived dSYM UUIDs."""
import argparse
import os
import plistlib
import struct
from pathlib import Path


def versions(text):
    fields = tuple(int(part) for part in text.split("."))
    return (fields + (0, 0, 0))[:3]


def slices(data):
    """Return (CPU type, macOS minimum version, UUID) for thin/fat Mach-O."""
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
        endian = ">" if magic[:1] == b"\xca" else "<"
        count = struct.unpack_from(endian + "I", data, 4)[0]
        wide = magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
        size = 32 if wide else 20
        result = []
        for index in range(count):
            base = 8 + index * size
            offset, length = struct.unpack_from(endian + ("QQ" if wide else "II"), data, base + 8)
            result.extend(slices(data[offset:offset + length]))
        return result
    formats = {
        b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32),
        b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28),
    }
    if magic not in formats:
        return []
    endian, position = formats[magic]
    cpu = struct.unpack_from(endian + "I", data, 4)[0]
    commands = struct.unpack_from(endian + "I", data, 16)[0]
    minimum, uuid = None, None
    for _ in range(commands):
        command, size = struct.unpack_from(endian + "II", data, position)
        if size < 8 or position + size > len(data):
            raise ValueError("invalid Mach-O load command")
        if command == 0x24 or (command == 0x32 and struct.unpack_from(endian + "I", data, position + 8)[0] == 1):
            raw = struct.unpack_from(endian + "I", data, position + (8 if command == 0x24 else 12))[0]
            minimum = (raw >> 16, (raw >> 8) & 255, raw & 255)
        if command == 0x1B:
            uuid = data[position + 8:position + 24].hex()
        position += size
    return [(cpu, minimum, uuid)]


def verify(app, symbols, reference_executable=None):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    supported = versions(info["LSMinimumSystemVersion"])
    errors, binaries = [], []
    for root, _, names in os.walk(app):
        for name in names:
            path = Path(root) / name
            if path.is_symlink():
                continue
            entries = slices(path.read_bytes())
            if not entries:
                continue
            binaries.append(path)
            if not any(cpu == 0x0100000C for cpu, _, _ in entries):
                errors.append(f"{path.relative_to(app)}: no arm64 slice")
            for _, minimum, _ in entries:
                if minimum is None or minimum > supported:
                    errors.append(f"{path.relative_to(app)}: minimum {minimum} exceeds app {supported}")
    if not binaries:
        errors.append("no Mach-O binaries found")
    if reference_executable:
        packaged = app / "Contents/MacOS" / info["CFBundleExecutable"]
        current = {(cpu, uuid) for cpu, _, uuid in slices(reference_executable.read_bytes())}
        embedded = {(cpu, uuid) for cpu, _, uuid in slices(packaged.read_bytes())}
        if not current or any(uuid is None for _, uuid in current) or current != embedded:
            errors.append("packaged executable differs from current SwiftPM build UUID")
    if symbols:
        for relative, name in [
            ("Contents/MacOS/" + info["CFBundleExecutable"], "MNotch.app.dSYM"),
            ("Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter", "MediaRemoteAdapter.framework.dSYM"),
        ]:
            binary = app / relative
            dwarf = symbols / name / "Contents/Resources/DWARF" / binary.name
            if not dwarf.is_file():
                errors.append(f"missing symbols: {name}")
                continue
            binary_uuids = {(cpu, uuid) for cpu, _, uuid in slices(binary.read_bytes())}
            symbol_uuids = {(cpu, uuid) for cpu, _, uuid in slices(dwarf.read_bytes())}
            if any(uuid is None for _, uuid in binary_uuids) or binary_uuids != symbol_uuids:
                errors.append(f"{name}: UUID does not match binary")
            if not has_debug_info(dwarf.read_bytes()):
                errors.append(f"{name}: missing DWARF debug information")
    if errors:
        raise ValueError("\n".join(errors))
    print(f"Verified {len(binaries)} Mach-O binaries: deployment targets <= {supported}, matching symbols={bool(symbols)}")


def has_debug_info(data):
    # Our dSYMs are thin arm64 Mach-O. A UUID-only dSYM can still match the
    # binary while containing no useful symbols (missing compiler objects).
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return False
    commands = struct.unpack_from("<I", data, 16)[0]
    position = 32
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > len(data):
            return False
        if command == 0x19:
            count = struct.unpack_from("<I", data, position + 64)[0]
            for index in range(count):
                section = position + 72 + index * 80
                if section + 80 > position + size:
                    return False
                name = data[section:section + 16].rstrip(b"\0")
                length = struct.unpack_from("<Q", data, section + 40)[0]
                if name == b"__debug_info" and length > 0:
                    return True
        position += size
    return False


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("symbols", nargs="?", type=Path)
    parser.add_argument("--reference-executable", type=Path)
    args = parser.parse_args()
    try:
        verify(args.app, args.symbols, args.reference_executable)
    except (ValueError, KeyError, OSError, struct.error) as error:
        parser.exit(1, f"Bundle verification failed: {error}\n")
