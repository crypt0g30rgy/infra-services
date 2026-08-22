# scripts

## check-image-updates.py

Answers one question weekly: which container images are behind upstream?

```bash
python3 scripts/check-image-updates.py                 # tags declared in this repo
python3 scripts/check-image-updates.py --from-cluster   # images actually running
python3 scripts/check-image-updates.py --only traefik    # one image, while iterating
```

Stdlib only, no venv, no dependencies. It reads tag lists and manifest digests
over HTTPS; it never pulls a layer, never writes to a registry and never edits a
manifest in this repo. Bumping a tag stays a deliberate act.

### The two modes answer different questions

`--from-cluster` is the more truthful of the two and the one worth reading. It
asks the API server what is running, so it sees the whole cluster — including the
things installed by Helm or by a microk8s addon that were never written down in
this repo. That is where the interesting findings are: on the first run it turned
up a `coredns` five minor versions back and a `busybox` from 2018, neither of
which appears in any file here.

The default repo mode only sees `image:` lines in this repo's YAML, so it is
blind to anything installed by a chart — but it tells you the file and line to
edit, which the cluster cannot.

Both are worth running. They disagree, and the disagreement is information.

### Pinned tags versus floating tags

A pinned tag (`traefik:v3.7.9`) is behind when the registry holds a higher tag in
the same channel, which is a pure name comparison.

A floating tag (`:latest`, `:lts`, `:main`) never changes name — the digest under
it moves. Comparing names says nothing, so what gets compared is the digest the
kubelet actually started (`status.containerStatuses[].imageID`) against the digest
the tag points at now. A mismatch means the pod predates the tag and a restart
would change the software underneath it. **This only works in `--from-cluster`
mode**; from a GitHub runner there is nothing to compare a floating tag against,
and the report says exactly that rather than guessing.

### What counts as the same channel

Only tags with the same prefix, the same number of numeric components and the
same suffix are compared. So `15-alpine` is compared against `16-alpine`, but not
against `15.14-alpine` or `15.14` or `v15`.

This is deliberately conservative and it does under-report. `15-alpine` already
floats to the newest 15.x, so calling `15.14-alpine` an update would be noise, and
`3.24` is not an upgrade path for `v3.24` — it is a different naming scheme, and
almost certainly a different image.

Findings are then split by which component moved. A patch bump is a restart; a
major bump can be an irreversible data migration. `postgres:15-alpine` to
`18-alpine` is three `pg_upgrade` runs, and the volumes in this cluster have one
replica and no backup target, so it lands under a heading that says so.

### Two categories of finding to leave alone

**Internal registry.** `registry.internal.xboy.me/...` is skipped by design. Those
images are built by this platform's own CI, their tags are commit SHAs, and there
is no upstream to be behind. Skipping them also means the job needs no registry
credentials at all — every registry it does talk to issues a pull-scoped token
anonymously, so there is no secret in the workflow and none to leak.

**Chart-managed images.** Anything under `longhornio/`, `calico/`, `argoproj/` or
`kedacore/` is chosen by the chart that installed it. Editing the tag in a
running Deployment gets reverted by the next `helm upgrade`, or worse, pairs a new
sidecar with an old manager. Upgrade the chart and let it pick. The report cannot
tell these apart from the rest, so this is on you to notice.

### The weekly job

[`.github/workflows/image-updates.yml`](../.github/workflows/image-updates.yml)
runs the repo mode at 06:15 UTC on Mondays and rewrites a single issue titled
*Container image update report* in place. One issue, not one per run — its edit
history is the changelog, and there is nothing to close.

Weekly rather than daily deliberately: a report that is replaced before you have
had time to act on it is noise, and a week is long enough to work through the
list. `workflow_dispatch` is there for when you want an answer sooner.

It reports and stops. Nothing in this cluster gets upgraded by a schedule.

To get the cluster-mode answer, which the hosted runner cannot reach, run it
by hand from somewhere with a kubeconfig:

```bash
python3 scripts/check-image-updates.py --from-cluster --markdown /tmp/report.md
```

`--fail-on-updates` exits 1 when anything is behind, if you would rather have a
red check than an issue to read.
