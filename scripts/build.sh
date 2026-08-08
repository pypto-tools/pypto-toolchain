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
#   scripts/build.sh 2026.08.1 --mirror cn      # domestic mirrors for GCC/Python
#   scripts/build.sh 2026.08.1 --mirror cn --proxy socks5://127.0.0.1:1080
#                                               # ...and a proxy for the rest
#
# Note that --proxy only affects downloads made INSIDE the container. Pulling
# the base image is done by dockerd, which reads its proxy from a systemd
# drop-in and cannot be influenced from here:
#   /etc/systemd/system/docker.service.d/http-proxy.conf
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
PROXY="${PYPTO_BUILD_PROXY:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR_SET="$2"; shift 2 ;;
        --proxy)  PROXY="$2"; shift 2 ;;
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

# AlmaLinux 8 for both arches: glibc 2.28 (the floor the bundle promises), ~75 MB
# rather than manylinux's ~600 MB of prebuilt CPythons this build never touches,
# and on Docker Hub, which has usable regional mirrors — quay.io pulls at
# ~100 KB/s from these machines. Override to point at a mirror, e.g.
#   PYPTO_BASE_IMAGE=<registry-mirror>/almalinux:8 scripts/build.sh ...
BASE_IMAGE="${PYPTO_BASE_IMAGE:-almalinux:8}"

case "$ARCH" in
    aarch64) GCC_ARCH_CONFIG="--with-arch=armv8-a --with-tune=generic" ;;
             # x86-64-v2 (SSE4.2/POPCNT, Nehalem 2008+) rather than plain
             # x86-64: every machine that can host this is far newer, and the
             # baseline still excludes AVX so it stays portable.
    x86_64)  GCC_ARCH_CONFIG="--with-arch=x86-64-v2 --with-tune=generic" ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

case "$MIRROR_SET" in
    upstream) GNU_MIRROR="https://ftp.gnu.org/gnu"
              PYTHON_MIRROR="https://www.python.org/ftp/python" ;;
    cn)       GNU_MIRROR="https://mirrors.huaweicloud.com/gnu"
              PYTHON_MIRROR="https://mirrors.huaweicloud.com/python" ;;
    *) echo "unknown mirror set: $MIRROR_SET (expected: upstream, cn)" >&2; exit 2 ;;
esac

# Proxy for downloads made INSIDE the build container. Separate from the proxy
# dockerd needs to pull the base image: that one is a systemd drop-in on the
# daemon and nothing here can influence it.
#
# --mirror cn covers GCC and Python, but contrib/download_prerequisites
# (gcc.gnu.org) plus the ccache and uv release tarballs (github.com) still leave
# the network, and those are exactly the hosts that are slow here.
#
# HTTP_PROXY/HTTPS_PROXY/NO_PROXY are predefined build args: docker forwards
# them without an ARG declaration and keeps them out of the image history.
BUILD_PROXY_ARGS=()
BUILD_NETWORK_ARGS=()
if [ -n "$PROXY" ]; then
    BUILD_PROXY_ARGS=(--build-arg "HTTP_PROXY=$PROXY"
                      --build-arg "HTTPS_PROXY=$PROXY"
                      --build-arg "NO_PROXY=localhost,127.0.0.1,::1")
    case "$PROXY" in
        # A proxy on the host's loopback is unreachable from a container's own
        # 127.0.0.1, so the build has to share the host's network namespace to
        # use it. Anything else (a LAN address, a container name) routes fine
        # from the default bridge and is left alone.
        *//127.0.0.1:*|*//localhost:*|*//::1:*)
            BUILD_NETWORK_ARGS=(--network host)
            echo "note: proxy is on the host loopback -> building with --network host" ;;
    esac
    # socks5h:// is a curl-ism. Go's net/http, which is what curl-in-container
    # will NOT use but dockerd and many tools do, only understands socks5://;
    # curl accepts both, so normalise and avoid the footgun entirely.
    case "$PROXY" in
        socks5h://*) echo "note: rewriting socks5h:// to socks5:// (only curl understands socks5h)"
                     PROXY="socks5://${PROXY#socks5h://}"
                     BUILD_PROXY_ARGS=(--build-arg "HTTP_PROXY=$PROXY"
                                       --build-arg "HTTPS_PROXY=$PROXY"
                                       --build-arg "NO_PROXY=localhost,127.0.0.1,::1") ;;
    esac
fi

OUT_DIR="$REPO_ROOT/dist"
TARBALL="$OUT_DIR/pypto-toolchain-${VERSION}-${ARCH}.tar.gz"
IMAGE="pypto-toolchain:${VERSION}-${ARCH}"

# The base image is the only thing dockerd itself has to fetch, and it needs to
# happen exactly once per build machine — a restart does not lose it, and no
# other machine in the fleet needs it at all (they only install the resulting
# tarball). So pre-pulling it behind a temporary proxy is preferable to giving
# the daemon a permanent proxy it would keep failing against once that proxy
# goes away.
if ! "${DOCKER[@]}" image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    cat <<EOF
note: $BASE_IMAGE is not present locally, so dockerd has to fetch it.
      --proxy above does NOT apply: it covers downloads inside the container,
      while the image pull is done by the daemon, which reads its own proxy
      from a systemd drop-in.

      If the pull is slow, stop, pull it once behind a temporary drop-in, and
      remove the drop-in again — the image then stays cached for every later
      build:

        sudo mkdir -p /etc/systemd/system/docker.service.d
        printf '[Service]\\nEnvironment="HTTPS_PROXY=%s"\\n' "\${PROXY:-socks5://127.0.0.1:1080}" \\
          | sudo tee /etc/systemd/system/docker.service.d/zz-temp-proxy.conf
        sudo systemctl daemon-reload && sudo systemctl restart docker
        docker pull $BASE_IMAGE
        sudo rm /etc/systemd/system/docker.service.d/zz-temp-proxy.conf
        sudo systemctl daemon-reload && sudo systemctl restart docker

      Or point at a registry mirror, which needs no proxy at all:
        PYPTO_BASE_IMAGE=<mirror>/almalinux:8 $0 $VERSION ...

EOF
fi

echo "==> building $IMAGE"
echo "    prefix  $PREFIX"
echo "    base    $BASE_IMAGE"
echo "    mirrors $MIRROR_SET"

"${DOCKER[@]}" build \
    -f docker/build.Dockerfile \
    "${BUILD_NETWORK_ARGS[@]+"${BUILD_NETWORK_ARGS[@]}"}" \
    "${BUILD_PROXY_ARGS[@]+"${BUILD_PROXY_ARGS[@]}"}" \
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
