# Infra Services

## Description

infra services is a repo that hosts services running in my homelab/production servers.

## Layout

```
arm64-srv/     the arm64 node: control plane, most compose stacks, cluster manifests
amd64-srv/     the amd64 node: worker, host-specific compose stacks
incidents/     what broke, why, and what was changed because of it
maintenance/   planned changes: what was upgraded, what it diverged from, how to revert
scripts/       repo tooling
Infra.md       both nodes' specs, roles and current headroom
k8s.md         MicroK8s setup notes
k8s-cli-usage.md
```

Top-level directories are named by **architecture**, not by vendor: the hardware
behind each node has changed before and the paths should not have to change with
it. Each node directory has a `README.md` listing what is deployed there and what
is only kept for reference — anything not deployed also says so in its own files,
so a stale manifest cannot be mistaken for a live one.

## Hostnames here are placeholders, so `apply -f <dir>/` is not safe

Every Ingress in this repo carries an `*.example.com` host, because this repo is public and
the real names are not in it. The live values are the `.example.com` (and `example.org`,
`example.net`) names in `kubectl get ingress -A`. That makes a directory-wide apply a
foot-gun: `kubectl apply -f amd64-srv/k8s/monitoring/grafana/` rewrites the live host to
`grafana.example.com` and takes Grafana off the internet, with a healthy pod and a green
Ingress object the whole time.

So: **apply the files you changed, never the directory, unless you have checked it holds no
Ingress.** `kubectl diff -f <dir>/` before every apply is the habit that catches this — and
it catches the other direction too, since a tag bumped in git may never have been applied
(loki was two patch releases behind its own manifest for a week; grafana still is a minor
behind, deliberately left for a human because a Grafana minor migrates its SQLite database
and does not migrate back).

The vaultwarden ingress is worse than a rewrite: the live object is named
`password-manager` and the file declares `ingress`, so applying it adds a *second* Ingress
rather than replacing the first.

## Keeping images current

[`scripts/check-image-updates.py`](./scripts/README.md) reports which container
images are behind upstream, either from the tags declared here or from what is
actually running in the cluster. A scheduled workflow runs it weekly and keeps the
answer in one issue; it never bumps a tag by itself.

In-cluster components — MetalLB, ArgoCD, Longhorn, KEDA — are not upgraded by
editing a tag: each is owned by something (a MicroK8s addon, plain manifests, a
Helm release, an ArgoCD Application with `selfHeal`) that decides how it may be
changed and what will be reverted. See
[`maintenance/2026-09-05-cluster-component-upgrades.md`](./maintenance/2026-09-05-cluster-component-upgrades.md),
which records the last round and the traps in each path.

A database major is not a tag edit either — PostgreSQL will not start on a data
directory written by an older major. The dump-and-restore procedure used for all
three servers, and everything that went wrong doing it, is in
[`maintenance/2026-09-05-postgres-15-to-18.md`](./maintenance/2026-09-05-postgres-15-to-18.md).