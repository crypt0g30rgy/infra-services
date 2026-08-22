#!/usr/bin/env python3
"""Report which container images in this repo (or in the live cluster) are behind.

Scope is public registries that answer anonymously - Docker Hub, ghcr.io, gcr.io
and friends. Internal registries are listed as out of scope rather than checked:
registry.internal.example.com and the pi's local registry need credentials, are not
routable from a GitHub runner, and hold images this repo builds itself, so
"is there a newer upstream tag" is not a question they can answer.

Two questions, because "is this image out of date" means two different things
depending on how the tag was written:

  * A pinned tag (traefik:v3.7.9, jenkins/jenkins:2.578) is out of date when the
    registry has a higher tag in the same channel. Comparing tag *names* answers
    this, and no pull is needed.

  * A floating tag (:latest, :lts, :main) never changes name; the digest behind
    it moves. Comparing names is useless. What matters is whether the container
    that is actually running was started before the tag moved, which needs the
    running digest - so it is only answerable in --from-cluster mode.

Registry access is anonymous by default and read-only either way: this script
lists tags and reads manifest digests. It never pulls a layer and never writes.

Usage:
    check-image-updates.py                      # images declared in this repo
    check-image-updates.py --from-cluster       # images running in the cluster
    check-image-updates.py --markdown report.md # also write a Markdown report

Exit status is 0 even when updates exist, so a scheduled job reports rather than
fails. Pass --fail-on-updates to invert that.

Stdlib only, so it runs on a bare GitHub runner and on the pi without a venv.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Tags whose name carries no version, so a name comparison cannot say anything.
FLOATING = {"latest", "main", "master", "lts", "stable", "edge", "nightly", "dev"}

# Refs that are documentation rather than something deployed. ghcr.io/your-org
# is the placeholder in the vaultwarden backup manifest; asking a registry about
# it would 404 and add noise to every report.
PLACEHOLDER = re.compile(r"your-org|example\.com|<[^>]+>|\$\{")

# Registries that serve a pull-scoped token to an anonymous caller. Anything not
# on this list is treated as internal and left alone - it either needs
# credentials or is not reachable from wherever this runs, and in this cluster it
# is a registry holding images built here rather than pulled from upstream.
PUBLIC_REGISTRIES = {
    "docker.io",
    "ghcr.io",
    "gcr.io",
    "quay.io",
    "registry.k8s.io",
    "k8s.gcr.io",
    "public.ecr.aws",
    "mcr.microsoft.com",
    "docker.elastic.co",
}

MANIFEST_TYPES = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)

IMAGE_LINE = re.compile(r"""^\s*-?\s*image:\s*["']?([^"'\s#]+)""")

UA = "infra-services-image-check/1.0"


# --------------------------------------------------------------------------- #
# image reference parsing
# --------------------------------------------------------------------------- #

def parse_ref(ref: str) -> tuple[str, str, str, str | None]:
    """Split an image reference into (registry, repository, tag, digest).

    Follows Docker's own rule for deciding whether the first path segment is a
    registry or a user namespace: it is a registry only if it contains a dot or
    a colon, or is exactly "localhost".
    """
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)

    head, _, rest = ref.partition("/")
    if rest and ("." in head or ":" in head or head == "localhost"):
        registry, remainder = head, rest
    else:
        registry, remainder = "docker.io", ref

    repository, _, tag = remainder.rpartition(":")
    if not repository:                      # no colon at all
        repository, tag = remainder, "latest"

    # Docker Hub keeps single-segment names under the library/ namespace.
    if registry == "docker.io" and "/" not in repository:
        repository = f"library/{repository}"

    return registry, repository, tag, digest


VERSION = re.compile(r"^(v?)(\d+(?:\.\d+)*)(.*)$")


def version_key(tag: str) -> tuple[str, int, str, tuple[int, ...]] | None:
    """Classify a tag into a comparable (prefix, depth, suffix, numbers) key.

    Only tags sharing prefix, depth and suffix are ever compared, which keeps
    channels apart: 15-alpine is compared with 16-alpine but not with 15.14 or
    with 15.14-alpine. That is deliberately conservative. 15-alpine already
    floats to the newest 15.x, so calling 15.14-alpine an "update" would be
    noise, and treating 3.24 as an update to v3.24 would be a different image
    naming scheme entirely.
    """
    m = VERSION.match(tag)
    if not m:
        return None
    prefix, numbers, suffix = m.groups()
    parts = tuple(int(n) for n in numbers.split("."))
    return (prefix, len(parts), suffix, parts)


def jump_level(current: str, newest: str) -> str:
    """major / minor / patch, by which numeric component moved first.

    Worth separating, because the three ask for different things. A patch bump is
    a restart. A major bump can be a data migration you cannot undo - postgres
    15-alpine to 18-alpine is three pg_upgrade runs, not a tag edit - so it has no
    business sitting in the same list as traefik v3.7.9 to v3.7.11.
    """
    a = (version_key(current) or ("", 0, "", ()))[3]
    b = (version_key(newest) or ("", 0, "", ()))[3]
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return ("major", "minor")[i] if i < 2 else "patch"
    return "patch"


def newer_tags(current: str, available: list[str]) -> list[str]:
    cur = version_key(current)
    if cur is None:
        return []
    out = []
    for tag in available:
        key = version_key(tag)
        if key is None:
            continue
        if key[:3] == cur[:3] and key[3] > cur[3]:
            out.append((key[3], tag))
    out.sort()
    return [t for _, t in out]


# --------------------------------------------------------------------------- #
# registry client
# --------------------------------------------------------------------------- #

class Registry:
    """Minimal read-only registry v2 client with bearer-challenge handling."""

    def __init__(self) -> None:
        self._tokens: dict[str, str] = {}

    def _get(self, url: str, headers: dict[str, str], method: str = "GET"):
        req = urllib.request.Request(url, headers={"User-Agent": UA, **headers}, method=method)
        return urllib.request.urlopen(req, timeout=30)

    def _token(self, registry: str, repository: str) -> str:
        """Answer the 401 challenge from /v2/ to get a pull-scoped token."""
        cache_key = f"{registry}/{repository}"
        if cache_key in self._tokens:
            return self._tokens[cache_key]

        # Probe the API host, not the registry name: https://docker.io/v2/ is a
        # web redirect that answers with HTML, and only registry-1.docker.io
        # issues the 401 bearer challenge this depends on.
        host = self._api_host(registry)
        realm, service = f"https://{host}/token", host
        try:
            self._get(f"https://{host}/v2/", {})
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                challenge = exc.headers.get("Www-Authenticate", "")
                if m := re.search(r'realm="([^"]+)"', challenge):
                    realm = m.group(1)
                if m := re.search(r'service="([^"]+)"', challenge):
                    service = m.group(1)

        query = urllib.parse.urlencode(
            {"service": service, "scope": f"repository:{repository}:pull"}
        )
        # Deliberately anonymous. Every registry in PUBLIC_REGISTRIES issues a
        # pull-scoped token without credentials, so this script has no login step
        # and no secret to leak. The cost is a per-IP rate limit, which shows up
        # as an honest "rate-limited" line in the report.
        with self._get(f"{realm}?{query}", {}) as resp:
            body = json.load(resp)
        token = body.get("token") or body.get("access_token") or ""
        self._tokens[cache_key] = token
        return token

    def _api_host(self, registry: str) -> str:
        return "registry-1.docker.io" if registry == "docker.io" else registry

    def tags(self, registry: str, repository: str) -> list[str]:
        token = self._token(registry, repository)
        host = self._api_host(registry)
        url = f"https://{host}/v2/{repository}/tags/list?n=200"
        collected: list[str] = []
        while url and len(collected) < 5000:
            with self._get(url, {"Authorization": f"Bearer {token}"}) as resp:
                collected.extend(json.load(resp).get("tags") or [])
                link = resp.headers.get("Link", "")
            if m := re.search(r'<([^>]+)>;\s*rel="next"', link):
                nxt = m.group(1)
                url = nxt if nxt.startswith("http") else f"https://{host}{nxt}"
            else:
                url = ""
        return collected

    def digest(self, registry: str, repository: str, tag: str) -> str:
        token = self._token(registry, repository)
        host = self._api_host(registry)
        url = f"https://{host}/v2/{repository}/manifests/{urllib.parse.quote(tag)}"
        headers = {"Authorization": f"Bearer {token}", "Accept": MANIFEST_TYPES}
        with self._get(url, headers, method="HEAD") as resp:
            return resp.headers.get("Docker-Content-Digest", "")


# --------------------------------------------------------------------------- #
# discovery
# --------------------------------------------------------------------------- #

def discover_repo(root: Path) -> dict[str, list[str]]:
    """Map image ref -> ["path:line", ...] for every YAML in the repo."""
    found: dict[str, list[str]] = {}
    for path in sorted(root.rglob("*")):
        if path.suffix not in (".yaml", ".yml") or not path.is_file():
            continue
        if any(part == ".git" for part in path.parts):
            continue
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8", errors="replace").splitlines(), 1
        ):
            if m := IMAGE_LINE.match(line):
                where = f"{path.relative_to(root)}:{lineno}"
                found.setdefault(m.group(1), []).append(where)
    return found


def discover_cluster() -> tuple[dict[str, list[str]], dict[str, set[str]]]:
    """Map image ref -> ["ns/pod", ...] and image ref -> {running digests}.

    status.containerStatuses[].imageID is the digest the kubelet actually
    started, which is the only way to tell that a :latest pod is stale.
    """
    raw = subprocess.run(
        ["kubectl", "get", "pods", "--all-namespaces", "-o", "json"],
        check=True, capture_output=True, text=True,
    ).stdout
    refs: dict[str, list[str]] = {}
    running: dict[str, set[str]] = {}
    for pod in json.loads(raw).get("items", []):
        meta, spec, status = pod["metadata"], pod["spec"], pod.get("status", {})
        where = f"{meta['namespace']}/{meta['name']}"
        for key in ("containers", "initContainers"):
            for container in spec.get(key) or []:
                refs.setdefault(container["image"], []).append(where)
        for key in ("containerStatuses", "initContainerStatuses"):
            for cs in status.get(key) or []:
                if "@sha256:" in (cs.get("imageID") or ""):
                    running.setdefault(cs["image"], set()).add(
                        cs["imageID"].split("@", 1)[1]
                    )
    return refs, running


# --------------------------------------------------------------------------- #
# checking
# --------------------------------------------------------------------------- #

def check(ref: str, where: list[str], registry: Registry, running: set[str]) -> dict:
    result = {"ref": ref, "where": where, "state": "current", "detail": ""}
    reg, repo, tag, digest = parse_ref(ref)
    result.update(registry_name=reg, repository=repo, tag=tag)

    if digest:
        result.update(state="pinned-by-digest", detail="pinned to a digest, nothing to compare")
        return result
    if PLACEHOLDER.search(ref):
        result.update(state="skipped", detail="placeholder reference, not a real image")
        return result
    if reg not in PUBLIC_REGISTRIES:
        result.update(state="internal",
                      detail=f"{reg} is internal - built here, not pulled from upstream")
        return result

    try:
        if tag in FLOATING or version_key(tag) is None:
            upstream = registry.digest(reg, repo, tag)
            result["upstream_digest"] = upstream
            if not running:
                result.update(
                    state="floating",
                    detail=f"floating tag; upstream is now {upstream[:19]}. "
                           "Run with --from-cluster to see if the running container predates it.",
                )
            elif upstream and upstream not in running:
                result.update(
                    state="stale-digest",
                    detail=f"running {', '.join(d[:19] for d in sorted(running))} "
                           f"but {tag} now points at {upstream[:19]}",
                )
            else:
                result.update(state="current", detail=f"floating tag, digest matches upstream")
            return result

        newer = newer_tags(tag, registry.tags(reg, repo))
        if newer:
            level = jump_level(tag, newer[-1])
            result.update(
                state=f"update-{level}",
                newest=newer[-1],
                level=level,
                detail=f"`{tag}` &rarr; `{newer[-1]}`"
                       + (f" (also {', '.join(newer[:-1][-3:])})" if len(newer) > 1 else ""),
            )
        else:
            result["detail"] = f"{tag} is the newest tag in its channel"
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            result.update(state="error", detail="registry rate-limited this check (HTTP 429)")
        else:
            result.update(state="error", detail=f"HTTP {exc.code} from {reg}")
    except Exception as exc:                                  # noqa: BLE001
        result.update(state="error", detail=f"{type(exc).__name__}: {exc}")
    return result


def divergent(results: list[dict]) -> list[tuple[str, list[str]]]:
    """Same repository referenced at more than one tag, which is usually a miss."""
    by_repo: dict[str, set[str]] = {}
    for r in results:
        if r["state"] not in ("skipped", "pinned-by-digest", "internal"):
            by_repo.setdefault(f"{r['registry_name']}/{r['repository']}", set()).add(r["tag"])
    return sorted((repo, sorted(tags)) for repo, tags in by_repo.items() if len(tags) > 1)


# --------------------------------------------------------------------------- #
# reporting
# --------------------------------------------------------------------------- #

ORDER = ["update-patch", "update-minor", "update-major", "stale-digest", "floating",
         "error", "current", "pinned-by-digest", "internal", "skipped"]

HEADINGS = {
    "update-patch": "Patch updates",
    "update-minor": "Minor updates",
    "update-major": "Major updates - read the release notes first",
    "stale-digest": "Running an outdated digest of a floating tag",
    "floating": "Floating tags (name cannot be compared)",
    "error": "Could not be checked",
    "current": "Up to date",
    "pinned-by-digest": "Pinned by digest",
    "internal": "Internal registry, out of scope",
    "skipped": "Skipped",
}

PREAMBLE = {
    "update-major": (
        "A first-component bump. Some of these are not a tag edit at all: a "
        "postgres major needs pg_upgrade or a dump and restore, and the volumes "
        "here have one replica and no backup target, so take a snapshot first."
    ),
    "internal": (
        "Left alone deliberately - these are built by CI from this platform's own "
        "repos and their tags are commit SHAs, so there is no upstream to be "
        "behind."
    ),
    "error": (
        "Transient upstream failures and rate limits both land here. A repeat "
        "across consecutive days is the signal; a single day is usually not."
    ),
}


def render(results: list[dict], source: str) -> str:
    buckets: dict[str, list[dict]] = {}
    for r in results:
        buckets.setdefault(r["state"], []).append(r)

    counts = {k: len(v) for k, v in buckets.items()}
    lines = [
        f"## Container image report ({source})",
        "",
        f"{len(results)} distinct image references. "
        + ", ".join(f"**{counts[k]} {HEADINGS[k].lower()}**" for k in ORDER if k in counts)
        + ".",
        "",
    ]

    for state in ORDER:
        rows = sorted(buckets.get(state, []), key=lambda r: r["ref"])
        if not rows:
            continue
        lines += [f"### {HEADINGS[state]}", ""]
        if state in PREAMBLE:
            lines += [PREAMBLE[state], ""]
        lines += ["| image | finding | referenced from |", "|---|---|---|"]
        for r in rows:
            where = ", ".join(r["where"][:4]) + (" ..." if len(r["where"]) > 4 else "")
            lines.append(f"| `{r['ref']}` | {r['detail']} | {where} |")
        lines.append("")

    if div := divergent(results):
        lines += ["### Same image at more than one tag", "",
                  "Worth a look: one of these is probably a copy that was never bumped.",
                  "", "| repository | tags in use |", "|---|---|"]
        lines += [f"| `{repo}` | {', '.join(f'`{t}`' for t in tags)} |" for repo, tags in div]
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-cluster", action="store_true",
                    help="read images from running pods via kubectl instead of from the repo")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent),
                    help="repo root to scan (default: the repo this script lives in)")
    ap.add_argument("--markdown", help="also write the Markdown report to this file")
    ap.add_argument("--json", dest="json_out", help="write raw results to this file")
    ap.add_argument("--only", help="only check refs containing this substring")
    ap.add_argument("--jobs", type=int, default=8, help="parallel registry queries (default 8)")
    ap.add_argument("--fail-on-updates", action="store_true",
                    help="exit 1 if any update is available (default: always exit 0)")
    args = ap.parse_args()

    running: dict[str, set[str]] = {}
    if args.from_cluster:
        refs, running = discover_cluster()
        source = "running in the cluster"
    else:
        refs = discover_repo(Path(args.root))
        source = "declared in this repo"

    if args.only:
        refs = {k: v for k, v in refs.items() if args.only in k}
    if not refs:
        print("No image references found.", file=sys.stderr)
        return 0

    registry = Registry()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(
            lambda item: check(item[0], item[1], registry, running.get(item[0], set())),
            sorted(refs.items()),
        ))

    report = render(results, source)
    print(report)
    if args.markdown:
        Path(args.markdown).write_text(report + "\n", encoding="utf-8")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(results, indent=2, default=list) + "\n",
                                       encoding="utf-8")

    behind = [r for r in results
              if r["state"].startswith("update-") or r["state"] == "stale-digest"]
    if behind and args.fail_on_updates:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
