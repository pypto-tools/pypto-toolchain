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
# Emit the MANIFEST that ships inside the bundle. Runs INSIDE the build
# container, after every component is installed, and writes to stdout.
#
# The manifest records what was actually produced, read back out of the built
# binaries rather than echoed from the build ARGs — a component that silently
# installed a different version than requested has to show up here, not be
# papered over by repeating the input. `pypto-toolchain verify` re-derives the
# same values on the target host and diffs them against this file.

set -euo pipefail

: "${PREFIX:?PREFIX must be set}"

# Recorded so a host can tell, without unpacking anything else, whether this
# bundle can run at all. glibc is backward compatible, so a host at or above
# this version can run everything here.
build_glibc() {
    # sed rather than `head -1` / `grep -m1`: those exit after the first line,
    # ldd then takes SIGPIPE, and under `set -o pipefail` the assignment that
    # captures this would abort the whole script with 141. sed without `q`
    # consumes all of the input, so nothing is signalled.
    ldd --version | sed -n '1s/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p'
}

# The floor DERIVED FROM THE ARTIFACTS: the highest GLIBC_x.y any bundled binary
# actually asks the loader for. This is the real requirement, whereas the build
# image's own glibc is merely what we believe we linked against.
#
# It matters because the build container runs on a host whose glibc is usually
# much newer (a GitHub arm64 runner is Ubuntu 24.04 / glibc 2.39 while the
# container is AlmaLinux 8 / glibc 2.28). If anything ever leaked in from the
# host, the symbols would prove it and the guard below fails the build rather
# than shipping a bundle that dies on the fleet's own machines.
referenced_glibc_max() {
    # `|| true`: the prefix legitimately contains non-ELF files (wrapper
    # scripts, libtool .la files) that objdump rejects, which xargs reports as
    # 123, and grep exits 1 when a file happens to reference nothing. The scan
    # is best-effort over a mixed directory, so under `set -e` none of that may
    # be allowed to abort the manifest.
    find "$PREFIX" -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
        | xargs -0 -r objdump -p 2>/dev/null \
        | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
        | sed 's/^GLIBC_//' | sort -V | tail -1 || true
}

# sha256 of the load-bearing binaries. Not every file: the point is to catch a
# truncated or partially-overwritten install, and these five are the ones whose
# corruption would otherwise surface as a baffling mid-build error.
checksums() {
    local f
    for f in "$PREFIX/gcc/bin/g++-15" \
             "$PREFIX/gcc/lib64/libstdc++.so.6" \
             "$PREFIX/python/bin/python3.10" \
             "$PREFIX/bin/ccache" \
             "$PREFIX/bin/uv"; do
        if [ -e "$f" ]; then
            printf 'FILE_SHA256 %s %s\n' "${f#"$PREFIX"/}" "$(sha256sum "$f" | cut -d' ' -f1)"
        else
            echo "gen-manifest: missing expected component: $f" >&2
            exit 1
        fi
    done
}

# Highest GLIBCXX the bundled libstdc++ provides. ptoas needs GLIBCXX_3.4.29 and
# the HCE2 system libstdc++ tops out at 3.4.28, so this value is the whole
# reason the bundle carries a libstdc++ at all — assert it rather than trust it.
glibcxx_max() {
    strings "$PREFIX/gcc/lib64/libstdc++.so.6" \
        | grep -oE '^GLIBCXX_[0-9.]+$' | sort -V | tail -1
}

BUILD_GLIBC="$(build_glibc)"
REF_GLIBC="$(referenced_glibc_max)"

# A binary cannot legitimately reference a glibc newer than the one it linked
# against, so this only trips if something from outside the container found its
# way into the bundle. Fail here: the symptom on a target host would be a bare
# "version `GLIBC_2.39' not found" hours later, with nothing pointing back here.
if [ -n "$REF_GLIBC" ] && \
   [ "$(printf '%s\n%s\n' "$BUILD_GLIBC" "$REF_GLIBC" | sort -V | tail -1)" != "$BUILD_GLIBC" ]; then
    echo "gen-manifest: a bundled binary requires GLIBC_$REF_GLIBC, but this" >&2
    echo "  container's glibc is only $BUILD_GLIBC — something leaked in from" >&2
    echo "  the build host. Refusing to produce a manifest." >&2
    exit 1
fi

cat <<EOF
# pypto-toolchain bundle manifest. Generated at build time; do not edit.
BUNDLE_ARCH $(uname -m)
BUNDLE_PREFIX $PREFIX
GLIBC_FLOOR ${REF_GLIBC:-$BUILD_GLIBC}
GLIBC_BUILD $BUILD_GLIBC
GCC_VERSION $("$PREFIX/gcc/bin/g++-15" -dumpversion)
GCC_TARGET $("$PREFIX/gcc/bin/g++-15" -dumpmachine)
GLIBCXX_MAX $(glibcxx_max)
PYTHON_VERSION $("$PREFIX/python/bin/python3.10" -c 'import platform;print(platform.python_version())')
CCACHE_VERSION $("$PREFIX/bin/ccache" --version | sed -n '1s/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\1/p')
UV_VERSION $("$PREFIX/bin/uv" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
$(checksums)
EOF
