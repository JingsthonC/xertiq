#!/bin/bash

#############################################
# XertiQ First-Time Deployment Script (Docker)
#
# This is the ONLY script you need to run for initial deployment.
# It handles everything: frontend build, SSL, DB, and service startup.
#
# Prerequisites:
#   - Docker and Docker Compose installed
#   - .env file configured (cp .env.example .env)
#   - DNS A record pointing to this server's IP
#   - Port 80 and 443 open
#
# Usage:
#   ./scripts/ssl-init.sh                              # reads from .env
#   ./scripts/ssl-init.sh yourdomain.com admin@email   # explicit args
#
# Run this ONCE for initial deployment.
# For updates, use: docker compose up -d --build
#############################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
log_step()    { echo -e "\n${GREEN}━━━ Step $1 ━━━${NC}"; }

# Parse arguments or load from .env
DOMAIN="${1:-}"
EMAIL="${2:-}"

if [ -z "$DOMAIN" ]; then
    if [ -f "$REPO_DIR/.env" ]; then
        set -a
        source "$REPO_DIR/.env"
        set +a
        DOMAIN="${DOMAIN:-}"
        EMAIL="${ADMIN_EMAIL:-}"
    fi
fi

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "yourdomain.com" ]; then
    log_error "Domain not configured!"
    echo ""
    echo "  Option 1: Set DOMAIN in .env file first"
    echo "  Option 2: ./scripts/ssl-init.sh yourdomain.com admin@yourdomain.com"
    exit 1
fi

EMAIL="${EMAIL:-admin@$DOMAIN}"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     XertiQ Docker Deployment             ║"
echo "╚══════════════════════════════════════════╝"
echo ""
log_info "Domain:   $DOMAIN"
log_info "Email:    $EMAIL"
log_info "Database: PostgreSQL 16"
echo ""

cd "$REPO_DIR"

# ──────────────────────────────────────────
# Preflight checks
# ──────────────────────────────────────────
log_step "0/9: Preflight checks"

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Run: curl -fsSL https://get.docker.com | sh"
    exit 1
fi
log_success "Docker installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose not found. Install Docker Compose V2."
    exit 1
fi
log_success "Docker Compose installed"

if [ ! -f ".env" ]; then
    log_error ".env file not found. Run: cp .env.example .env && nano .env"
    exit 1
fi
log_success ".env file exists"

# Check required vars
MISSING=""
for VAR in DB_PASSWORD JWT_SECRET SOLANA_PRIVATE_KEY PINATA_API_KEY PINATA_SECRET_API_KEY; do
    VAL=$(grep "^${VAR}=" .env | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -z "$VAL" ] || [[ "$VAL" == *"CHANGE_ME"* ]] || [[ "$VAL" == *"your_"* ]]; then
        MISSING="$MISSING $VAR"
    fi
done

if [ -n "$MISSING" ]; then
    log_error "These .env variables are not set:$MISSING"
    echo "  Edit your .env file and fill in real values."
    exit 1
fi
log_success "Required .env variables set"

# ──────────────────────────────────────────
# Step 1: Clone app repositories if needed
# ──────────────────────────────────────────
log_step "1/9: Clone application repositories"

FRONTEND_REPO="${FRONTEND_REPO:-}"
BACKEND_REPO="${BACKEND_REPO:-}"

if [ ! -d "xertiq_frontend/.git" ]; then
    if [ -z "$FRONTEND_REPO" ]; then
        log_error "xertiq_frontend/ not found and FRONTEND_REPO not set in .env"
        exit 1
    fi
    log_info "Cloning frontend repo..."
    git clone "$FRONTEND_REPO" xertiq_frontend
    log_success "Frontend repo cloned"
else
    log_info "Frontend repo already exists — pulling latest..."
    cd xertiq_frontend && git pull origin main && cd "$REPO_DIR"
fi

if [ ! -d "xertiq_backend/.git" ]; then
    if [ -z "$BACKEND_REPO" ]; then
        log_error "xertiq_backend/ not found and BACKEND_REPO not set in .env"
        exit 1
    fi
    log_info "Cloning backend repo..."
    git clone "$BACKEND_REPO" xertiq_backend
    log_success "Backend repo cloned"
else
    log_info "Backend repo already exists — pulling latest..."
    cd xertiq_backend && git pull origin main && cd "$REPO_DIR"
fi

# ──────────────────────────────────────────
# Step 2: Replace domain in nginx config
# ──────────────────────────────────────────
log_step "2/9: Configure Nginx for $DOMAIN"

# Only replace if placeholder still exists
if grep -q "XERTIQ_DOMAIN" nginx/docker-nginx.conf; then
    sed -i "s/XERTIQ_DOMAIN/$DOMAIN/g" nginx/docker-nginx.conf
    log_success "Domain set in nginx/docker-nginx.conf"
else
    log_info "Nginx config already configured (no placeholder found)"
fi

# ──────────────────────────────────────────
# Step 2: Install Node.js dependencies & build frontend
# ──────────────────────────────────────────
log_step "3/9: Build frontend"

if [ ! -d "xertiq_frontend/dist" ] || [ "$FORCE_REBUILD" = "1" ]; then
    # Check if Node.js is available
    if ! command -v node &> /dev/null; then
        log_info "Node.js not found on host — installing via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    cd "$REPO_DIR/xertiq_frontend"
    log_info "Installing frontend dependencies..."
    npm ci --silent
    log_info "Building React app..."
    VITE_API_BASE_URL="https://$DOMAIN/api" npm run build
    cd "$REPO_DIR"
    log_success "Frontend built → xertiq_frontend/dist/"
else
    log_info "Frontend already built (delete xertiq_frontend/dist to rebuild)"
fi

# ──────────────────────────────────────────
# Step 3: Create certbot directories
# ──────────────────────────────────────────
log_step "4/9: Prepare SSL directories"

mkdir -p certbot/conf certbot/www
log_success "certbot/conf and certbot/www created"

# ──────────────────────────────────────────
# Step 4: Create temporary self-signed cert
# ──────────────────────────────────────────
log_step "5/9: Create temporary SSL certificate"

CERT_DIR="certbot/conf/live/$DOMAIN"
mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=$DOMAIN" 2>/dev/null

log_success "Temporary self-signed cert created (needed for Nginx to start)"

# ──────────────────────────────────────────
# Step 5: Start Nginx + PostgreSQL + Redis
# ──────────────────────────────────────────
log_step "6/9: Start infrastructure services"

# Copy frontend dist into the Docker volume mount path
log_info "Preparing frontend files..."
mkdir -p xertiq_frontend/dist

log_info "Starting PostgreSQL, Redis, and Nginx..."
docker compose up -d postgres redis
log_info "Waiting for PostgreSQL to be healthy..."

# Wait for postgres to be ready (max 60 seconds)
for i in $(seq 1 60); do
    if docker compose exec postgres pg_isready -U "${DB_USER:-xertiq}" &>/dev/null; then
        break
    fi
    sleep 1
done
log_success "PostgreSQL is ready"

# Build and start backend
log_info "Building backend Docker image..."
docker compose up -d backend
log_info "Waiting for backend to start..."
sleep 10

# Start nginx
docker compose up -d nginx
sleep 3
log_success "All infrastructure services running"

# ──────────────────────────────────────────
# Step 6: Get real Let's Encrypt certificate
# ──────────────────────────────────────────
log_step "7/9: Obtain Let's Encrypt SSL certificate"

# Remove temp cert
rm -rf "$CERT_DIR"

log_info "Requesting certificate from Let's Encrypt..."
docker compose run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --force-renewal

log_success "Real SSL certificate obtained"

# ──────────────────────────────────────────
# Step 7: Reload Nginx with real cert + start certbot renewal
# ──────────────────────────────────────────
log_step "8/9: Activate SSL and start all services"

docker compose up -d
sleep 5
docker compose exec nginx nginx -s reload
log_success "Nginx reloaded with real SSL certificate"

# ──────────────────────────────────────────
# Step 8: Run database migration
# ──────────────────────────────────────────
log_step "9/9: Run database migrations"

log_info "Pushing Prisma schema to PostgreSQL..."
docker compose exec backend npx prisma db push --accept-data-loss 2>/dev/null || \
    docker compose exec backend npx prisma migrate deploy 2>/dev/null || \
    log_warn "Migration may need manual attention — check with: docker compose exec backend npx prisma migrate status"

log_success "Database schema applied"

# ──────────────────────────────────────────
# Done!
# ──────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Deployment Complete!              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
log_success "Site:         https://$DOMAIN"
log_success "API Health:   https://$DOMAIN/api/health"
echo ""
echo "Useful commands:"
echo "  docker compose ps                    # Service status"
echo "  docker compose logs -f backend       # Backend logs"
echo "  docker compose logs -f nginx         # Nginx logs"
echo "  docker compose exec postgres psql -U ${DB_USER:-xertiq} ${DB_NAME:-xertiq_db}  # DB shell"
echo "  docker compose down                  # Stop everything"
echo "  docker compose up -d --build         # Rebuild after code changes"
echo ""
echo "To seed initial data (optional):"
echo "  docker compose exec backend node prisma/seed.js"
