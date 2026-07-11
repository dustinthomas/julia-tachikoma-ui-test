# Relocatable Linux bundle — off-machine / container smoke

**Status (Stage 1):** internal only. Same-architecture Linux x86_64 bundles via
PackageCompiler `create_app`. **Do not** claim multi-machine redistribution
success until you have exit-code evidence from a machine (or container) that is
not the build host — and document what you actually ran.

This file is the procedure. The optional helper script is
`packaging/relocatable_container_smoke.sh`.

---

## `QCI_CPU_TARGET`: dev vs release

`packaging/build_linux_app.jl` passes `cpu_target` to PackageCompiler
`create_app` (env `QCI_CPU_TARGET`, default **`native`**).

| Use case | Recommended `QCI_CPU_TARGET` | Notes |
|----------|------------------------------|--------|
| Stage 1 / same-machine internal build | **`native`** (default) | Fastest codegen for the build CPU. **Not** portable to older ISA levels. |
| Redistribution attempt (other x86_64 Linux hosts) | **`generic`** | Broadest LLVM x86-64 baseline; safer for “runs on other boxes”. Often slower than `native`. |
| Optional multi-dispatch (advanced) | Julia multi-target string | e.g. official-style multi-CPU lists; only if you know the target fleet. Not required for Stage 1. |

Examples:

```bash
# Dev / Stage 1 (default)
julia --project=packaging packaging/build_linux_app.jl

# Explicit native
QCI_CPU_TARGET=native julia --project=packaging packaging/build_linux_app.jl

# Broader ISA for a redistribution *attempt* (rebuild required)
QCI_CPU_TARGET=generic julia --project=packaging packaging/build_linux_app.jl
```

**Caveats (not solved by `cpu_target` alone):**

- **Architecture** must match (this pipeline is Linux **x86_64** only).
- **glibc** (and other host libs the dynamic loader needs) must be **new enough**.
  A bundle built on a newer distro may fail on older glibc with errors like
  `version 'GLIBC_2.38' not found`. Prefer building on the oldest supported
  target OS, or smoke-test on that OS image before shipping.
- PackageCompiler apps are relocatable **directories** (bin + lib + share), not
  a single static binary. Move/tar the whole tree.

Research note: PackageCompiler documents apps as bundles intended for other
machines of the same OS/arch; `cpu_target` is the PackageCompiler/`create_app`
knob that maps to Julia’s CPU feature selection. Community practice for
portability is **`generic`** (or a multi-target string). Official Julia builds
use multi-version CPU targets; for this Stage 1 product we default **`native`**
and recommend **`generic`** when deliberately preparing a redistributable build.

---

## What “relocatable smoke” means here

| Check | What it proves | What it does **not** prove |
|-------|----------------|----------------------------|
| `./bin/qci-kanban --smoke` on the build host | Bundle runs where it was built | Other machines / other glibc |
| Same binary after `tar` extract on another path on the **same** host | Path independence on that host | Cross-machine ISA/glibc |
| Docker/podman mount of the **whole** dist tree + `--smoke` | Runs under a different userspace (libc, etc.) than the host | Full multi-machine fleet; graphics/TTY product UX |
| Real second physical/VM host | True off-build-machine run | — |

Always report: command, image/host, exit code, and `cpu_target` used at build.

---

## Prerequisites

1. A built tree: `dist/qci-kanban-linux/` (or a tarball extract) with
   `bin/qci-kanban` executable.
2. Do **not** set `JULIA_PROJECT` / `JULIA_LOAD_PATH` or wrap with
   `julia --project=.` from a source checkout when running the bundle.
3. Optional: Docker or Podman for container smoke (script degrades if missing).

Build reminder (from `qci-kanban/`):

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=packaging -e 'using Pkg; Pkg.instantiate()'
julia --project=packaging packaging/build_linux_app.jl
```

---

## Host smoke (always run first)

```bash
# From qci-kanban/, after build:
./dist/qci-kanban-linux/bin/qci-kanban --smoke
# or:
julia packaging/smoke_bundle.jl
julia packaging/smoke_bundle.jl /path/to/dist/qci-kanban-linux
```

Expect **exit 0**. Failure → fix the bundle before any container/off-machine work.

### Tarball round-trip (same host, different path)

```bash
tar -C dist -czf /tmp/qci-kanban-linux.tgz qci-kanban-linux
mkdir -p /tmp/qci-unpack && tar -C /tmp/qci-unpack -xzf /tmp/qci-kanban-linux.tgz
/tmp/qci-unpack/qci-kanban-linux/bin/qci-kanban --smoke
echo "exit=$?"
```

---

## Container smoke (optional; Docker/Podman)

Helper (from `qci-kanban/`):

```bash
# Default: dist/qci-kanban-linux, image ubuntu:24.04
./packaging/relocatable_container_smoke.sh

# Explicit dist path or tarball extract
./packaging/relocatable_container_smoke.sh /path/to/qci-kanban-linux

# Override image (must provide new enough glibc for *this* build)
QCI_SMOKE_IMAGE=ubuntu:24.04 ./packaging/relocatable_container_smoke.sh
```

The script:

1. Locates `bin/qci-kanban` under the dist dir.
2. Runs host smoke first (unless `QCI_SMOKE_SKIP_HOST=1`).
3. If `docker` or `podman` is available, mounts the dist dir read-only and runs
   `bin/qci-kanban --smoke` inside the container.
4. If no container runtime: prints a skip message and exits **0** after a
   successful host smoke (or **1** if host smoke failed / dist missing).
5. Does **not** claim multi-machine success in its output beyond what it ran.

### Image choice

| Image | Typical use |
|-------|-------------|
| **`ubuntu:24.04`** (script default) | Hosts with glibc ≥ ~2.39; matches many modern build machines |
| `debian:bookworm-slim` | Often **too old** if the build host has glibc 2.38+ (smoke fails with `GLIBC_* not found`) |
| Custom plant image | Best proxy for real deploy OS |

**glibc rule of thumb:** the container (or target host) must be **≥** the build
machine’s glibc ABI for libraries bundled with Julia/libstdc++. If smoke fails
on glibc, rebuild on an older base OS or raise the minimum supported target —
do not paper over with “it works on the build box only” for redistribution.

---

## Honest Stage 1 wording

Until you have recorded successful `--smoke` on a **second** machine or a
deliberate container/VM matrix:

- Ship **internal only** (`dist/` or private tarball).
- README / release notes: **Stage 1 internal** — build-machine verification
  (and optional container proxy) only; **not** a verified multi-machine product
  release.
- Prefer `QCI_CPU_TARGET=generic` when you start true redistribution trials;
  re-smoke after every rebuild.

---

## Evidence template (paste into notes / PR)

```text
date:
build host:
julia:
cpu_target:
bundle path:
du -sh:
host: ./bin/qci-kanban --smoke → exit=
tarball unpack path (optional): → exit=
container runtime: docker|podman|none
image (if any):
container: bin/qci-kanban --smoke → exit=
notes (glibc errors, skipped steps):
```
