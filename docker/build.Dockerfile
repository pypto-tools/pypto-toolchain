# Copyright (c) PyPTO Contributors.
# This program is free software, you can redistribute it and/or modify it under the terms and conditions of
# CANN Open Software License Agreement Version 2.0 (the "License").
# Please refer to the License for details. You may not use this file except in compliance with the License.
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR A PARTICULAR PURPOSE.
# See LICENSE in the root of the software repository for the full text of the License.
# -----------------------------------------------------------------------------------------------------------
#
# The single definition of the PyPTO host toolchain. Everything a PyPTO build
# needs that is NOT pinned per-project lives here: a CPython, a GCC (with the
# libstdc++ ptoas links against), uv and ccache.
#
# Deliberately NOT in the bundle:
#   ptoas      pinned per-project in pypto/toolchain/versions.env and fetched
#              per job; bumped far more often than this bundle.
#   CANN       bound to the machine's driver; detected, never deployed.
#   torch etc. project dependencies; installed into each job's venv by uv.
#
# The container only BUILDS the tree. It is exported as a tarball and unpacked
# on bare metal, because the device/HCCL jobs cannot run inside docker (the chip
# child silently dies in comm_init).
#
# Usage: driven by scripts/build.sh, which passes every ARG below.

# glibc floor. Built here, the binaries reference no symbol newer than the base
# image's glibc, and glibc is backward compatible — so the bundle runs on any
# host at or above that floor.
#
# Do NOT "helpfully" move this to a newer base: the floor is the contract that
# lets a machine added next year work without re-testing. For reference, ptoas
# itself already requires GLIBC_2.34, so 2.28 will never be the binding limit.
#
# AlmaLinux 8 rather than manylinux_2_28: both are glibc 2.28, but manylinux is
# ~600 MB of prebuilt CPythons and auditwheel that this build never touches (it
# compiles its own Python and GCC), and it lives on quay.io, which pulls at
# ~100 KB/s from the network these machines sit on. AlmaLinux 8 is ~75 MB and on
# Docker Hub, which has usable regional mirrors. Its stock GCC 8.5 already
# implements the C++14 that bootstrapping GCC 15 requires.
ARG BASE_IMAGE=almalinux:8
FROM ${BASE_IMAGE}

# The install prefix is BAKED INTO the GCC driver and into Python's sysconfig
# (cc1plus literally contains this string; `g++ -print-search-dirs` resolves
# against it). Unpacking anywhere else produces a subtly broken toolchain, so
# this must equal the deployed path exactly, version component included.
# /opt/pypto may be a symlink to a roomier filesystem on any given host — that
# is fine, the *path string* is what has to match.
ARG PREFIX=/opt/pypto/toolchain/dev

ARG GCC_VERSION=15.2.0
ARG PYTHON_VERSION=3.10.18
ARG UV_VERSION=0.9.28
ARG CCACHE_VERSION=4.10.2

# Source mirrors. Default to upstream; scripts/build.sh overrides them with the
# domestic mirrors when building from inside the corporate network.
ARG GNU_MIRROR=https://ftp.gnu.org/gnu
ARG PYTHON_MIRROR=https://www.python.org/ftp/python

# CPU baseline. The bundle must run on every aarch64/x86_64 host in the fleet,
# including one added later with an older part, so the compiler is configured
# for a conservative architecture and generic tuning. (The gcc-15 tarball this
# replaces was built --with-tune=native, i.e. tuned for whichever machine
# happened to build it.)
ARG GCC_ARCH_CONFIG=--with-arch=armv8-a --with-tune=generic

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# gmp/mpfr/mpc are NOT taken from the distro: on RHEL 8 derivatives libmpc-devel
# lives in the PowerTools/CRB repo, whose name and default-enabled state differ
# between AlmaLinux, Rocky and RHEL. GCC ships contrib/download_prerequisites
# for exactly this, so the build stays self-contained and base-image-agnostic.
RUN dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False \
        gcc gcc-c++ make cmake git \
        zlib-devel bzip2-devel xz-devel libffi-devel openssl-devel libzstd-devel \
        sqlite-devel readline-devel ncurses-devel libuuid-devel gdbm-devel \
        bison flex patch diffutils file findutils which \
        tar xz bzip2 curl ca-certificates \
    && dnf clean all

# bzip2 is the *binary*, not the development package: three of the five GCC
# prerequisites ship as .tar.bz2, and bzip2-devel (also in this list, for
# Python) provides headers and a library, not the bzip2 command.
#
# wget is deliberately ABSENT. contrib/download_prerequisites prefers it over
# curl when present, and wget rejects a socks5:// proxy outright ("Unsupported
# scheme"), which breaks the --proxy path this build depends on from behind a
# restricted network. Without wget the script falls back to curl, which handles
# socks5 fine — it only logs a cosmetic "type: wget: not found" first.

# No texinfo on purpose. It only provides makeinfo, which GCC uses to render its
# manuals; configure detects its absence and skips documentation, leaving the
# compiler itself unaffected. On RHEL 8 rebuilds texinfo sits in PowerTools/CRB,
# a repo whose name and default-enabled state vary between AlmaLinux, Rocky and
# RHEL — enabling it would reintroduce exactly the base-image coupling that
# download_prerequisites was chosen to avoid.

WORKDIR /build

# --- GCC ------------------------------------------------------------------
# install-strip, not install: an unstripped GCC 15 install is ~1.8 GB, of which
# ~1.6 GB is debug info for cc1plus/lto1 that nobody here will ever use.
#
# Every curl here is plain `--retry`, without --retry-all-errors: the base
# image ships curl 7.61 (EL8) and that option only arrived in 7.71, where it
# fails the whole command as an unknown option rather than being ignored.
# --retry alone already covers the transient timeouts and 5xx that matter.
RUN curl -fsSL --retry 5 \
      "${GNU_MIRROR}/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" | tar xJ \
    && (cd gcc-${GCC_VERSION} && ./contrib/download_prerequisites) \
    && mkdir gcc-build && cd gcc-build \
    && ../gcc-${GCC_VERSION}/configure \
        --prefix="${PREFIX}/gcc" \
        --program-suffix=-15 \
        --enable-languages=c,c++ \
        --disable-multilib \
        --disable-nls \
        --with-system-zlib \
        --enable-shared \
        --enable-threads=posix \
        ${GCC_ARCH_CONFIG} \
    && make -j"$(nproc)" \
    && make install-strip \
    && cd /build && rm -rf gcc-${GCC_VERSION} gcc-build

# GCC's driver and cc1plus are themselves C++ programs, linked against the
# libstdc++ the bootstrap just built. activate.sh already puts gcc/lib64 on
# LD_LIBRARY_PATH, so this is belt-and-braces: an $ORIGIN-relative RPATH lets
# them resolve it even when invoked from an environment nobody activated.
# Best-effort — patchelf ships with the manylinux images but is not worth
# failing a two-hour build over, and the LD_LIBRARY_PATH path still works.
#
# $ORIGIN is single-quoted so the shell passes it through literally; it is
# resolved by the dynamic loader at run time, not here.
RUN if command -v patchelf >/dev/null 2>&1; then \
        find "${PREFIX}/gcc/bin" "${PREFIX}/gcc/libexec" -type f -executable -print0 \
          | xargs -0 -r -n1 sh -c 'patchelf --set-rpath '"'"'$ORIGIN/../lib64:$ORIGIN/../../../../lib64'"'"' "$0" 2>/dev/null || true'; \
        echo "RPATH set on gcc binaries"; \
    else \
        echo "patchelf unavailable; relying on activate.sh LD_LIBRARY_PATH"; \
    fi

# --- Python ---------------------------------------------------------------
# --enable-shared plus an RPATH to its own lib: extension builds (nanobind via
# scikit-build-core) read these paths out of sysconfig, so they must point
# inside the bundle rather than at whatever the host has.
RUN curl -fsSL --retry 5 \
      "${PYTHON_MIRROR}/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" | tar xJ \
    && cd Python-${PYTHON_VERSION} \
    && ./configure \
        --prefix="${PREFIX}/python" \
        --enable-shared \
        --enable-optimizations \
        --with-lto \
        --with-ensurepip=install \
        LDFLAGS="-Wl,-rpath,${PREFIX}/python/lib" \
    && make -j"$(nproc)" \
    && make install \
    && cd /build && rm -rf Python-${PYTHON_VERSION} \
    && "${PREFIX}/python/bin/python3.10" -m pip install --no-cache-dir --upgrade pip

# --- ccache ---------------------------------------------------------------
# >= 4.8 is a correctness requirement, not a preference: CCACHE_NAMESPACE is how
# PyPTO CI scopes the compile cache to the pinned pto-isa commit (pypto #1139),
# and older ccache ignores the variable *silently*, serving objects built
# against the previous ISA headers. One fleet machine currently runs 3.7.12.
#
# zstd comes from libzstd-devel rather than ccache's own download, and the redis
# backend is off so hiredis is never needed: ccache 4.8 replaced the old
# -DZSTD_FROM_INTERNET / -DHIREDIS_FROM_INTERNET switches, and CMake only warns
# about unknown -D options — the build would have silently fallen through to
# whatever the default resolution does.
RUN curl -fsSL --retry 5 \
      "https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/ccache-${CCACHE_VERSION}.tar.xz" | tar xJ \
    && cmake -S ccache-${CCACHE_VERSION} -B ccache-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DREDIS_STORAGE_BACKEND=OFF \
        -DENABLE_TESTING=OFF \
    && cmake --build ccache-build -j"$(nproc)" \
    && cmake --install ccache-build --strip \
    && cd /build && rm -rf ccache-${CCACHE_VERSION} ccache-build

# --- uv -------------------------------------------------------------------
# Replaces conda's --system-site-packages layering: uv installs from a shared
# cache by hardlink, so a per-job venv gets torch in seconds and costs no extra
# disk, with none of the global mutable state that layering required.
RUN arch="$(uname -m)" \
    && curl -fsSL --retry 5 \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${arch}-unknown-linux-gnu.tar.gz" \
      | tar xz --strip-components=1 -C "${PREFIX}/bin" \
    && "${PREFIX}/bin/uv" --version

# --- activate.sh + MANIFEST -----------------------------------------------
# Both generators live in scripts/ rather than inline: a multi-line shell
# heredoc inside RUN only parses under BuildKit's own heredoc form, and the
# double-escaping needed to satisfy both the Dockerfile and the shell parser
# makes the generated file impossible to review.
COPY scripts/gen-activate.sh scripts/gen-manifest.sh scripts/bundle-libs.sh /usr/local/bin/

# Must run before the manifest: it adds files to the prefix, and it is the check
# that the bundle carries every non-glibc library it needs rather than borrowing
# them from this image. Without it the bundle installs cleanly and then fails at
# `import ctypes` on a host whose libffi has a different SONAME.
RUN PREFIX="${PREFIX}" bash /usr/local/bin/bundle-libs.sh

RUN mkdir -p "${PREFIX}" \
    && PREFIX="${PREFIX}" bash /usr/local/bin/gen-activate.sh \
    && PREFIX="${PREFIX}" bash /usr/local/bin/gen-manifest.sh > "${PREFIX}/MANIFEST" \
    && cat "${PREFIX}/MANIFEST"

# Smoke-test inside the build, so a broken bundle never reaches a machine.
RUN set -eux; \
    "${PREFIX}/python/bin/python3.10" -c 'import ssl,ctypes,sqlite3,lzma,venv,ensurepip'; \
    echo 'int main(){}' | "${PREFIX}/gcc/bin/g++-15" -std=c++23 -x c++ - -o /tmp/probe; \
    "${PREFIX}/bin/ccache" --version; \
    CCACHE_NAMESPACE=probe "${PREFIX}/bin/ccache" -p | grep -qi namespace; \
    "${PREFIX}/bin/uv" --version
