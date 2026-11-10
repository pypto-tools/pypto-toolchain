#!/usr/bin/env python3
# Copyright (c) PyPTO Contributors.
# SPDX-License-Identifier: LicenseRef-CANN-Open-Software-License-Agreement-2.0
"""Remove regenerable data and duplicate storage without dropping components."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import subprocess


def compact(prefix, strip):
    # Preserve sourceless bytecode. Normal imports regenerate caches from .py.
    cache_bytes = 0
    for path in prefix.rglob("*.pyc"):
        if path.is_symlink() or "__pycache__" not in path.parts:
            continue
        try:
            source = Path(importlib.util.source_from_cache(str(path)))
        except ValueError:
            # CPython's own tests include intentionally unusual cache names.
            continue
        if source.is_file():
            cache_bytes += path.stat().st_size
            path.unlink()
    for path in sorted(prefix.rglob("__pycache__"), reverse=True):
        if path.is_dir() and not path.is_symlink() and not any(path.iterdir()):
            path.rmdir()

    # CPython is built with debug information. Keep symbols, headers and the
    # static library for extension builds and embedding; remove only DWARF.
    debug_bytes = 0
    python_lib = prefix / "python/lib"
    libraries = list(python_lib.glob("libpython*.so.*"))
    libraries += list(python_lib.glob("python*/config*/libpython*.a"))
    for path in libraries:
        if path.is_symlink():
            continue
        before = path.stat().st_size
        subprocess.run([strip, "--strip-debug", str(path)], check=True)
        debug_bytes += before - path.stat().st_size

    # tar records hard links once. Contents and permissions stay identical,
    # including package RECORD hashes and the bundle's binary checksums.
    seen = {}
    linked_bytes = 0
    linked_files = 0
    for path in sorted(prefix.rglob("*")):
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size < 1024 * 1024:
            continue
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        key = (metadata.st_size, stat.S_IMODE(metadata.st_mode), digest.digest())
        previous = seen.setdefault(key, path)
        if previous == path or previous.samefile(path):
            continue
        temporary = path.with_name(path.name + ".compact-link")
        os.link(previous, temporary)
        os.replace(temporary, path)
        linked_bytes += metadata.st_size
        linked_files += 1

    mib = 1024 * 1024
    print(f"Removed bytecode caches: {cache_bytes / mib:.1f} MiB")
    print(f"Removed CPython debug information: {debug_bytes / mib:.1f} MiB")
    print(f"Hard-linked {linked_files} duplicates: {linked_bytes / mib:.1f} MiB")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path)
    parser.add_argument("--strip", default="strip")
    args = parser.parse_args()
    if not (args.prefix / "python/lib").is_dir():
        parser.error("prefix must contain python/lib")
    compact(args.prefix, args.strip)
