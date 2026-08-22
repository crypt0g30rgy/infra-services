# Infra Services

## Description

infra services is a repo that hosts services running in my homelab/production servers.

## Keeping images current

[`scripts/check-image-updates.py`](./scripts/README.md) reports which container
images are behind upstream, either from the tags declared here or from what is
actually running in the cluster. A scheduled workflow runs it weekly and keeps the
answer in one issue; it never bumps a tag by itself.