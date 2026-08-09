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
# Bootstrap the pypto-toolchain CLI on a host. Installs ~50 KB of scripts; the
# bundle itself is a separate, explicit step.
#
#   curl -fsSL .../install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --storage /data/pypto
#   curl -fsSL .../install.sh | sudo bash -s -- --version 2026.08.1
#
# Deliberately does NOT install a bundle by default: on a machine that is
# currently building through conda, adding the CLI must be a no-op for anything
# already running.

set -euo pipefail

REPO_URL="${PYPTO_TOOLCHAIN_REPO:-https://github.com/pypto-tools/pypto-toolchain.git}"
# Everything this tool owns lives under one prefix: the CLI checkout, the
# bundles and the download cache. Uninstalling is then `rm -rf /opt/pypto` plus
# the symlink below, and since /opt/pypto is usually redirected to a roomier
# filesystem (see --storage), none of it lands on the root partition.
APP_DIR="/opt/pypto/app"
BIN_LINK="/usr/local/bin/pypto-toolchain"
STORAGE=""
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --storage) STORAGE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help)
            sed -n '12,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (it writes to /usr/local/bin and /opt)"

# Refuse early and legibly on a host that could never run a bundle, rather than
# leaving a CLI that fails at every invocation. 2.28 is the floor the bundles
# are built against; ptoas separately needs 2.34, so this is the looser of the
# two checks and `verify` will surface the rest.
glibc="$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
if [ "$(printf '2.28\n%s\n' "$glibc" | sort -V | head -1)" != "2.28" ]; then
    die "glibc $glibc is below the 2.28 floor; this host cannot run pypto-toolchain bundles"
fi
case "$(uname -m)" in
    aarch64|x86_64) ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac
echo "host: $(hostname)  glibc $glibc  $(uname -m)"

# /opt/pypto is frequently a symlink onto a roomier filesystem: the *path
# string* is what has to be identical fleet-wide (it is compiled into GCC and
# Python), not the physical location. On these hosts / is often the small
# partition while the data disk has room.
if [ -n "$STORAGE" ]; then
    if [ -e /opt/pypto ] && [ ! -L /opt/pypto ]; then
        die "/opt/pypto already exists and is not a symlink; move it aside or drop --storage"
    fi
    mkdir -p "$STORAGE"
    ln -sfn "$STORAGE" /opt/pypto
    echo "storage: /opt/pypto -> $STORAGE"
else
    mkdir -p /opt/pypto
fi
mkdir -p /opt/pypto/toolchain /opt/pypto/cache

# An earlier layout put the CLI beside the other host tools in
# /home/pypto-tools/<tool>/app. Point it out rather than deleting anything under
# a home directory unprompted.
if [ -d /home/pypto-tools/pypto-toolchain ]; then
    echo "note: an old checkout remains at /home/pypto-tools/pypto-toolchain."
    echo "      It is no longer used — remove it once this install verifies."
fi

mkdir -p "$(dirname "$APP_DIR")"
if [ -d "$APP_DIR/.git" ]; then
    echo "updating $APP_DIR"
    git -C "$APP_DIR" fetch --depth=1 origin HEAD
    git -C "$APP_DIR" reset --hard FETCH_HEAD
else
    echo "cloning into $APP_DIR"
    rm -rf "$APP_DIR"
    git clone --depth=1 "$REPO_URL" "$APP_DIR"
fi
chmod +x "$APP_DIR/bin/pypto-toolchain" "$APP_DIR/scripts/"*.sh
ln -sfn "$APP_DIR/bin/pypto-toolchain" "$BIN_LINK"
echo "cli: $BIN_LINK -> $APP_DIR/bin/pypto-toolchain"

# Supersede the hand-deployed pypto-setup, which is read-only, unversioned, and
# has drifted per machine. Keeping the name means existing muscle memory and any
# script calling `pypto-setup --export` keeps working.
if [ -f /usr/local/bin/pypto-setup ] && [ ! -L /usr/local/bin/pypto-setup ]; then
    cp -a /usr/local/bin/pypto-setup /usr/local/bin/pypto-setup.pre-toolchain
    printf '#!/bin/sh\nexec %s export "$@"\n' "$BIN_LINK" > /usr/local/bin/pypto-setup
    chmod +x /usr/local/bin/pypto-setup
    echo "pypto-setup: replaced by a wrapper (original kept as pypto-setup.pre-toolchain)"
fi

if [ -n "$VERSION" ]; then
    "$BIN_LINK" install "$VERSION"
    "$BIN_LINK" use "$VERSION"
else
    cat <<EOF

CLI installed. Nothing else on this host was touched — no rpm, no system
Python or GCC, no /etc changes, and any conda environment is untouched.

Next:
  pypto-toolchain list
  sudo pypto-toolchain install <version>
  sudo pypto-toolchain use <version>
  pypto-toolchain verify
EOF
fi
