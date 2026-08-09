#!/usr/bin/env bash
# Copyright (c) PyPTO Contributors.
# This program is free software, you can redistribute it and/or modify it under the terms and conditions of
# CANN Open Software License Agreement Version 2.0 (the "License").
# Please refer to the License for details. You may not use this file except in compliance with the License.
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR A PARTICULAR PURPOSE.
# See LICENSE in the root of the software repository for the full text of the License.
# -----------------------------------------------------------------------------------------------------------
#
# Copy every shared library the bundle needs from the build image into the
# bundle itself, then prove nothing is left pointing at the build host.
#
# Choosing an old base image bounds the *glibc* symbols the binaries require,
# but says nothing about the other libraries they link. Those are matched by
# SONAME, not by version, so a newer host does not satisfy them — it simply does
# not have them. CPython's _ctypes linked AlmaLinux 8's libffi.so.6 while HCE2
# ships libffi.so.8, and importing ctypes failed outright on a host that is
# otherwise far newer than the build image.
#
# This is what auditwheel does for manylinux wheels, for the same reason.

set -euo pipefail

: "${PREFIX:?PREFIX must be set}"

BUNDLED="$PREFIX/lib/bundled"
mkdir -p "$BUNDLED"

# Libraries every glibc host provides, and which must NOT be shipped: they are
# part of the C runtime and pairing a copied libc with the host's loader is a
# reliable way to produce a bundle that segfaults. libstdc++/libgcc_s are
# excluded for a different reason — the bundle already carries its own under
# gcc/lib64, which activate.sh puts first.
#
# libcrypt and libnsl are NOT on this list, though they look like they belong.
# glibc dropped both after 2.28: EL8 still ships them inside glibc, while EL9
# and anything newer take them from separate libxcrypt and libnsl2 packages that
# a minimal install does not have. Treating them as core produced a bundle whose
# Python would not start on AlmaLinux 9 ("libcrypt.so.1: cannot open shared
# object file") while working on a fleet host that happened to have libxcrypt.
# They are leaf libraries with no tie to the loader, so bundling them is safe in
# the way bundling libc would not be.
is_core_lib() {
    # By basename: ldd names the loader by absolute path
    # ("/lib/ld-linux-aarch64.so.1 (0x...)"), unlike every other entry.
    case "$(basename "$1")" in
        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libutil.so.*|\
        libresolv.so.*|libanl.so.*|\
        ld-linux*.so.*|ld64.so.*|linux-vdso.so.*|\
        libstdc++.so.*|libgcc_s.so.*) return 0 ;;
        *) return 1 ;;
    esac
}

elf_files() {
    find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null
}

# One pass: copy in anything resolved outside $PREFIX that is not a core lib.
# Returns 1 when it copied something, so the caller can iterate — a library just
# copied in may itself pull further dependencies.
copy_pass() {
    local copied=0 f soname path
    while read -r f; do
        # `ldd` on a non-ELF file just fails; skip those quietly.
        ldd "$f" 2>/dev/null | while read -r soname _arrow path _addr; do
            case "$soname" in *.so*) ;; *) continue ;; esac
            is_core_lib "$soname" && continue
            [ -n "$path" ] && [ -e "$path" ] || continue
            case "$path" in "$PREFIX"/*) continue ;; esac
            [ -e "$BUNDLED/$soname" ] && continue
            cp -L "$path" "$BUNDLED/$soname"
            # stderr: this function's stdout carries only the count, which the
            # caller reads back.
            echo "  bundled $soname  <- $path" >&2
        done
    done < <(elf_files)
    # Counted after the fact: the loop above runs in a subshell (it is on the
    # right of a pipe), so a variable incremented inside it would not survive.
    copied="$(find "$BUNDLED" -type f | wc -l)"
    echo "$copied"
}

echo "== collecting host libraries into $BUNDLED"
prev=-1
for _ in 1 2 3 4 5; do
    now="$(copy_pass | tail -1)"
    [ "$now" = "$prev" ] && break
    prev="$now"
done
echo "== $prev libraries bundled"

# Deliberately NOT rewriting RPATHs across the whole prefix. A pass that did
# corrupted libpython3.10.so.1.0 on x86_64 — "ELF load command address/offset
# not properly aligned" — because patchelf has to shift PT_LOAD segments to make
# room, and gets that wrong on some layouts. The self-containment check below did
# not notice: ldd still prints a sensible answer for a library the loader then
# refuses. Rewriting every ELF in the bundle risks more than it buys.
#
# The two places an RPATH genuinely earns its keep are handled where they are
# built instead: Python links with -Wl,-rpath pointing at python/lib and
# lib/bundled, and GCC's driver gets an $ORIGIN-relative RPATH over its own bin
# and libexec only. Everything else resolves through activate.sh, which is how
# consumers enter the bundle anyway.

# The guard. With only the bundle's own directories on the search path, nothing
# may be missing and nothing may resolve back to the build image. If this passes,
# the same binaries resolve identically on any host at or above the glibc floor.
echo "== verifying self-containment"
status=0
while read -r f; do
    out="$(env -i LD_LIBRARY_PATH="$PREFIX/gcc/lib64:$PREFIX/python/lib:$BUNDLED" \
           ldd "$f" 2>/dev/null)" || continue
    while read -r soname _arrow path _addr; do
        case "$soname" in *.so*) ;; *) continue ;; esac
        if [ "$_arrow" = "=>" ] && [ "$path" = "not" ]; then
            echo "::error:: $f needs $soname — not found"
            status=1
            continue
        fi
        is_core_lib "$soname" && continue
        [ -n "$path" ] || continue
        case "$path" in
            "$PREFIX"/*) ;;
            *) echo "::error:: $f resolves $soname to $path, outside the bundle"
               status=1 ;;
        esac
    done <<< "$out"
done < <(elf_files)

if [ "$status" -ne 0 ]; then
    echo "bundle is not self-contained; it would fail on a host without the build image's libraries" >&2
    exit 1
fi
echo "== every dependency resolves inside the bundle or to core glibc"
