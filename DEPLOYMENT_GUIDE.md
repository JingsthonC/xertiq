# XertiQ Deployment Guide — Hostinger KVM2 VPS

**Stack:** Docker Compose + PostgreSQL 16 + Redis + Nginx + Let's Encrypt

**VPS Specs:** 2 vCPU, 8 GB RAM, 100 GB NVMe, Ubuntu 22.04/24.04

---

## Before You Start

You need:
- [ ] Hostinger KVM2 VPS (provisioned, powered on)
- [ ] A domain name (pointed to your VPS IP, or ready to configure)
- [ ] Your API keys ready: Solana private key, Pinata API key, etc.
- [ ] SSH access to your VPS (Hostinger provides this in hPanel)

---

## Step 1: SSH Into Your VPS

Go to **hPanel** > **VPS** > **Overview** to find your VPS IP address and root password.

```bash
ssh root@YOUR_VPS_IP
```

If this is your first time, accept the fingerprint prompt.

---

## Step 2: Update the System

```bash
apt update && apt upgrade -y
```

This updates all system packages. Takes 1-2 minutes.

---

## Step 3: Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

Verify it works:

```bash
docker --version
# Docker version 27.x.x

docker compose version
# Docker Compose version v2.x.x
```

---

## Step 4: Install Node.js 20

Needed to build the frontend on the server.

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
```

Verify:

```bash
node --version
# v20.x.x
```

---

## Step 5: Set Up Firewall

```bash
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

Verify:

```bash
ufw status
# Status: active
# To        Action    From
# --        ------    ----
# 22/tcp    ALLOW     Anywhere
# 80/tcp    ALLOW     Anywhere
# 443/tcp   ALLOW     Anywhere
```

---

## Step 6: Install fail2ban (Brute-Force Protection)

```bash
apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban
```

---

## Step 7: Clone Your Repository

```bash
cd /var/www
git clone https://github.com/YOUR_USERNAME/xertiq.git
cd xertiq
```

> If your repo is private, you'll need to set up a GitHub personal access token or SSH key first.

---

## Step 8: Configure Environment Variables

```bash
cp .env.example .env
nano .env
```

Fill in every value. Here's what each one does:

```env
# Your domain (NO https://, NO trailing slash)
DOMAIN=yourdomain.com
FRONTEND_URL=https://yourdomain.com
ADMIN_EMAIL=you@yourdomain.com

# Database — pick a strong password (the DB is created automatically by Docker)
DB_USER=xertiq
DB_PASSWORD=          # Generate: openssl rand -base64 32
DB_NAME=xertiq_db

# Auth — MUST be a long random string
JWT_SECRET=           # Generate: openssl rand -base64 64
JWT_EXPIRES_IN=7d

# Solana — your wallet private key (base58 encoded)
SOLANA_RPC_URL=https://api.devnet.solana.com
SOLANA_PRIVATE_KEY=   # From your Solana wallet

# Pinata (IPFS storage)
PINATA_API_KEY=       # From pinata.cloud dashboard
PINATA_SECRET_API_KEY=

# Payments (leave blank if not using yet)
STRIPE_SECRET_KEY=
PAYMONGO_SECRET_KEY=

# Email (leave blank if not using yet)
RESEND_API_KEY=
```

To generate passwords/secrets right in the terminal:

```bash
# Generate DB password
openssl rand -base64 32

# Generate JWT secret
openssl rand -base64 64
```

Save and exit nano: `Ctrl+O`, `Enter`, `Ctrl+X`

---

## Step 9: Point Your Domain to the VPS

Go to your domain registrar (or Hostinger hPanel if domain is with Hostinger):

1. Find **DNS Settings** or **DNS Zone Editor**
2. Add or edit an **A Record**:
   - **Name:** `@` (for root domain) or a subdomain like `app`
   - **Value:** Your VPS IP address (e.g., `154.12.xxx.xxx`)
   - **TTL:** 3600 (or "Auto")
3. If you also want `www`, add another A record with Name: `www`

Wait 5-15 minutes for DNS to propagate. Verify:

```bash
# Run this from your VPS
apt install -y dnsutils
dig yourdomain.com +short
# Should show your VPS IP
```

---

## Step 10: Deploy Everything

This single command handles SSL, frontend build, database setup, and service startup:

```bash
cd /var/www/xertiq
./scripts/ssl-init.sh
```

The script will:
1. Validate your `.env` configuration
2. Set your domain in the Nginx config
3. Build the React frontend
4. Create a temporary SSL certificate (so Nginx can start)
5. Start PostgreSQL, Redis, and the backend
6. Get a real Let's Encrypt SSL certificate
7. Reload Nginx with the real certificate
8. Run database migrations

This takes about 3-5 minutes. Watch for any red `[FAIL]` messages.

---

## Step 11: Verify Everything Works

```bash
# Check all containers are running and healthy
docker compose ps
```

You should see something like:

```
NAME               STATUS           PORTS
xertiq-nginx       Up (healthy)     0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
xertiq-backend-1   Up (healthy)     3000/tcp
xertiq-backend-2   Up (healthy)     3000/tcp
xertiq-postgres    Up (healthy)     5432/tcp
xertiq-redis       Up (healthy)     6379/tcp
xertiq-certbot     Up
```

Test the endpoints:

```bash
# API health check (should return JSON with status: "OK")
curl https://yourdomain.com/api/health

# Frontend (should return HTML)
curl -s https://yourdomain.com | head -5
```

Open in your browser:
- `https://yourdomain.com` — Frontend should load
- `https://yourdomain.com/dashboard` — SPA routing should work (no 404)
- `https://yourdomain.com/api/health` — API health check

---

## Step 12: Seed Initial Data (Optional)

If you want to create a Super Admin account or seed test data:

```bash
docker compose exec backend node prisma/seed.js
```

---

## You're Done!

Your XertiQ instance is now live at `https://yourdomain.com`

---

## Day-to-Day Operations

### View Logs

```bash
# Backend logs (most useful)
docker compose logs -f backend

# Nginx access/error logs
docker compose logs -f nginx

# PostgreSQL logs
docker compose logs -f postgres

# All logs
docker compose logs -f
```

### Restart Services

```bash
# Restart just the backend
docker compose restart backend

# Restart everything
docker compose restart

# Full stop + start
docker compose down && docker compose up -d
```

### Update After Code Changes

```bash
cd /var/www/xertiq

# Pull latest code
git pull origin main

# Rebuild frontend
cd xertiq_frontend && npm ci && VITE_API_BASE_URL="https://yourdomain.com/api" npm run build && cd ..

# Rebuild and restart backend (zero-downtime)
docker compose up -d --build

# Run any new migrations
docker compose exec backend npx prisma db push
```

### Database Operations

```bash
# Open PostgreSQL shell
docker compose exec postgres psql -U xertiq xertiq_db

# Backup database
docker compose exec postgres pg_dump -U xertiq xertiq_db | gzip > backups/xertiq_$(date +%Y%m%d).sql.gz

# Restore from backup
gunzip -c backups/xertiq_20260212.sql.gz | docker compose exec -T postgres psql -U xertiq xertiq_db

# Check database size
docker compose exec postgres psql -U xertiq xertiq_db -c "SELECT pg_size_pretty(pg_database_size('xertiq_db'));"
```

### Monitor Resources

```bash
# Container resource usage
docker stats --no-stream

# Disk usage
df -h /
docker system df

# Clean unused Docker images/volumes (saves disk space)
docker system prune -f
```

### SSL Certificate

SSL auto-renews via the Certbot container (checks every 12 hours). To manually renew:

```bash
docker compose run --rm certbot renew
docker compose exec nginx nginx -s reload
```

---

## Troubleshooting

### Container won't start

```bash
# Check what failed
docker compose ps -a
docker compose logs backend   # or whichever service failed
```

### "502 Bad Gateway"

Backend isn't running or hasn't started yet.

```bash
docker compose logs backend
# Look for startup errors (DB connection, missing env vars, etc.)
```

### Database connection refused

```bash
docker compose ps postgres
# If not healthy, check logs:
docker compose logs postgres
```

### Frontend shows blank page

```bash
# Check if frontend was built
ls -la xertiq_frontend/dist/index.html

# Check nginx logs
docker compose logs nginx
```

### SSL certificate errors

```bash
# Check cert files exist
ls certbot/conf/live/yourdomain.com/

# Re-request certificate
docker compose run --rm certbot certonly \
  --webroot --webroot-path=/var/www/certbot \
  -d yourdomain.com --email you@email.com \
  --agree-tos --no-eff-email --force-renewal

docker compose exec nginx nginx -s reload
```

### Out of disk space

```bash
# Check disk usage
df -h /

# Clean Docker (removes unused images, build cache)
docker system prune -af
docker volume prune -f   # WARNING: removes unused volumes (not active ones)
```

### Need to start completely fresh

```bash
cd /var/www/xertiq
docker compose down -v   # -v removes volumes (DELETES DATABASE!)
# Reconfigure nginx domain placeholder if needed
git checkout nginx/docker-nginx.conf
./scripts/ssl-init.sh
```

---

## Architecture on KVM2

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────┐
│  Hostinger KVM2 VPS (2 vCPU / 8GB RAM)          │
│                                                   │
│  ┌─────────┐                                     │
│  │  Nginx   │ :80 → redirect to :443             │
│  │  (proxy) │ :443 → SSL termination             │
│  └────┬─────┘                                     │
│       │                                           │
│       ├── /api/*  ──→  ┌──────────────────┐      │
│       │                │  Backend ×2       │      │
│       │                │  (Node.js/Express)│      │
│       │                └───────┬──────────┘      │
│       │                        │                  │
│       │                ┌───────┴──────────┐      │
│       │                │ PostgreSQL 16     │      │
│       │                │ Redis 7           │      │
│       │                └──────────────────┘      │
│       │                                           │
│       └── /*  ──→  Static files (React SPA)      │
│                                                   │
│  ┌──────────┐                                    │
│  │ Certbot  │ Auto-renews SSL every 12h          │
│  └──────────┘                                    │
└──────────────────────────────────────────────────┘
```

**Estimated memory usage:**

| Service | RAM |
|---------|-----|
| PostgreSQL 16 | ~300 MB |
| Redis | 256 MB (capped) |
| Nginx | ~10 MB |
| Backend x2 | ~500 MB each = 1 GB |
| Docker engine | ~200 MB |
| OS + buffers | ~500 MB |
| **Total** | **~2.3 GB** |
| **Free** | **~5.7 GB** |
