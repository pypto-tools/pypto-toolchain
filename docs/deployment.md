# Deploying a bundle on a host

English | [中文](deployment.zh.md)

The README says what a bundle is and why it exists. This says how to get one
onto a machine, and documents the places a deployment actually stalls — most of
them proxy-related, none of them obvious from the error message.

## The host contract

A bundle depends on almost nothing, but "almost" is not "nothing":

| From the host | Checked by | Why |
| --- | --- | --- |
| aarch64 or x86_64 | `install.sh`, before downloading | the only two architectures built |
| glibc >= 2.28 | `install.sh`, before downloading | the floor the bundles are built against |
| `binutils` (`as`, `ld`) | `doctor`, `verify` | GCC drives the system assembler and linker |
| `glibc-devel` (`crt1.o`, `libc.so`) | `doctor`, `verify` | the C runtime startup files every link needs |
| RHEL-family layout | not checked — see below | GCC's library paths are baked in at configure time |

Preflight by hand, before installing anything:

```bash
uname -m                          # aarch64 or x86_64
ldd --version | head -1           # >= 2.28
cat /etc/os-release               # HCE2 / openEuler / AlmaLinux / Rocky
command -v as ld                  # binutils
gcc -print-file-name=crt1.o       # an absolute path that exists, not a bare "crt1.o"
```

That last one is the same trick `verify` uses. When GCC cannot find a file it
echoes the bare name back, so `crt1.o` on its own means "missing", while
`/usr/lib64/crt1.o` means the package is there.

On a machine that already builds PyPTO, all of this is usually present already —
check before reaching for the package manager.

## Proxy: sudo throws your environment away

This is the single most common way a deployment stalls, and it fails silently:
the download does not refuse, it hangs.

```bash
export https_proxy=http://127.0.0.1:7892
sudo pypto-toolchain install 2026.08.5     # the curl inside goes DIRECT
```

`sudo` runs with `env_reset`, which clears everything not on a whitelist. The
proxy you exported never reaches the `git` in `install.sh` or the `curl` in
`install`. Three ways through, in decreasing order of reliability:

### `sudo env VAR=value cmd` — recommended

```bash
sudo env https_proxy=http://127.0.0.1:7892 \
     /usr/local/bin/pypto-toolchain install 2026.08.5
```

sudo sees a command named `env` and some arguments; it has no idea an
environment variable is involved, so there is nothing for its policy to filter.
This works regardless of how sudoers is configured, which matters on a machine
you did not set up.

One catch: the target command is resolved by `env` against sudo's `secure_path`,
which does not always include `/usr/local/bin`. Use the absolute path, as above.

For a piped install, `env` execs `bash`, which still inherits the pipe:

```bash
curl -fsSL .../install.sh | sudo env https_proxy=http://127.0.0.1:7892 bash
```

### `sudo VAR=value cmd`

Here the assignment is an argument *to sudo*, which refuses it unless the user
carries `SETENV` in sudoers or the variable matches `env_keep`/`env_check`:

```
sudo: sorry, you are not allowed to set the following environment variables: https_proxy
```

Fine on a host you control, a coin flip elsewhere.

### `export` in `/etc/pypto-env.conf`

Persistent, and survives sudo for a reason worth understanding: both `install.sh`
and the CLI **source this file themselves**, after sudo has already reset the
environment.

```bash
sudo tee -a /etc/pypto-env.conf > /dev/null <<'EOF'

# pypto-toolchain: needed only by `install.sh` and `install` (the two network steps)
export https_proxy="http://127.0.0.1:7892"
export http_proxy="http://127.0.0.1:7892"
export no_proxy="localhost,127.0.0.0/8,::1,10.0.0.0/8,192.168.0.0/16"
EOF
```

`export` is not optional: `curl` and `git` are child processes, and a bare
assignment in a sourced file is only a shell variable. Note that the entries
that may already be in this file (`PTOAS_ROOT`, `ASCEND_HOME_PATH`, …) are
deliberately *not* exported — they are read back out by `pypto-toolchain export`.
Append to the file; do not rewrite it in another style.

If the URL carries credentials, `chmod 600` the file. And consider whether a
machine-wide file is the right home for a personal proxy at all: only two
commands ever need it, so `sudo env` is often the better shape. `doctor` redacts
the userinfo when it prints the proxy, because that report gets pasted into
tickets.

`sudo -E` is the fourth option and is not recommended: it is still subject to
`env_keep` filtering, so whether it carries the proxy varies per host.

### `127.0.0.1` means the machine you are deploying *to*

A proxy on your laptop is not reachable as `127.0.0.1:7892` from the target. Test
it on the target before anything else:

```bash
curl -sI --connect-timeout 5 -x http://127.0.0.1:7892 https://github.com | head -1
# HTTP/1.1 200 Connection established
```

If it is not there, either bind the proxy to the LAN and use the real address, or
tunnel it from the machine that has it:

```bash
ssh -R 7892:127.0.0.1:7892 <target>
```

### Only two steps need the network

`use`, `verify`, `doctor` and every later use of the toolchain are offline. If
the proxy is awkward, it is needed for exactly the CLI clone and the bundle
download — and both have offline alternatives (see below).

## Walkthrough

```bash
# 1. the host's half of the toolchain (skip if the preflight above already passed)
sudo dnf install -y binutils glibc-devel git tar findutils diffutils

# 2. the CLI — ~50 KB of scripts, installs no bundle
curl -fsSL https://raw.githubusercontent.com/pypto-tools/pypto-toolchain/main/install.sh \
  | sudo env https_proxy=http://127.0.0.1:7892 bash -s -- --storage /data/pypto

# 3. survey the host before committing to a 200 MB download
pypto-toolchain doctor

# 4. download, verify, unpack
sudo env https_proxy=http://127.0.0.1:7892 \
     /usr/local/bin/pypto-toolchain install 2026.08.5

# 5. select and check
sudo /usr/local/bin/pypto-toolchain use 2026.08.5
pypto-toolchain verify
```

Step 2 touches nothing else on the machine: no rpm, no system Python or GCC, no
`/etc` changes beyond a proxy line you added yourself, and any conda environment
is left alone. Step 5's `use` moves one symlink. Nothing changes for anything
already running until a consumer sources `activate.sh`, so there is no window to
wait for.

Then:

```bash
source /opt/pypto/toolchain/2026.08.5/activate.sh
```

## Where the bundle lives

`/opt/pypto/toolchain/<version>` is compiled into the binaries, so the *path
string* is fixed. The physical location is not — `--storage` points `/opt/pypto`
at a roomier filesystem:

```
/opt/pypto              -> /data/pypto     (symlink created by --storage)
  app/                  the CLI checkout
  toolchain/<version>/  the bundle
  toolchain/current     -> <version>
  cache/                downloaded tarballs
```

`--storage` refuses to run if `/opt/pypto` already exists and is not a symlink.
Check first with `ls -ld /opt/pypto`.

Two places not to put it:

- **A home directory or a CI workspace.** The CLI was moved out of
  `/home/pypto-tools` for this reason, and `install.sh` still warns about that
  old layout. Workspace cleanup, per-user quotas and home-directory backup tools
  all treat 200 MB × N versions as something to reclaim or copy.
- **NFS.** `root_squash` stops the root-owned unpack, and running a compiler off
  NFS is slow enough to notice. Check with `df -T <path>` before choosing.

Uninstall is `rm -rf` on the storage directory plus `/usr/local/bin/pypto-toolchain`.

## When there is no route to GitHub

Release assets are served from `objects.githubusercontent.com`, which several
hosts cannot reach even when `raw.githubusercontent.com` works. The cache is
checked before any download and the sha256 is verified whatever the source, so
any transport is equally safe.

Sideload one machine:

```bash
scp pypto-toolchain-2026.08.5-aarch64.tar.gz <host>:/tmp/
ssh <host> 'sudo cp /tmp/pypto-toolchain-2026.08.5-aarch64.tar.gz /opt/pypto/cache/ \
            && sudo pypto-toolchain install 2026.08.5'
```

Serve a fleet — tried before the GitHub release, and needs no proxy at all:

```bash
echo 'PYPTO_TOOLCHAIN_MIRROR=http://<intranet-host>:8080/toolchain' \
  | sudo tee -a /etc/pypto-env.conf
```

If even `install.sh` cannot clone, point it at a checkout you carried in:

```bash
sudo PYPTO_TOOLCHAIN_REPO=/path/to/pypto-toolchain bash /path/to/install.sh --storage /data/pypto
```

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `install` hangs with no progress | proxy did not survive `sudo` | `sudo env https_proxy=... <abs path> install <v>` |
| `sorry, you are not allowed to set the following environment variables` | `sudo VAR=value` without `SETENV` | use `sudo env` instead |
| `could not obtain a bundle matching sha256` | `objects.githubusercontent.com` unreachable | sideload into the cache, or set `PYPTO_TOOLCHAIN_MIRROR` |
| `cannot find crt1.o` from the linker | `glibc-devel` missing — or a Debian host | `dnf install glibc-devel`; on Debian, see below |
| `verify`: `prefix matches build` fails | unpacked somewhere other than `/opt/pypto/toolchain/<version>` | reinstall; the prefix is compiled in, not configurable |
| `doctor`: `no conda under …` while the prompt says `(base)` | it looks at `${CONDA_ROOT:-$HOME/miniconda3}` | `CONDA_ROOT="$(conda info --base)" pypto-toolchain doctor` |
| `dnf` fails with 403 on repodata | the host's own package mirror, unrelated to this tool | `dnf clean all`; then switch mirrors, or skip it if the preflight already passed |

`doctor`'s migration notes (`no ccache on PATH`, a conda env carrying pypto) never
block an install. They describe the state the machine is in today, and they go
quiet once the migration is done.

## Debian and Ubuntu are not supported

`install.sh` does not check the distribution, so a Debian-family host installs
cleanly and then fails at `verify`, with a message about `crt1.o` that reads like
a corrupt bundle.

The cause is layout. GCC resolves `crt1.o` and friends through library paths
baked in at configure time, in the build image's RHEL layout (`/usr/lib64`);
Debian and Ubuntu use a multiarch triplet directory
(`/usr/lib/x86_64-linux-gnu`) instead. Installing `libc6-dev` puts the files on
the disk but not where the compiler looks.

Two workarounds exist, neither supported:

- Run the build in a RHEL-family container. Not an option on a host that also
  runs device or HCCL jobs — the chip child dies silently in `comm_init` inside
  docker.
- Point GCC at the multiarch directories by hand. Both sides need it — the
  library side for the crt files, and the include side for the arch-specific
  glibc headers:

  ```bash
  export LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
  export CPATH=/usr/include/x86_64-linux-gnu
  ```

  `verify` still reports the crt check as failed, because it goes through
  `-print-file-name`, which does not consult `LIBRARY_PATH`. Linking a shared
  object is the test that matters here, since that is what a PyPTO extension
  module is:

  ```bash
  echo 'extern "C" int f(){return 42;}' \
    | g++-15 -std=c++23 -shared -fPIC -x c++ - -o /tmp/t.so \
    && python3.10 -c 'import ctypes; print(ctypes.CDLL("/tmp/t.so").f())'
  ```

Supporting Debian properly means shipping a sysroot, which would also bound the
glibc version of everything the toolchain *produces* — today an artifact built on
a 2.34 host requires 2.34, whatever the bundle's own floor says. That is a design
change, not a configuration one.
