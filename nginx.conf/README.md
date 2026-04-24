# nginx.conf/

Nginx reverse-proxy config for the Kiln ATS EC2 host.

## Layout

```
nginx.conf/
├── nginx.conf                   # main: events, http, includes
├── conf.d/
│   ├── upstreams.conf           # kiln_backend + kiln_frontend pools
│   └── kiln.conf                # server block + routing
└── snippets/
    ├── proxy-common.conf        # shared X-Forwarded-* headers + timeouts
    ├── security-headers.conf    # XFO, nosniff, referrer-policy, HSTS (commented)
    ├── cloudflare-real-ip.conf  # trust CF edges, restore real client IP
    └── tls-example.conf         # reference :443 block for Cloudflare / certbot
```

## What it does

- **Multi-worker** (`worker_processes auto`) + **epoll** event model + `multi_accept on` — Linux high-throughput basics.
- **Two upstream pools** (`kiln_backend` :8080, `kiln_frontend` :3000) with `least_conn` load balancing and keepalive connection pools — ready to scale by adding `server` lines.
- **Routes**:
  - `/api/*` → backend
  - `/_next/static/*` → frontend with 1-year immutable cache
  - `/_next/image` → frontend with 1-day cache
  - everything else → frontend (Next.js SSR)
- **Healthcheck** at `/nginx-health` for external monitors.
- **Gzip**, 25 MB upload limit (CVs / PDFs), reasonable timeouts.

## Deploying to the EC2

### First install

```bash
# One-time: install nginx
sudo apt update && sudo apt install -y nginx       # Ubuntu
# OR
sudo dnf install -y nginx                          # AL2023

# Back up the distro defaults so you can always revert
sudo mv /etc/nginx/nginx.conf        /etc/nginx/nginx.conf.orig
sudo mv /etc/nginx/conf.d            /etc/nginx/conf.d.orig 2>/dev/null || true
sudo mv /etc/nginx/snippets          /etc/nginx/snippets.orig 2>/dev/null || true

# Symlink this repo's configs into place (so `git pull` == config update)
REPO=/home/ubuntu/kiln-deployment        # adjust for your path
sudo ln -sf "$REPO/nginx.conf/nginx.conf"       /etc/nginx/nginx.conf
sudo ln -sf "$REPO/nginx.conf/conf.d"           /etc/nginx/conf.d
sudo ln -sf "$REPO/nginx.conf/snippets"         /etc/nginx/snippets

# Validate before reloading — -t catches syntax errors
sudo nginx -t

# Apply
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

### After editing any config

```bash
cd ~/kiln-deployment
git pull
sudo nginx -t && sudo systemctl reload nginx
```

`reload` does a zero-downtime swap: old workers finish in-flight requests, new workers pick up new config. If `nginx -t` fails, **don't reload** — fix the error first.

## Typical tweaks

### Scaling backend horizontally

Open `conf.d/upstreams.conf`, uncomment the commented `server` lines, point them at extra backend instances (e.g. `127.0.0.1:8081`, `:8082`). Run another backend container on each port via `deploy.sh`, reload nginx.

### Adding a domain

Edit `conf.d/kiln.conf`, replace `server_name _;` with your domain:

```nginx
server_name kiln.example.com;
```

Reload.

### Enabling HTTPS

Two paths — pick one:

1. **Cloudflare in front** (recommended for first deploy). Point DNS at the EC2 in proxied mode ("orange cloud"). CF terminates TLS. Origin keeps plain HTTP. Include `snippets/cloudflare-real-ip.conf` in your server block so logs show real client IPs, not CF edges.

2. **Certbot direct on origin**. `sudo certbot --nginx -d kiln.example.com`. Certbot will add a :443 server block automatically; use `snippets/tls-example.conf` as a reference for the hand-tuned version.

### Noisy upstream errors

If you see `upstream prematurely closed connection` in logs, bump keepalive settings in `conf.d/upstreams.conf` — the `keepalive_timeout 60s` is aligned with Fiber's default so they shouldn't fight, but fiddle if needed.

## Performance notes

- `worker_processes auto` = one worker per vCPU. On `t3.xlarge` (4 vCPU) you get 4 workers × 4096 connections = **16 384 concurrent connections** cap. Plenty for 100 users.
- `sendfile on` + `tcp_nopush on` + `tcp_nodelay on` = standard kernel-level zero-copy + low-latency combo.
- `keepalive` to upstream (32 idle connections per worker) avoids a TCP handshake on every API call; big win when the browser fires 10–20 parallel requests on a page load.
- Next.js static assets are hashed (`/_next/static/<hash>/...`) — the 1-year `immutable` cache on those is safe and dramatic for returning-visitor page speed.

## What's NOT in here (by design)

- **Rate limiting** (`limit_req_zone`) — add when you start seeing abuse. Right now the ATS has known users, not public abuse risk.
- **WAF rules** — if needed, let Cloudflare handle it at the edge.
- **Metrics export** (`stub_status` or `vts`) — add when you care about nginx-level metrics. For now, access logs + `upstream_response_time` in the log format give enough.
