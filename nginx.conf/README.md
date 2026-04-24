# nginx.conf/

Nginx reverse-proxy config for the Kiln ATS EC2 host. Subdomain-split:
`api.kilnai.io` → Go backend, `app.kilnai.io` → Next.js, everything else
is silently dropped.

## Layout

```
nginx.conf/
├── nginx.conf                       # main: events, http, includes, trusts CF IPs
├── conf.d/
│   ├── upstreams.conf               # kiln_backend + kiln_frontend pools
│   ├── api.kilnai.io.conf           # api subdomain → backend (public API entry)
│   ├── app.kilnai.io.conf           # app subdomain → Next.js
│   └── default-reject.conf          # catch-all (Host != api/app) → 444
└── snippets/
    ├── kiln-backend.conf            # routes for api.* (backend team owns)
    ├── kiln-frontend.conf           # routes for app.* (frontend team owns)
    ├── proxy-common.conf            # shared X-Forwarded-* headers + timeouts
    ├── security-headers.conf        # XFO, nosniff, referrer-policy
    ├── cloudflare-real-ip.conf      # trust CF edges, restore real client IP
    └── tls-example.conf             # reference :443 block for CF origin cert / certbot
```

**Why routing is split across snippets:** `location{}` must live inside
`server{}`, and files auto-included from `conf.d/` are parsed at `http{}`
context. Putting route rules in `snippets/` and including them from each
per-subdomain server block lets each team own its routing independently.

## Architecture

```
            https://app.kilnai.io                https://api.kilnai.io
                    │                                       │
                    ▼                                       ▼
            ┌──────────────────┐                    ┌──────────────────┐
            │   Cloudflare     │ ◄── TLS terminates ┤   Cloudflare     │
            │   (Flexible)     │                    │   (Flexible)     │
            └────────┬─────────┘                    └────────┬─────────┘
                     │ HTTP :80                              │ HTTP :80
                     ▼                                       ▼
            ┌──────────────────────────────────────────────────────┐
            │            EC2 — nginx (ports 80/443)                │
            │   SG allows :80/:443 from Cloudflare IPv4 only       │
            └────────┬─────────────────────────────────┬───────────┘
                     │                                 │
                     │ server_name = app.kilnai.io     │ server_name = api.kilnai.io
                     ▼                                 ▼
            ┌──────────────────┐              ┌──────────────────┐
            │  Next.js :3000   │──── /api ───▶│  Go + Fiber :8080│
            │  (SSR + proxy)   │  127.0.0.1   │                  │
            └──────────────────┘              └──────────────────┘
```

Browser requests for `/api/*` hit the **Next.js** process on `app.*`,
which proxies server-side to the Go backend on `127.0.0.1:8080`. Real
backend endpoints are never exposed to the browser via this subdomain.

`api.kilnai.io` is the public entry for non-browser clients:
OAuth callbacks, Chrome extension, webhooks, future mobile apps.

Anything else (`kilnai.io`, `www.kilnai.io`, random subdomain scans,
direct-IP probes) → `444` close connection, logged under `rejected.access.log`.

## What's enabled

- **Multi-worker** (`worker_processes auto`) + **epoll** + `multi_accept on`
- **Upstream pools** with `least_conn` + keepalive (32 idle conns/worker)
- **Cloudflare real-IP restore** via `CF-Connecting-IP` (at `http{}` level)
- **Per-subdomain access logs** (`api.kilnai.io.access.log`, `app.kilnai.io.access.log`, `rejected.access.log`)
- **Gzip**, 25 MB upload cap (CV / PDF), sensible timeouts
- **Next.js cache headers**: `/_next/static/*` → 1 y immutable, `/_next/image` → 1 d
- **Health** at `/nginx-health` on each subdomain for CF health checks

## Deploying to the EC2

### First install

```bash
sudo apt update && sudo apt install -y nginx         # Ubuntu
# OR
sudo dnf install -y nginx                            # AL2023

# Back up distro defaults
sudo mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
sudo mv /etc/nginx/conf.d     /etc/nginx/conf.d.orig     2>/dev/null || true
sudo mv /etc/nginx/snippets   /etc/nginx/snippets.orig   2>/dev/null || true

# Symlink this repo into place
REPO=/home/ubuntu/kiln-deployment
sudo ln -sf "$REPO/nginx.conf/nginx.conf" /etc/nginx/nginx.conf
sudo ln -sf "$REPO/nginx.conf/conf.d"     /etc/nginx/conf.d
sudo ln -sf "$REPO/nginx.conf/snippets"   /etc/nginx/snippets

sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

### After editing any config

```bash
cd ~/kiln-deployment
git pull
sudo nginx -t && sudo systemctl reload nginx
```

`reload` does a zero-downtime swap. If `nginx -t` fails, **don't reload** —
fix the error first.

## Cloudflare DNS setup

Both subdomains must be proxied (orange cloud):

| Type | Name | Content           | Proxy |
|------|------|-------------------|-------|
| A    | api  | 13.213.59.10      | ✅    |
| A    | app  | 13.213.59.10      | ✅    |

Cloudflare SSL/TLS setting: **Flexible** (user → CF via HTTPS,
CF → origin via HTTP). Upgrade to **Full (strict)** + a CF-issued
**Origin Certificate** later for end-to-end encryption without
managing Let's Encrypt.

## Typical tweaks

### Adding a subdomain

Copy `conf.d/api.kilnai.io.conf`, change `server_name`, change the
`include` target, reload.

### Scaling backend horizontally

Open `conf.d/upstreams.conf`, uncomment the commented `server` lines.
Run additional backend containers on :8081, :8082, etc. via
`deploy.sh`. `least_conn` load-balances automatically.

### Pointing the catch-all to a landing page

In `conf.d/default-reject.conf`, swap:

```nginx
return 444;
```

for

```nginx
return 301 https://kilnai.io$request_uri;
```

## Performance notes

- `worker_processes auto` = 4 workers on `t3.xlarge` × 4096 conns = **16 384 concurrent connections** headroom.
- `keepalive` to upstream avoids a TCP handshake on every API call.
- Next.js hashed assets get 1-year `immutable` cache — dramatic page-speed win for returning visitors.

## What's NOT in here (by design)

- **Rate limiting** — add when abuse shows up. Cloudflare can cover this at the edge.
- **WAF** — Cloudflare's WAF is the right layer.
- **TLS on origin** — Cloudflare Flexible is simpler for now. See `snippets/tls-example.conf` for the upgrade path.
