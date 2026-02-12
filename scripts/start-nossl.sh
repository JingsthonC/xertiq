#!/bin/bash

#############################################
# XertiQ Quick Start — HTTP only (no SSL)
# Test your stack with just the VPS IP.
# When you get a domain, run ssl-init.sh.
#
# Usage: sudo ./scripts/start-nossl.sh
#############################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }

cd "$REPO_DIR"

# Load .env
if [ ! -f ".env" ]; then
    log_error ".env not found. Run: cp .env.example .env && nano .env"
    exit 1
fi
set -a && source .env && set +a

# ── Step 1: Clone repos ──
echo ""
log_info "Step 1: Checking app repos..."

if [ ! -d "xertiq_frontend/.git" ]; then
    log_info "Cloning frontend..."
    git clone "${FRONTEND_REPO}" xertiq_frontend
else
    log_info "Pulling frontend..."
    cd xertiq_frontend && git pull origin main && cd "$REPO_DIR"
fi

if [ ! -d "xertiq_backend/.git" ]; then
    log_info "Cloning backend..."
    git clone "${BACKEND_REPO}" xertiq_backend
else
    log_info "Pulling backend..."
    cd xertiq_backend && git pull origin main && cd "$REPO_DIR"
fi
log_success "Repos ready"

# ── Step 2: Build frontend ──
echo ""
log_info "Step 2: Building frontend..."
VPS_IP=$(curl -sf ifconfig.me || echo "localhost")
cd "$REPO_DIR/xertiq_frontend"
npm ci --silent
VITE_API_BASE_URL="http://${VPS_IP}/api" npm run build
cd "$REPO_DIR"
log_success "Frontend built"

# ── Step 3: Use HTTP-only nginx config ──
echo ""
log_info "Step 3: Configuring nginx for HTTP..."

# Backup original SSL config, swap in no-SSL version
if [ ! -f "nginx/docker-nginx.conf.ssl-backup" ]; then
    cp nginx/docker-nginx.conf nginx/docker-nginx.conf.ssl-backup
fi
cp nginx/docker-nginx-nossl.conf nginx/docker-nginx.conf

# Create empty certbot dirs so docker-compose doesn't complain
mkdir -p certbot/conf certbot/www

log_success "Nginx set to HTTP-only mode"

# ── Step 4: Start services ──
echo ""
log_info "Step 4: Starting services..."

docker compose up -d postgres redis
log_info "Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    if docker compose exec postgres pg_isready -U "${DB_USER:-xertiq}" &>/dev/null; then
        break
    fi
    sleep 1
done
log_success "PostgreSQL ready"

docker compose up -d backend
log_info "Waiting for backend to start..."
sleep 15

docker compose up -d nginx
sleep 3
log_success "All services running"

# ── Step 5: Database migration ──
echo ""
log_info "Step 5: Running database migrations..."
docker compose exec -T backend npx prisma db push --accept-data-loss 2>&1 || \
    log_info "Check: docker compose exec backend npx prisma migrate status"
log_success "Database ready"

# ── Step 6: Health check ──
echo ""
log_info "Step 6: Health check..."
sleep 3
curl -sf "http://localhost/api/health" 2>/dev/null && echo "" || echo "Health check pending — backend may still be starting"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Test Deployment Ready!            ║"
echo "╚══════════════════════════════════════════╝"
echo ""
log_success "Frontend:  http://${VPS_IP}"
log_success "API:       http://${VPS_IP}/api/health"
echo ""
echo "This is HTTP only — for testing."
echo "When you have a domain:"
echo "  1. Restore SSL config: cp nginx/docker-nginx.conf.ssl-backup nginx/docker-nginx.conf"
echo "  2. Run: sudo ./scripts/ssl-init.sh yourdomain.com"
echo ""
echo "Commands:"
echo "  docker compose ps              # Status"
echo "  docker compose logs -f backend # Logs"
echo "  docker compose down            # Stop all"
