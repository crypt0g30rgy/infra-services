# AdGuard Home

The LAN's DNS server, and the microk8s cluster's upstream resolver. CoreDNS runs
`forward . /etc/resolv.conf` and both nodes' `resolv.conf` is
`nameserver 192.168.0.59`, so every name a pod looks up that is not a cluster
name arrives here. So does every name every phone, laptop and TV on the LAN looks
up. It is also the only resolver for the pi itself — `192.168.0.59`'s own
`resolv.conf` points at `192.168.0.59`.

There is **no pi-hole**. `../pi-hole/docker-compose.yml` describes one, but no
such process runs and `192.168.0.99` does not answer. AdGuard is it.

```
pod → CoreDNS (1 replica, on dell-amd64-srv)
    → 192.168.0.59:53
    → docker-proxy (userspace UDP relay, because :53 is a published bridge port)
    → adguardhome (172.19.0.2:53)
    → DNS-over-HTTPS upstreams
```

## Is it reproducible from this directory?

It is now. It was not before, and the gap was not the config format — it was that
this directory did not describe the thing that runs.

The live deployment is `/home/w3b/adguard` on the pi (`docker compose` project
`adguard`, working dir recorded in the container's labels). **That directory is
not a checkout of this repo**, and neither is anything else under `/home/w3b`.
The compose file that was committed here described a *different* AdGuard: on a
macvlan network at `192.168.1.98`, with no published ports, no traefik labels and
no resource limits. Running `docker compose up -d` from the old committed version
would have produced a container the LAN cannot reach on an address in the wrong
/24, with nothing listening on `192.168.0.59:53` — i.e. it would have taken DNS
out for the whole cluster. `docker-compose.yml` here is now the transcription of
what actually runs; keep the two equal.

## What the state is

Two bind-mounted directories, and nothing else:

| Path | What | Tracked? |
| --- | --- | --- |
| `config/AdGuardHome.yaml` | the entire configuration, ~4 KB | no — `AdGuardHome.seed.yaml` is |
| `work/` | query log (417 MB), statistics, sessions, downloaded filter lists | no |

The container is disposable. `docker compose down && docker compose up -d` loses
nothing, and always has — that part was already reproducible. Upgrading is a tag
bump plus the same two commands; AdGuard migrates `AdGuardHome.yaml` in place and
bumps its `schema_version`.

## Rebuilding from nothing

```sh
git clone <this repo> && cd pi5-arm64/docker/adguard
printf 'ADGUARD_INTERNAL_HOST=adguard.internal.example.com\n' > .env
./manage.sh up
```

`up` is safe to run repeatedly. It creates the `internal` network if missing,
creates `config/` and `work/`, seeds `config/AdGuardHome.yaml` from
`AdGuardHome.seed.yaml` **only if there is no live config**, brings the container
up, and then queries `192.168.0.59:53` to prove the LAN address answers.

Two things a fresh rebuild does not carry, both on purpose:

- **The admin password.** `users[].password` in the seed is a placeholder bcrypt
  string. DNS serves normally; the web UI on `:3000` refuses every login until
  you paste the real hash in, or delete the whole `users:` block to get the setup
  wizard back. A rebuild that resolves names but cannot be logged into is the
  right way round, and the alternative is committing a password hash.
- **`.env`.** `*.env*` is gitignored repo-wide. It holds exactly one variable,
  the traefik router's `Host()`. Without it compose substitutes an empty string
  and traefik rejects the router — the DNS server still works.

## Why a seed file and not the real one

AdGuard Home owns `AdGuardHome.yaml`. It rewrites the file **in full, comments
stripped**, every time anything changes in the web UI and on every schema
migration, and it does so as root with mode 600. Bind-mounting a tracked file
into the container would mean a working tree that is permanently dirty, needs
sudo to read, and holds the admin hash. There is no read-only or declarative mode
and no reconcile loop — AdGuard is the writer, always.

So the split is: `AdGuardHome.seed.yaml` is curated, commented, and used to
build; the pi holds the running state.

```sh
./manage.sh diff   # every value that differs between the seed and the live file
./manage.sh pull   # print the live file (admin hash masked) to port changes from
```

`pull` deliberately prints rather than overwriting. Redirecting it over the seed
would work and would destroy every comment in it, including the four marked
`FIX`. Port intentional changes across by hand and `diff` until it is quiet.

**Nothing in git applies itself.** This is not ArgoCD. A change committed here
reaches the resolver when someone copies it to the pi and restarts the container.

## The flakiness, and the four changes in the seed

Cluster DNS failed intermittently: `getaddrinfo EAI_AGAIN` in the services,
`i/o timeout` from CoreDNS's forward plugin, always on public names, in bursts.
The cause was this file's rate limiter.

```yaml
ratelimit: 20
ratelimit_subnet_len_ipv4: 24
ratelimit_whitelist: []
```

Over-limit queries are **dropped**, not refused — the client gets no packet at
all, so CoreDNS waits, times out, and answers SERVFAIL. Nothing anywhere logs
"rate limited". And a `/24` bucket means every device on `192.168.0.0/24` shares
one 20 qps allowance, so a laptop syncing photos spends the cluster's DNS budget.
The last 20 000 query-log entries, by client:

```
6346  192.168.0.60   ← dell-amd64-srv, i.e. all of CoreDNS
4899  192.168.0.104
4364  192.168.0.9
2942  192.168.0.4
1016  192.168.0.6
 897  192.168.0.59   ← the pi resolving for itself
 555  192.168.0.2
```

Measured against `192.168.0.59` at `ratelimit: 20`:

| offered | failed | ok |
| --- | --- | --- |
| ~10 q/s | 0 | 60 |
| ~25 q/s | 17 | 43 |
| ~60 q/s | 40 | 20 |

Successes cap at 20/s, and AdGuard's own query log shows the same ceiling — its
busiest seconds contain exactly 20 entries. Only the ~1% of cluster lookups that
leave the cluster are exposed, which is why it reads as random flakiness rather
than an outage.

The seed changes four things, each marked `FIX` where it appears:

1. `ratelimit_subnet_len_ipv4: 24` → **`32`** — one bucket per address instead of
   one per LAN.
2. `ratelimit_whitelist: []` → **`[192.168.0.59, 192.168.0.60]`** — CoreDNS
   multiplexes the whole cluster through one source address, so even a per-host
   limit is the wrong shape for it.
3. A **second upstream** (`dns.quad9.net`). One upstream under `load_balance` is
   not redundancy; every cache miss was a single point of failure reached over
   DoH. Both are DoH, so filtering and privacy are unchanged.
4. `upstream_timeout: 10s` → **`2s`** — CoreDNS gives up on an upstream after
   about 2s, so a 10s budget here meant CoreDNS SERVFAILed first and the answer
   AdGuard was still waiting for arrived for nobody.

Not changed, but worth knowing when latency is the symptom: `cpus: "0.25"` in
`docker-compose.yml` is a quarter of a core for a resolver whose every cache miss
is a TLS handshake and an HTTP/2 round trip (~112 ms measured), `max_goroutines`
caps in-flight queries at 300, and `docker-proxy` copies every DNS packet in the
cluster through userspace because `:53` is a published bridge port rather than a
host-network listener.

### Applying it to the running instance

```sh
# on the pi, from /home/w3b/adguard
sudo cp config/AdGuardHome.yaml config/AdGuardHome.yaml.bak
# edit the four values, or paste the real admin hash into a copy of the seed
docker compose restart adguardhome
docker compose logs --tail=50 adguardhome
dig +short @192.168.0.59 example.com
```

A restart is a few seconds of LAN-wide DNS downtime. CoreDNS retries, so the
cluster rides it out; anything mid-lookup on the LAN sees one failure.

## Traps

- **Do not uncomment the macvlan block.** `setup-macvlan.sh` builds
  `pihole_macvlan` as `192.168.1.0/24` while `../pi-hole/docker-compose.yml`
  documents the same network name as `192.168.0.0/24`. The two have never
  agreed, which is the likeliest reason pi-hole never came up. An AdGuard on
  `192.168.1.98` is unreachable from `192.168.0.0/24`, and macvlan isolates the
  host from its own containers without the `macvlan-shim` interface anyway.
- **`dig version.bind chaos @192.168.0.59` timing out is not a fault.** It is
  `blocked_hosts` in the config. Do not use it as a health check.
- **`*.internal.example.com → 192.168.0.59` is a rewrite in this config**, and the
  cluster depends on it (MinIO at `local-s3.internal.example.com`, among others).
  CoreDNS also has a `hosts` entry pinning `local-s3` to the same address, added
  because the lookup used to time out intermittently — that was the rate limit
  above, not the rewrite.
- **`.env` is not optional** even though its absence does not stop DNS. Compose
  will happily substitute an empty `Host()`.
