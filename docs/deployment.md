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
| `glibc-devel` / `libc6-dev` (`crt1.o`, `libc.so`) | `doctor`, `verify` | the C runtime startup files every link needs |
| multiarch layout, if any | `install`, which then adapts to it | GCC's library paths are baked in at configure time — see below |

Preflight by hand, before installing anything:

```bash
uname -m                          # aarch64 or x86_64
ldd --version | head -1           # >= 2.28
cat /etc/os-release               # RHEL family, or Debian family — both work
command -v as ld                  # binutils
gcc -print-file-name=crt1.o       # an absolute path that exists, not a bare "crt1.o"
```

That last one is the same trick `verify` uses. When GCC cannot find a file it
echoes the bare name back, so `crt1.o` on its own means "missing", while
`/usr/lib64/crt1.o` — or `/usr/lib/x86_64-linux-gnu/crt1.o` on Debian and
Ubuntu — means the package is there.

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
| `cannot find crt1.o` from the linker | the C runtime dev package is missing | `dnf install glibc-devel`, or `apt install libc6-dev` |
| `cannot find crt1.o` on Debian/Ubuntu with `libc6-dev` already installed | the multiarch specs file was never written, or a reinstall wiped it | `pypto-toolchain install <version> --force` |
| `verify`: `prefix matches build` fails | unpacked somewhere other than `/opt/pypto/toolchain/<version>` | reinstall; the prefix is compiled in, not configurable |
| `doctor`: `no conda under …` while the prompt says `(base)` | it looks at `${CONDA_ROOT:-$HOME/miniconda3}` | `CONDA_ROOT="$(conda info --base)" pypto-toolchain doctor` |
| `dnf` fails with 403 on repodata | the host's own package mirror, unrelated to this tool | `dnf clean all`; then switch mirrors, or skip it if the preflight already passed |

`doctor`'s migration notes (`no ccache on PATH`, a conda env carrying pypto) never
block an install. They describe the state the machine is in today, and they go
quiet once the migration is done.

## Debian and Ubuntu

Supported, with one adaptation that `install` applies on its own.

GCC resolves `crt1.o` and the arch-specific glibc headers through library paths
baked in at configure time, in the build image's RHEL layout (`/usr/lib64`,
`/usr/include`). Debian and Ubuntu use a multiarch triplet directory
(`/usr/lib/x86_64-linux-gnu`) instead. Installing `libc6-dev` puts the files on
the disk but not where the compiler looks, so the link fails with a message
about `crt1.o` that reads like a corrupt bundle.

`install` closes the gap by writing a specs file into GCC's own lib directory:

```
*self_spec:
+ -B/usr/lib/x86_64-linux-gnu -idirafter /usr/include/x86_64-linux-gnu
```

GCC loads a specs file found there automatically, so no consumer has to
remember a flag and no CI job has to export anything. Three details matter:

- **`-B`, not `LIBRARY_PATH`.** `-B` joins the startfile search that
  `-print-file-name` consults, so `verify`'s crt check passes for the same
  reason the link does. `LIBRARY_PATH` is not consulted by `-print-file-name`,
  which is why the older workaround left that check red even when builds worked.
- **`-idirafter`, not `-I`.** The multiarch include directory goes last, so the
  bundle's own C++ headers keep priority. Confirmed on Ubuntu 24.04:
  `<format>` still resolves inside the bundle.
- **Detected by behaviour, not by `/etc/os-release`.** `install` writes the file
  only when the compiler cannot find `crt1.o` *and* a `/usr/lib/*/crt1.o`
  exists. An RHEL host therefore never gets a specs file.

That last point is a correctness requirement, not tidiness. On a host whose
`ld.so.conf` carries a second GCC's `libgcc_s` — a hand-deployed
`/data/software/gcc-15`, exactly the drift this bundle exists to replace — the
*presence* of any user specs file breaks C++ linking with `DSO missing from
command line`, whatever the file contains. Writing one unconditionally would
have broken working RHEL machines to fix Debian ones.

The file lives inside the version prefix, so `install --force` and every version
upgrade recreate it; nothing else needs doing.

### Verified

Ubuntu 24.04.3, x86_64, glibc 2.39, CANN 9.2.0: `verify` passes all twelve
checks. A shared object built with `-std=c++23` loads through `ctypes`, and
linking `libascendcl.so` produces no `@GLIBC_2.xx` version conflict.

### Why not a sysroot

Shipping a sysroot is the textbook fix, and it is the wrong one here. It would
bound the glibc version of everything the toolchain *produces* — today an
artifact built on a 2.34 host requires 2.34, whatever the bundle's own floor
says. Worse, the sysroot's glibc would have to be at least as new as the glibc
of every host library the artifacts link against, CANN included; that version is
machine-bound and outside the bundle, so the bundle would end up tracking the
fleet it was built to abstract over. A sysroot would also hide the host's
`/usr/include` entirely, forcing every system header the three PyPTO
repositories rely on to be enumerated and maintained. That is a design change,
not a configuration one.
