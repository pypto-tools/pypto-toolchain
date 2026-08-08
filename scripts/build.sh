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
# Build one bundle and export it as a tarball plus its sha256.
#
#   scripts/build.sh 2026.08.1                  # build for the host arch
#   scripts/build.sh 2026.08.1 --mirror cn      # use domestic source mirrors
#
# Builds NATIVELY for the host architecture. Cross-building aarch64 under qemu
# would work but a full GCC bootstrap through emulation takes many hours, so the
# two architectures are produced on two machines instead (see
# .github/workflows/build.yml: x86_64 on a GitHub-hosted runner, aarch64 on a
# self-hosted one) and their artifacts merged into one manifest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version> [--mirror cn]" >&2
    exit 2
fi
shift

MIRROR_SET="upstream"
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR_SET="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Docker socket access, elevated only where it is actually needed. The script
# itself must keep running as the invoking user: every file it produces lands in
# the working tree (dist/, and manifest/<version>.env, which gets committed), and
# a root-owned manifest would need a chown before git would touch it.
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1 || { [ -t 0 ] && sudo docker info >/dev/null 2>&1; }; then
    DOCKER=(sudo docker)
    echo "note: using 'sudo docker' (no direct socket access for $(id -un))"
    echo "      to avoid the prompt permanently: sudo usermod -aG docker $(id -un) && newgrp docker"
else
    cat >&2 <<EOF
error: cannot reach the docker daemon as $(id -un), and sudo did not help.

  Add yourself to the docker group (preferred, survives reboots):
    sudo usermod -aG docker $(id -un)
    newgrp docker            # or log out and back in

  Or check the daemon is up:
    systemctl status docker
EOF
    exit 1
fi

ARCH="$(uname -m)"

# The prefix is compiled into the GCC driver and into Python's sysconfig, so it
# must be the deployed path exactly, version component and all. Changing it
# later is a full rebuild, not a config edit.
PREFIX="/opt/pypto/toolchain/${VERSION}"

case "$ARCH" in
    aarch64) BASE_IMAGE="quay.io/pypa/manylinux_2_28_aarch64"
             GCC_ARCH_CONFIG="--with-arch=armv8-a --with-tune=generic" ;;
    x86_64)  BASE_IMAGE="quay.io/pypa/manylinux_2_28_x86_64"
             # x86-64-v2 (SSE4.2/POPCNT, Nehalem 2008+) rather than plain
             # x86-64: every machine that can host this is far newer, and the
             # baseline still excludes AVX so it stays portable.
             GCC_ARCH_CONFIG="--with-arch=x86-64-v2 --with-tune=generic" ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

case "$MIRROR_SET" in
    upstream) GNU_MIRROR="https://ftp.gnu.org/gnu"
              PYTHON_MIRROR="https://www.python.org/ftp/python" ;;
    cn)       GNU_MIRROR="https://mirrors.huaweicloud.com/gnu"
              PYTHON_MIRROR="https://mirrors.huaweicloud.com/python" ;;
    *) echo "unknown mirror set: $MIRROR_SET (expected: upstream, cn)" >&2; exit 2 ;;
esac

OUT_DIR="$REPO_ROOT/dist"
TARBALL="$OUT_DIR/pypto-toolchain-${VERSION}-${ARCH}.tar.gz"
IMAGE="pypto-toolchain:${VERSION}-${ARCH}"

echo "==> building $IMAGE"
echo "    prefix  $PREFIX"
echo "    base    $BASE_IMAGE"
echo "    mirrors $MIRROR_SET"

"${DOCKER[@]}" build \
    -f docker/build.Dockerfile \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "PREFIX=$PREFIX" \
    --build-arg "GCC_ARCH_CONFIG=$GCC_ARCH_CONFIG" \
    --build-arg "GNU_MIRROR=$GNU_MIRROR" \
    --build-arg "PYTHON_MIRROR=$PYTHON_MIRROR" \
    -t "$IMAGE" \
    .

echo "==> exporting $TARBALL"
mkdir -p "$OUT_DIR"
# Tar with the version directory as the single top-level entry, so unpacking at
# /opt/pypto/toolchain lands it at exactly the prefix it was built for.
# The redirect is performed by THIS shell, not by the elevated docker, so the
# tarball is owned by the invoking user even when DOCKER is "sudo docker".
"${DOCKER[@]}" run --rm "$IMAGE" \
    tar czf - -C /opt/pypto/toolchain "$VERSION" > "$TARBALL"

SHA256="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
SIZE="$(du -h "$TARBALL" | cut -f1)"
echo "$SHA256  $(basename "$TARBALL")" > "$TARBALL.sha256"

echo "==> extracting the in-bundle manifest"
"${DOCKER[@]}" run --rm "$IMAGE" cat "$PREFIX/MANIFEST" > "$OUT_DIR/MANIFEST-${VERSION}-${ARCH}"

# The per-version manifest is the single source of truth consumed by install.sh.
# Written per-arch and merged, because the two architectures are built on
# different machines: whichever finishes second must not clobber the first.
ARCH_UPPER="$(printf '%s' "$ARCH" | tr '[:lower:]' '[:upper:]')"
MANIFEST_ENV="$REPO_ROOT/manifest/${VERSION}.env"
mkdir -p "$REPO_ROOT/manifest"
touch "$MANIFEST_ENV"

set_key() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" "$MANIFEST_ENV"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$MANIFEST_ENV"
    else
        printf '%s=%s\n' "$key" "$value" >> "$MANIFEST_ENV"
    fi
}

read_manifest() { grep -E "^$1 " "$OUT_DIR/MANIFEST-${VERSION}-${ARCH}" | awk '{print $2}'; }

set_key TOOLCHAIN_VERSION "$VERSION"
set_key GLIBC_FLOOR       "$(read_manifest GLIBC_FLOOR)"
set_key GCC_VERSION       "$(read_manifest GCC_VERSION)"
set_key PYTHON_VERSION    "$(read_manifest PYTHON_VERSION)"
set_key CCACHE_VERSION    "$(read_manifest CCACHE_VERSION)"
set_key UV_VERSION        "$(read_manifest UV_VERSION)"
set_key "BUNDLE_SHA256_${ARCH_UPPER}" "$SHA256"

cat <<EOF

==> done
    tarball  $TARBALL  ($SIZE)
    sha256   $SHA256
    manifest $MANIFEST_ENV

Next:
  1. commit manifest/${VERSION}.env
  2. attach $(basename "$TARBALL") to the ${VERSION} release
  3. on a target host: sudo pypto-toolchain install ${VERSION}
EOF
