# julia

A lightweight SIVACOR-specific shim over the official
[`docker-library/julia`](https://github.com/docker-library/julia) image.

The official image is deliberately barebones: it creates no user, runs as root, and ships no
package registry. SIVACOR needs neither root nor a curated package set — it needs an image whose
depot layout works for an arbitrary uid on a read-only rootfs, and a registry present so that
resolving a researcher's declared environment does not begin by cloning General over the network.
That is all this adds.

Design and rationale: `development_notes/10_julia_support_plan.md` in the SIVACOR workspace notes.
The `10-D*` markers in the `Dockerfile` are that file's decision numbers.

## What it adds to the official image

| | why |
|---|---|
| a non-root `julia` user (uid 1000) | for anyone running the image directly. **Not** what makes a SIVACOR run non-root — the worker forces `--user <its own uid>:<its own gid>`, a pair present in no image's `/etc/passwd`, so everything here is world-readable rather than owned by this user (10-D9) |
| the General registry at `/opt/julia-depot` | without it every resolve clones General before it can begin (10-D8) |
| `JULIA_DEPOT_PATH=/workspace/.julia:/opt/julia-depot` | writes land in the workspace, reads fall through to the baked registry. `/workspace/.julia` is a sibling of the researcher's `project/`, so downloaded packages never enter the signed TRO (10-D7) |

**No packages are baked in.** Correctness never depends on a cache — the resolve phase downloads
what the researcher declared — so a package cache would buy runtime at the price of image size,
build time, and a curation list nobody has evidence for. And **no default environment is
populated**, because that would let `using` succeed against packages the researcher never declared,
producing a run that works here and nowhere else.

## How a SIVACOR run uses it

Two containers per submission stage. The first resolves, with the network on; the second runs the
analysis, honouring the submission's own network-isolation setting.

```
phase 1   julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'   network: on
phase 2   julia --startup-file=no --project=. main.jl                             network: per submission
```

A submission must ship a `Project.toml`. A `Manifest.toml` is optional but strongly encouraged —
without one, phase 1 resolves whatever versions exist that day and writes the manifest it produced
into the package, so the run is reproducible after the fact rather than by declaration.

## Build and check

```sh
docker build --build-arg JULIA_TAG=1.11.9-bookworm -t sivacor-julia:1.11.9-local .
./check.sh sivacor-julia:1.11.9-local      # three legs, non-zero on failure
./measure-resolve.sh sivacor-julia:1.11.9-local
```

`check.sh` reproduces every constraint the worker imposes — an arbitrary uid present in no
`/etc/passwd`, a read-only rootfs, `HOME` on the workspace bind mount, and no network for the
analysis container — and asserts the resolve phase writes its manifest, does not re-clone the
registry, and fails an unsatisfiable environment in phase 1 rather than phase 2.

`measure-resolve.sh` times a cold resolve of a real AEA replication package's dependency set.
**Where you run it is part of the measurement**: a fast link makes the download half disappear.
