#!/usr/bin/env python3
"""Decide which Julia images need rebuilding, and under what tags.

    ./plan_builds.py                 # human-readable plan
    ./plan_builds.py --json          # the plan as JSON
    ./plan_builds.py --github-output # also write matrix=/any= to $GITHUB_OUTPUT

**The trigger is the upstream digest, not the upstream version.** Two different
events have to produce a rebuild and only one of them changes a version number:

  1. a new Julia patch release -- `julia:1.11.9-bookworm` appears where
     `1.11.8-bookworm` was the newest;
  2. a rebuild of a tag we already built, which is how a Debian CVE fix reaches
     us. The version is identical; only the digest moves.

Watching the digest covers both, because a new version is just a tag whose
digest we have never seen. Watching the version covers only the first, and the
second is the one that carries security fixes.

Standard library only, and no docker: this has to run locally to be testable,
and a planning step that needs a daemon is one that only ever runs in CI.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
UPSTREAM_VERSIONS = (
    "https://raw.githubusercontent.com/docker-library/julia/master/versions.json"
)
GHCR_NAMESPACE = "sivacor"


def fetch_json(url: str, headers: dict | None = None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def current_patch_per_line() -> dict[str, str]:
    """Map ``1.11`` -> ``1.11.9`` for every line upstream currently publishes.

    Keyed off each entry's ``version`` field rather than off the key, because
    **the keys are not the lines**. Upstream publishes ``stable``, ``rc``, and
    a key per older maintained line -- so 1.13 has no ``1.13`` key at all today,
    it is whatever ``stable`` happens to point at, and that moves when 1.14
    lands. Reading the version string is stable across that; reading the key is
    not.

    Pre-releases are excluded by the regex: ``rc`` carries a version like
    ``1.13.0-rc4``, which must never be published as if it were ``1.13.0``.
    """
    versions = fetch_json(UPSTREAM_VERSIONS)
    per_line: dict[str, str] = {}
    for entry in versions.values():
        version = entry.get("version", "")
        match = re.fullmatch(r"(\d+\.\d+)\.\d+", version)
        if match:
            per_line[match.group(1)] = version
    return per_line


def dockerhub_digest(tag: str) -> str:
    """The manifest digest of ``julia:<tag>`` on Docker Hub.

    A HEAD against the registry with every manifest media type we might be
    offered; the digest comes back in ``Docker-Content-Digest``. Anonymous, via
    a pull-scoped token, so this needs no credentials anywhere.
    """
    token = fetch_json(
        "https://auth.docker.io/token"
        "?service=registry.docker.io&scope=repository:library/julia:pull"
    )["token"]
    req = urllib.request.Request(
        f"https://registry-1.docker.io/v2/library/julia/manifests/{tag}",
        method="HEAD",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": ", ".join(
                [
                    "application/vnd.oci.image.index.v1+json",
                    "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.docker.distribution.manifest.v2+json",
                ]
            ),
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        digest = resp.headers.get("Docker-Content-Digest")
    if not digest:
        raise RuntimeError(f"no Docker-Content-Digest for julia:{tag}")
    return digest


def published_tags(package: str) -> list[str]:
    """Tags already published for ``ghcr.io/sivacor/<package>``.

    An empty list for a package that does not exist yet, which is the normal
    case the first time a Julia line is added. **Anonymous access works only
    while the package is public** -- if this starts returning nothing for a
    package that certainly has tags, check the package's visibility before
    believing it, because a private package and an absent one look identical
    from here.
    """
    repo = f"{GHCR_NAMESPACE}/{package}"
    try:
        token = fetch_json(
            f"https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io"
        )["token"]
        body = fetch_json(
            f"https://ghcr.io/v2/{repo}/tags/list",
            headers={"Authorization": f"Bearer {token}"},
        )
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403, 404):
            return []
        raise
    return body.get("tags") or []


def choose_tag(version: str, today: str, existing: list[str]) -> str:
    """``<patch>-<build date UTC>``, with a numeric suffix if that is taken.

    Two builds of one line inside a single UTC day are unlikely from upstream
    but routine under workflow_dispatch. Overwriting would make the tag mutable,
    which is the one property the scheme exists to prevent, so take the next
    free suffix instead: ``1.11.9-20260916``, then ``1.11.9-20260916.2``.
    """
    base = f"{version}-{today}"
    if base not in existing:
        return base
    suffix = 2
    while f"{base}.{suffix}" in existing:
        suffix += 1
    return f"{base}.{suffix}"


def build_plan(today: str) -> dict:
    config = json.load(open(os.path.join(HERE, "lines.json")))
    tracked = json.load(open(os.path.join(HERE, "tracked.json")))
    upstream = current_patch_per_line()

    builds, skipped, dropped = [], [], []
    for item in config["lines"]:
        line, variant = item["line"], item["variant"]
        version = upstream.get(line)
        if version is None:
            # Upstream stopped publishing this line. Not an error: our tags
            # outlive theirs (10-D13). Say so loudly rather than silently
            # building nothing.
            dropped.append(line)
            continue

        upstream_tag = f"{version}-{variant}"
        digest = dockerhub_digest(upstream_tag)
        previous = tracked.get(line, {})
        if previous.get("upstream_digest") == digest:
            skipped.append({"line": line, "reason": "digest unchanged", "digest": digest})
            continue

        package = f"julia{line}"
        builds.append(
            {
                "line": line,
                "variant": variant,
                "version": version,
                "upstream_tag": upstream_tag,
                "upstream_digest": digest,
                "package": package,
                "tag": choose_tag(version, today, published_tags(package)),
            }
        )
    return {"builds": builds, "skipped": skipped, "dropped": dropped}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--github-output", action="store_true")
    parser.add_argument(
        "--date",
        default=datetime.datetime.now(datetime.UTC).strftime("%Y%m%d"),
        help="build date stamp, UTC. Overridable only for testing -- the tag "
        "must carry the date the build actually happened.",
    )
    args = parser.parse_args()

    plan = build_plan(args.date)

    if args.json:
        print(json.dumps(plan, indent=2))
    else:
        for build in plan["builds"]:
            print(
                f"BUILD  {build['package']}:{build['tag']}"
                f"  from julia:{build['upstream_tag']}  {build['upstream_digest'][:19]}…"
            )
        for skip in plan["skipped"]:
            print(f"skip   julia{skip['line']}  ({skip['reason']})")
        for line in plan["dropped"]:
            print(
                f"DROPPED  {line} is in lines.json but upstream no longer "
                f"publishes it; existing tags stay published (10-D13)"
            )
        if not plan["builds"]:
            print("nothing to build")

    if args.github_output and (path := os.environ.get("GITHUB_OUTPUT")):
        with open(path, "a") as handle:
            handle.write(f"matrix={json.dumps({'include': plan['builds']})}\n")
            handle.write(f"any={'true' if plan['builds'] else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
