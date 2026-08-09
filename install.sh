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

# Anything that aborts before the first echo would otherwise leave the user
# staring at a silent prompt — which is exactly how the glibc probe below failed
# once, and indistinguishable from "curl fetched nothing" when this script is
# piped into bash.
trap 'rc=$?; [ $rc -ne 0 ] && echo "install.sh: failed at line $LINENO (exit $rc)" >&2' EXIT

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

# sudo clears the environment, so a proxy exported in the caller's shell never
# reaches the git below. Read it from the same config file the CLI uses, which
# survives sudo because this script sources it itself.
for _conf in "${PYPTO_ENV_CONF:-}" /etc/pypto-env.conf; do
    if [ -n "$_conf" ] && [ -f "$_conf" ]; then
        # shellcheck disable=SC1090
        . "$_conf"
        echo "config: $_conf"
        break
    fi
done

# Fetching from github.com over these links fails in two recurring ways: HTTP/2
# framing errors ("RPC failed; curl 16"), and transfers that stall rather than
# fail. Pin HTTP/1.1, enlarge the buffer, let git abandon a dead transfer, and
# retry with backoff — the same treatment PyPTO's own CI applies to its clones.
GIT_OPTS=(-c http.version=HTTP/1.1
          -c http.postBuffer=1048576000
          -c http.lowSpeedLimit=1000
          -c http.lowSpeedTime=60)
[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ] \
    && GIT_OPTS+=(-c "http.proxy=${https_proxy:-$HTTPS_PROXY}") \
    && echo "proxy: ${https_proxy:-$HTTPS_PROXY}"

retry_git() {
    local attempt=0
    until git "${GIT_OPTS[@]}" "$@"; do
        attempt=$((attempt + 1))
        [ "$attempt" -ge 4 ] && { echo "git $* failed after $attempt attempts" >&2; return 1; }
        echo "  git attempt $attempt failed; retrying in $((attempt * 5))s" >&2
        sleep $((attempt * 5))
    done
}

[ "$(id -u)" -eq 0 ] || die "must run as root (it writes to /usr/local/bin and /opt)"

# Refuse early and legibly on a host that could never run a bundle, rather than
# leaving a CLI that fails at every invocation. 2.28 is the floor the bundles
# are built against; ptoas separately needs 2.34, so this is the looser of the
# two checks and `verify` will surface the rest.
# sed rather than `head -1`: head exits after the first line, ldd is killed by
# SIGPIPE on its next write, and under `set -o pipefail` that 141 propagates to
# this assignment and `set -e` terminates the script — before a single line of
# output, so the failure looks like nothing happened at all. sed without `q`
# consumes all of the input.
glibc="$(ldd --version | sed -n '1s/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')"
[ -n "$glibc" ] || die "could not determine this host's glibc version from 'ldd --version'"
# `tail -1` of a version sort: tail reads its input to the end, so no writer in
# the pipeline is ever signalled.
if [ "$glibc" != "2.28" ] && \
   [ "$(printf '2.28\n%s\n' "$glibc" | sort -V | tail -1)" != "$glibc" ]; then
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
    retry_git -C "$APP_DIR" fetch --depth=1 origin HEAD || die "could not update $APP_DIR"
    git -C "$APP_DIR" reset --hard FETCH_HEAD
else
    echo "cloning into $APP_DIR"
    rm -rf "$APP_DIR"
    retry_git clone --depth=1 "$REPO_URL" "$APP_DIR" || die "could not clone $REPO_URL"
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
