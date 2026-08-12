# pypto-toolchain

One reproducible host toolchain for every machine that builds PyPTO — CI
runners, development boxes, new hardware.

A **bundle** is a `.tar.gz` holding a prebuilt CPython, GCC (with the libstdc++
`ptoas` links against), `uv` and `ccache`. It unpacks into a fixed prefix, is
identified by one version number, and is verified by one sha256. Two machines
that report the same bundle version are byte-for-byte identical.

## Why this exists

The three PyPTO repositories used to get their toolchain from per-machine conda
environments. Measured across two machines in the fleet:

| | dev box | CI runner |
| --- | --- | --- |
| Python 3.10 | openEuler rpm (mixed into an HCE2 system) | absent — only 3.9 |
| `g++-15` | self-built 15.2.1, `aarch64-unknown-linux-gnu` | conda 15.2.0, `aarch64-conda-linux-gnu` |
| ccache | 3.7.12 — silently ignores `CCACHE_NAMESPACE` | 4.10 |
| package repos | openEuler 23.03 | HCE2 |

Nothing in CI noticed. Both machines built and tested green while compiling with
different compilers, and the older ccache had quietly disabled the cache
namespacing that keeps a `pto-isa` bump from reusing stale objects.

The bundle removes the whole class of problem by depending on almost nothing:

```
bundle requires from the host = { Linux kernel, glibc >= 2.28, aarch64 or x86_64 }
```

Everything else it carries.

## What is and is not in the bundle

| | Component | Why |
| --- | --- | --- |
| in | CPython 3.10 | no distro in the fleet ships it |
| in | GCC 15 + libstdc++ | simpler's sim kernels need `-std=c++23`; `ptoas` needs `GLIBCXX_3.4.29` and HCE2 stops at 3.4.28 |
| in | `uv` | per-job venvs get torch by hardlink from a shared cache |
| in | `ccache` >= 4.8 | `CCACHE_NAMESPACE` is ignored before 4.8 |
| out | `ptoas` | pinned per project in `pypto/toolchain/versions.env`, fetched per job; bumped far more often |
| out | CANN / NPU driver | bound to the machine; detected, never deployed |
| out | torch, numpy, … | project dependencies; installed into each job's venv |

The split is by **rate of change**, not by kind of tool. Putting `ptoas` in the
bundle would turn a zero-cost version bump into a fleet-wide redeployment.

## Build

Builds natively for the host architecture; the two architectures are produced on
two machines and merged into one manifest.

```bash
scripts/build.sh 2026.08.1              # host arch, upstream sources
scripts/build.sh 2026.08.1 --mirror cn  # domestic source mirrors
```

Produces `dist/pypto-toolchain-<version>-<arch>.tar.gz`, its `.sha256`, and
updates `manifest/<version>.env`.

The container only *builds* the tree. It is exported as a tarball and unpacked
on bare metal, because the device/HCCL jobs cannot run inside docker — the chip
child silently dies in `comm_init`.

## Deploy

```bash
curl -fsSL .../install.sh | sudo bash        # installs the CLI
sudo pypto-toolchain install 2026.08.1       # download, verify, unpack
sudo pypto-toolchain use     2026.08.1       # point `current` at it
pypto-toolchain verify                       # checksums + smoke tests
```

Installing a bundle does not disturb anything already on the machine: no rpm is
installed, no system Python or GCC is replaced, `/etc` is untouched. Uninstall is
`rm -rf` on one directory. A fleet can therefore be rolled out one machine at a
time, with conda left in place until every consumer has migrated.

[docs/deployment.md](docs/deployment.md) covers the rest: getting a proxy past
`sudo`, choosing where the bundle lands, installing with no route to GitHub, and
the errors that do not say what they mean.

## Use

```bash
source /opt/pypto/toolchain/current/activate.sh
```

In CI, assert capabilities rather than a version, so upgrading the bundle does
not require touching any consumer repository:

```yaml
- run: |
    pypto-toolchain verify --require python=3.10 --require gcc'>='15 --require ccache'>='4.8
    source /opt/pypto/toolchain/current/activate.sh
```

## The prefix is fixed

`/opt/pypto/toolchain/<version>` is compiled into the binaries — `cc1plus`
literally contains the string, `g++ -print-search-dirs` resolves against it, and
Python's `sysconfig` reports it to every extension build. Unpacking elsewhere
yields a subtly broken toolchain, so changing it means rebuilding, not
reconfiguring.

`/opt/pypto` may be a symlink to a roomier filesystem — the *path string* is what
has to match, not the physical location:

```bash
sudo mkdir -p /data/pypto && sudo ln -s /data/pypto /opt/pypto
```

`activate.sh` names the versioned directory and never `current`: the GCC driver
locates `cc1plus` relative to its own `argv[0]`, and a PATH threaded through the
symlink would compute a path that disagrees with the compiled-in prefix.

## The glibc floor

Built on `manylinux_2_28` (glibc 2.28), so the bundle runs on any host at or
above that floor — glibc is backward compatible. The floor is a *declared*
contract, not a survey of current machines: a host added next year needs no
re-testing, and `install.sh` refuses to install on anything below it, before
downloading. For scale, `ptoas` itself already requires `GLIBC_2.34`, so this
floor will never be the binding constraint.

## What the host must still provide

The bundle carries a compiler, not a C library. Two things come from the machine:

| From the host | Why |
| --- | --- |
| `binutils` (`as`, `ld`) | GCC drives the system assembler and linker |
| `glibc-devel` (`crt1.o`, `libc.so`) | the C runtime startup files every link needs |

`verify` checks for both, because their absence otherwise surfaces as
`cannot find crt1.o` from the linker — which reads like a corrupt bundle rather
than a missing package.

**RHEL-family hosts only.** GCC resolves those files through library paths baked
in at configure time, in the build image's layout (`/usr/lib64`). Debian and
Ubuntu place them under a multiarch triplet directory instead, so linking fails
there. Every machine in this fleet runs an RHEL derivative (HCE2, openEuler);
supporting Debian would mean shipping a sysroot, which is a different and much
larger artifact.
