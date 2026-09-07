# 2026-09-07 — history rewritten: every commit SHA changed

`main` was rewritten with `git filter-repo` and force-pushed. **Every commit SHA in this
repo changed.** Nothing about the *content* changed: the tree at the new tip is
byte-identical to the tree at the old one (verified by comparing tree hashes, not by
eyeballing a diff).

## What you have to do

If you have a clone, **do not `git pull`.** Pulling merges the old history back in and undoes
the rewrite. Either re-clone, or reset onto the new history:

```bash
git fetch origin
git reset --hard origin/main          # your working tree will not change
git remote prune origin               # stale tracking refs keep old objects alive
git reflog expire --expire=now --all && git gc --prune=now
```

The same applies to any CI checkout with a persistent workspace.

## Why

Real hostnames had been committed. This repo is public and its convention is that no real
domain, hostname or subdomain appears in it — see [`../README.md`](../README.md),
"Hostnames here are placeholders". The working tree was corrected first (PR #24); this
rewrite removed the same strings from the 21 older commits that still carried them, in both
file contents and commit messages.

One commit was also reattributed: `Add Grafana + Loki monitoring stack…` (2026-07-07) had
been authored by a tool identity rather than by `crypt0g30rgy`. Since every SHA was changing
anyway, it was corrected in the same pass — doing it later would have cost a second rewrite
and a second force-push.

## What did not change, and what you should not assume

- **Content.** No file differs. If you had the old tip checked out, `git reset --hard` moves
  you to a new SHA with the same bytes.
- **Issues and pull requests.** They are untouched, and `git filter-repo` cannot reach them.
  A PR's diff view still renders the objects it was opened against.
- **Old SHAs cited elsewhere.** Any SHA of *this* repo written down outside it now points at
  nothing. Checked at the time: the hex strings in `maintenance/` and `incidents/` are PVC
  UUIDs and commits belonging to `xboy-k8s-infra`, a different repo, so nothing inside this
  tree went stale.

A rewrite does not un-publish anything that was already fetched, forked, or indexed. Treat
the internal naming scheme as public knowledge and make sure nothing depends on it being
secret; the point of the rewrite is to stop advertising it going forward, not to undo it.
