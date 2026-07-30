# Cloudflare Tunnel Integration

This document outlines the process of integrating a Kubernetes cluster with Cloudflare Tunnel using the `cloudflared` CLI. It also documents the current Cloudflare limitation when associating a tunnel with multiple DNS zones (domains).

---

# Prerequisites

* A Cloudflare account with Zero Trust enabled.
* One or more domains already added to Cloudflare.
* A named tunnel already created (or one to be created).
* `cloudflared` installed locally.
* Kubernetes deployment configured to use either:

  * Tunnel credentials (`credentials.json`), or
  * Tunnel token.

---

# Download the Latest cloudflared Binary

Always use the latest stable release.

## AMD64

```bash
curl -L -o cloudflared-linux-amd64 \
https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64

chmod +x cloudflared-linux-amd64
```

## ARM64

```bash
curl -L -o cloudflared-linux-arm64 \
https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64

chmod +x cloudflared-linux-arm64
```

Verify the version:

```bash
./cloudflared-linux-amd64 --version
```

---

# First Login

Authenticate against the first Cloudflare zone.

Example:

```bash
./cloudflared-linux-amd64 tunnel login
```

A browser window opens.

Select:

```
example.com
```

Cloudflare downloads:

```
~/.cloudflared/cert.pem
```

This certificate authorizes `cloudflared` to manage DNS records within the selected zone.

---

# Create or Reuse a Tunnel

Create a tunnel:

```bash
./cloudflared-linux-amd64 tunnel create tunnel-name
```

or list existing tunnels:

```bash
./cloudflared-linux-amd64 tunnel list
```

---

# Create DNS Routes for the First Domain

Associate both the root domain and wildcard with the tunnel.

```bash
./cloudflared-linux-amd64 tunnel route dns -f tunnel-name "*.example.com"

./cloudflared-linux-amd64 tunnel route dns -f tunnel-name "example.com"
```

Cloudflare creates CNAME records pointing to:

```
<tunnel-id>.cfargotunnel.com
```

---

# Cloudflare Multi-Domain Limitation

`cloudflared tunnel login` authorizes **only one Cloudflare zone at a time**.

The downloaded:

```
~/.cloudflared/cert.pem
```

contains authorization for the selected zone only.

Attempting to create DNS routes for another zone using the existing certificate may produce incorrect results, such as:

```
*.example.net.example.com
```

instead of:

```
*.example.net
```

This behavior occurs because `cloudflared` uses the currently authorized zone stored in `cert.pem`.

---

# Adding a Second Domain

To authorize another Cloudflare zone:

Delete the existing certificate:

```bash
rm ~/.cloudflared/cert.pem
```

Login again:

```bash
./cloudflared-linux-amd64 tunnel login
```

When prompted, select:

```
example.net
```

Cloudflare downloads a new:

```
~/.cloudflared/cert.pem
```

authorized for the second zone.

Now create the DNS routes:

```bash
./cloudflared-linux-amd64 tunnel route dns -f tunnel-name "*.example.net"

./cloudflared-linux-amd64 tunnel route dns -f tunnel-name "example.net"
```

The tunnel itself remains unchanged. Only the management certificate changes.

---

# Repeating for Additional Domains

Repeat the following process for every additional Cloudflare zone:

1. Remove `~/.cloudflared/cert.pem`.
2. Run `cloudflared tunnel login`.
3. Select the desired Cloudflare zone.
4. Create DNS routes for that zone.

Example:

```
example.org
```

```bash
rm ~/.cloudflared/cert.pem

./cloudflared-linux-amd64 tunnel login

./cloudflared-linux-amd64 tunnel route dns -f tunnel-name "*.example.org"

./cloudflared-linux-amd64 tunnel route dns -f tunnel-name "example.org"
```

---

# Deploying the Tunnel

Once all DNS records have been created, the tunnel can be deployed.

Credential-based deployment:

```yaml
tunnel: <tunnel-id>

credentials-file: /etc/cloudflared/creds/credentials.json
```

or token-based deployment:

```bash
cloudflared tunnel token tunnel-name
```

Either authentication method can be used by the Kubernetes deployment.

---

# Verifying DNS Routes

List configured DNS routes:

```bash
./cloudflared-linux-amd64 tunnel route dns list
```

Verify the tunnel:

```bash
./cloudflared-linux-amd64 tunnel list
```

Retrieve tunnel details:

```bash
./cloudflared-linux-amd64 tunnel info tunnel-name
```

---

# Notes

* A single Cloudflare Tunnel can serve hostnames from multiple Cloudflare zones.
* The limitation applies only to the `cloudflared tunnel login` management certificate (`cert.pem`), which is scoped to one zone at a time.
* DNS routes are permanent until deleted and remain associated with the tunnel regardless of which management certificate is currently in use.
* The tunnel credentials (`credentials.json`) and tunnel token are independent of `cert.pem`; deleting `cert.pem` does not affect an already running tunnel.
* It is recommended to perform all DNS route creation from a dedicated administration workstation rather than from within Kubernetes.
