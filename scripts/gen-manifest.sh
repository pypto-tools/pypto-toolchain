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
# bundle can run at all. The floor comes from the build image's glibc: nothing
# here references a newer symbol, and glibc is backward compatible.
glibc_floor() {
    ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$'
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

cat <<EOF
# pypto-toolchain bundle manifest. Generated at build time; do not edit.
BUNDLE_ARCH $(uname -m)
BUNDLE_PREFIX $PREFIX
GLIBC_FLOOR $(glibc_floor)
GCC_VERSION $("$PREFIX/gcc/bin/g++-15" -dumpversion)
GCC_TARGET $("$PREFIX/gcc/bin/g++-15" -dumpmachine)
GLIBCXX_MAX $(glibcxx_max)
PYTHON_VERSION $("$PREFIX/python/bin/python3.10" -c 'import platform;print(platform.python_version())')
CCACHE_VERSION $("$PREFIX/bin/ccache" --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
UV_VERSION $("$PREFIX/bin/uv" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
$(checksums)
EOF
