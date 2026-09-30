#!/usr/bin/env python3
"""Verify Windows payload architecture without running or trusting the payload."""
import argparse
import pathlib
import struct

MACHINES = {"x64": 0x8664, "arm64": 0xAA64}


def runtime_imports(path):
    with pathlib.Path(path).open("rb") as stream:
        def read(offset, size):
            if offset < 0 or size < 0 or size > 65_536:
                raise ValueError(f"{path}: invalid PE import range")
            stream.seek(offset)
            data = stream.read(size)
            if len(data) != size:
                raise ValueError(f"{path}: truncated PE import data")
            return data

        dos = read(0, 64)
        if dos[:2] != b"MZ":
            raise ValueError(f"{path}: invalid DOS header")
        offset = struct.unpack_from("<I", dos, 60)[0]
        pe = read(offset, 24)
        if pe[:4] != b"PE\0\0":
            raise ValueError(f"{path}: invalid PE header")
        count = struct.unpack_from("<H", pe, 6)[0]
        size = struct.unpack_from("<H", pe, 20)[0]
        optional = read(offset + 24, size)
        if not 1 <= count <= 96 or size < 128 or struct.unpack_from("<H", optional)[0] != 0x20B:
            raise ValueError(f"{path}: unsupported PE64 optional header")
        directories = struct.unpack_from("<I", optional, 108)[0]
        sections = read(offset + 24 + size, count * 40)

        def file_offset(rva, length):
            for index in range(count):
                section = index * 40
                address, raw_size, raw_offset = struct.unpack_from("<III", sections, section + 12)
                delta = rva - address
                if 0 <= delta and delta + length <= raw_size:
                    return raw_offset + delta
            raise ValueError(f"{path}: PE import lies outside a file-backed section")

        names = set()
        for directory, width, name_offset in [(1, 20, 12), (13, 32, 4)]:
            if directories <= directory:
                continue
            entry = 112 + directory * 8
            if entry + 8 > len(optional):
                raise ValueError(f"{path}: truncated PE data directories")
            rva, length = struct.unpack_from("<II", optional, entry)
            if rva == 0:
                continue
            if length < width or length > 65_536:
                raise ValueError(f"{path}: invalid PE import directory")
            for index in range(min(length // width, 256)):
                descriptor = read(file_offset(rva + index * width, width), width)
                if not any(descriptor):
                    break
                if directory == 13 and struct.unpack_from("<I", descriptor)[0] != 1:
                    raise ValueError(f"{path}: unsupported delayed-import address format")
                name_rva = struct.unpack_from("<I", descriptor, name_offset)[0]
                value = bytearray()
                for character in range(256):
                    byte = read(file_offset(name_rva + character, 1), 1)
                    if byte == b"\0":
                        break
                    value.extend(byte)
                else:
                    raise ValueError(f"{path}: unbounded DLL name")
                try:
                    name = value.decode("ascii").lower()
                except UnicodeError as error:
                    raise ValueError(f"{path}: invalid DLL name") from error
                if not name or "/" in name or "\\" in name:
                    raise ValueError(f"{path}: unsafe DLL import")
                names.add(name)
            else:
                raise ValueError(f"{path}: unterminated or oversized import table")
        return names


def verify_static_runtime(path):
    dynamic = sorted(name for name in runtime_imports(path)
                     if name.startswith(("vcruntime", "msvcp", "concrt")))
    if dynamic:
        raise ValueError(f"{path}: external Visual C++ runtime required: {', '.join(dynamic)}")


def verify(path, architecture):
    with pathlib.Path(path).open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError(f"{path}: not a Windows executable")
        offset = struct.unpack_from("<I", header, 60)[0]
        if offset < 64 or offset > 1_048_576:
            raise ValueError(f"{path}: invalid PE header offset")
        stream.seek(offset)
        pe = stream.read(24)
    if len(pe) != 24 or pe[:4] != b"PE\0\0":
        raise ValueError(f"{path}: invalid PE signature")
    if struct.unpack_from("<H", pe, 4)[0] != MACHINES[architecture]:
        raise ValueError(f"{path}: payload is not native {architecture}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", required=True, choices=sorted(MACHINES))
    parser.add_argument("--static-runtime", action="store_true")
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    for path in args.paths:
        verify(path, args.architecture)
        if args.static_runtime:
            verify_static_runtime(path)
    print(f"Verified {len(args.paths)} native {args.architecture} PE payloads.")


if __name__ == "__main__":
    main()
