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

## Hostnames here are placeholders — nothing in this repo applies verbatim

**This repo is public, so no real domain, hostname or subdomain is in it.** Every one is
written as `*.example.com`, or `*.example.org` for the organisation domain. The live values
exist only on the hosts and in the cluster; `kubectl get ingress -A` and
`docker inspect`/`docker exec` on the box are the sources of truth.

This is not limited to Ingress hosts. The placeholder appears anywhere a name would have
been, and in several places it is **load-bearing** — the file is wrong until you substitute:

| file | what breaks if applied as-is |
| --- | --- |
| every `*ingress*.yaml` | the live host is replaced; pod healthy, Ingress green, service off the internet |
| `amd64-srv/k8s/bugsnik/bugsink-backup-cronjob.yaml`, `arm64-srv/k8s/vault-warden/s3-backup-job.yaml` | placeholder **registry** in the image ref → `ImagePullBackOff`, i.e. backups quietly stop |
| `arm64-srv/docker/traefik/docker-compose.yml` | dashboard router answers on a name nothing resolves |
| `arm64-srv/docker/adguard/AdGuardHome.seed.yaml` | the `*.internal` rewrite matches no name, so nothing internal resolves |
| `arm64-srv/docker/homepage/config/services.yaml` | every tile 404s |
| `amd64-srv/k8s/bugsnik/bugsink-config.yaml` | `DEFAULT_FROM_EMAIL` on a domain that does not exist (inert while `EMAIL_HOST` is blank) |

Each of those carries the substitution recipe in its own header. The pattern, as used in
[`amd64-srv/k8s/bugsnik/README.md`](./amd64-srv/k8s/bugsnik/README.md):

```bash
sed 's/bugsink\.example\.com/<the real host>/g' "$f" | kubectl apply -f -
```

Note what these failures have in common: **every one of them is silent.** Nothing reports
unhealthy, so the only reliable habit is `kubectl diff -f` (or `docker inspect`) before the
change, and reading the diff for a hostname you did not mean to touch.

So: **apply the files you changed, never the directory, unless you have checked it holds no
Ingress.** `kubectl diff -f <dir>/` catches the other direction too, since a tag bumped in
git may never have been applied (loki was two patch releases behind its own manifest for a
week; grafana still is a minor behind, deliberately left for a human because a Grafana minor
migrates its SQLite database and does not migrate back).

The vaultwarden ingress is worse than a rewrite: the live object is named
`password-manager` and the file declares `ingress`, so applying it adds a *second* Ingress
rather than replacing the first.

When you add a file here, add the placeholder, not the name. `git grep -nE 'example\.(com|org)'`
should be the only thing that matches a domain in this tree.

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