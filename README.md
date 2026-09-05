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