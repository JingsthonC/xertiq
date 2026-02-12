#!/bin/bash

#############################################
# XertiQ VPS Deployment Script
# Tested on: Hostinger KVM2 (2 vCPU, 8GB RAM, Ubuntu 22.04/24.04)
#
# Usage:
#   ./deploy-vps.sh setup      - Initial VPS setup (Node, Nginx, PM2, MySQL, Redis)
#   ./deploy-vps.sh setup-db   - Create MySQL database and user
#   ./deploy-vps.sh ssl        - Setup Let's Encrypt SSL
#   ./deploy-vps.sh deploy     - Deploy/update application
#   ./deploy-vps.sh restart    - Restart services
#   ./deploy-vps.sh status     - Check service status
#   ./deploy-vps.sh logs       - View logs
#   ./deploy-vps.sh backup     - Backup database
#   ./deploy-vps.sh restore    - Restore database from backup
#############################################

set -e

# ===== Configuration =====
# Edit these OR set them in .env at the repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if it exists at repo root
if [ -f "$REPO_DIR/.env" ]; then
    set -a
    source "$REPO_DIR/.env"
    set +a
fi

DOMAIN="${DOMAIN:-xertiq.yourdomain.com}"
APP_DIR="${APP_DIR:-/var/www/xertiq}"
DB_NAME="${DB_NAME:-xertiq_db}"
DB_USER="${DB_USER:-xertiq}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@yourdomain.com}"
NODE_VERSION="${NODE_VERSION:-20}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This command must be run as root (use sudo)"
        exit 1
    fi
}

check_domain() {
    if [ "$DOMAIN" = "xertiq.yourdomain.com" ]; then
        log_error "Please set your DOMAIN first!"
        echo "  Option 1: Edit DOMAIN in this script"
        echo "  Option 2: Set DOMAIN in .env file"
        echo "  Option 3: DOMAIN=yourdomain.com ./deploy-vps.sh $1"
        exit 1
    fi
}

#############################################
# Setup - Initial VPS Configuration
#############################################
setup() {
    check_root
    log_info "Starting initial VPS setup for Hostinger KVM2..."

    # Update system
    log_info "Updating system packages..."
    apt-get update && apt-get upgrade -y

    # Install essential packages
    log_info "Installing essential packages..."
    apt-get install -y \
        curl \
        git \
        build-essential \
        nginx \
        certbot \
        python3-certbot-nginx \
        ufw \
        htop \
        fail2ban \
        jq

    # Install Node.js LTS
    log_info "Installing Node.js ${NODE_VERSION}.x..."
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
        apt-get install -y nodejs
    fi
    log_success "Node.js $(node --version) installed"

    # Install PM2 globally
    log_info "Installing PM2..."
    npm install -g pm2
    pm2 install pm2-logrotate
    pm2 set pm2-logrotate:max_size 50M
    pm2 set pm2-logrotate:retain 7
    log_success "PM2 installed"

    # Install MySQL
    log_info "Installing MySQL 8.0..."
    apt-get install -y mysql-server
    systemctl enable mysql
    systemctl start mysql
    log_success "MySQL installed"
    log_warn "Run 'mysql_secure_installation' manually to secure MySQL"

    # Install Redis
    log_info "Installing Redis..."
    apt-get install -y redis-server
    sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
    systemctl enable redis-server
    systemctl restart redis-server
    log_success "Redis installed and configured"

    # Create application directory
    log_info "Creating application directories..."
    mkdir -p "$APP_DIR"
    mkdir -p /var/log/pm2
    mkdir -p /var/www/certbot
    mkdir -p /var/www/xertiq/frontend

    # Configure UFW firewall
    log_info "Configuring firewall..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 'Nginx Full'
    ufw --force enable
    log_success "Firewall configured (SSH + HTTP/HTTPS)"

    # Configure fail2ban
    log_info "Configuring fail2ban..."
    systemctl enable fail2ban
    systemctl start fail2ban
    log_success "fail2ban configured"

    # Setup PM2 startup script
    log_info "Setting up PM2 startup..."
    pm2 startup systemd -u root --hp /root
    log_success "PM2 startup configured"

    log_success "=== Initial setup complete! ==="
    echo ""
    log_info "Next steps:"
    echo "  1. Run: mysql_secure_installation"
    echo "  2. Run: ./deploy-vps.sh setup-db"
    echo "  3. Configure .env file (copy from .env.example)"
    echo "  4. Clone repo to $APP_DIR"
    echo "  5. Run: ./deploy-vps.sh ssl"
    echo "  6. Run: ./deploy-vps.sh deploy"
}

#############################################
# Setup Database
#############################################
setup_db() {
    check_root
    log_info "Setting up MySQL database..."

    # Generate random password
    DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)

    # Create database user and database
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    log_success "Database created successfully!"
    echo ""
    echo "=========================================="
    echo "  DATABASE CREDENTIALS (SAVE THESE!)"
    echo "=========================================="
    echo "  Database: $DB_NAME"
    echo "  User:     $DB_USER"
    echo "  Password: $DB_PASSWORD"
    echo ""
    echo "  Add to your .env file:"
    echo "  DATABASE_URL=\"mysql://$DB_USER:$DB_PASSWORD@localhost:3306/$DB_NAME\""
    echo "=========================================="
}

#############################################
# Setup SSL with Let's Encrypt
#############################################
setup_ssl() {
    check_root
    check_domain "ssl"
    log_info "Setting up SSL certificate for $DOMAIN..."

    # Install nginx config (HTTP-only first for certbot)
    log_info "Installing temporary Nginx config for SSL provisioning..."

    cat > /etc/nginx/sites-available/xertiq <<NGINX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'XertiQ SSL setup in progress';
        add_header Content-Type text/plain;
    }
}
NGINX_EOF

    # Enable the site
    ln -sf /etc/nginx/sites-available/xertiq /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    # Test and reload nginx
    nginx -t
    systemctl reload nginx

    # Get SSL certificate
    log_info "Obtaining SSL certificate from Let's Encrypt..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"

    # Now install the full nginx config
    log_info "Installing full Nginx configuration..."
    cp "$APP_DIR/nginx/xertiq.conf" /etc/nginx/sites-available/xertiq
    sed -i "s/XERTIQ_DOMAIN/$DOMAIN/g" /etc/nginx/sites-available/xertiq

    # Test and reload
    nginx -t && systemctl reload nginx

    # Setup auto-renewal
    log_info "Setting up auto-renewal..."
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    fi

    log_success "SSL certificate installed for $DOMAIN"
}

#############################################
# Deploy Application
#############################################
deploy() {
    check_domain "deploy"
    log_info "Starting deployment..."

    cd "$APP_DIR"

    # Pull latest code
    log_info "Pulling latest code..."
    git pull origin main

    # ===== Backend =====
    log_info "Installing backend dependencies..."
    cd "$APP_DIR/xertiq_backend"
    npm ci

    # Generate Prisma client (prisma is in devDependencies, needs full install)
    log_info "Generating Prisma client..."
    npx prisma generate

    # Run database migrations
    log_info "Running database migrations..."
    npx prisma migrate deploy 2>/dev/null || npx prisma db push
    log_success "Backend ready"

    # ===== Frontend =====
    log_info "Building frontend..."
    cd "$APP_DIR/xertiq_frontend"
    npm ci
    VITE_API_BASE_URL="https://$DOMAIN/api" npm run build
    log_success "Frontend built"

    # Copy frontend build to nginx serving directory
    log_info "Deploying frontend to /var/www/xertiq/frontend/dist..."
    rm -rf /var/www/xertiq/frontend/dist
    cp -r dist /var/www/xertiq/frontend/
    log_success "Frontend deployed"

    # ===== Restart Services =====
    log_info "Restarting backend (zero-downtime reload)..."
    cd "$APP_DIR/xertiq_backend"

    # Create logs directory
    mkdir -p logs

    pm2 reload ecosystem.config.cjs --env production 2>/dev/null || \
        pm2 start ecosystem.config.cjs --env production

    # Save PM2 process list (survives reboot)
    pm2 save

    # Reload nginx
    log_info "Reloading nginx..."
    nginx -t && systemctl reload nginx

    log_success "=== Deployment complete! ==="
    echo ""
    log_info "Live at: https://$DOMAIN"
    log_info "Health:  https://$DOMAIN/api/health"
}

#############################################
# Restart Services
#############################################
restart() {
    log_info "Restarting services..."

    cd "$APP_DIR/xertiq_backend"
    pm2 reload ecosystem.config.cjs --env production
    systemctl reload nginx

    log_success "Services restarted"
}

#############################################
# Check Status
#############################################
status() {
    echo ""
    echo "=== System Resources ==="
    free -h | head -2
    echo ""
    echo "CPU cores: $(nproc)"
    echo ""

    echo "=== PM2 Status ==="
    pm2 status 2>/dev/null || echo "PM2 not running"
    echo ""

    echo "=== Nginx Status ==="
    systemctl status nginx --no-pager -l 2>/dev/null | head -5
    echo ""

    echo "=== MySQL Status ==="
    systemctl status mysql --no-pager -l 2>/dev/null | head -5
    echo ""

    echo "=== Redis Status ==="
    systemctl status redis-server --no-pager -l 2>/dev/null | head -5
    redis-cli ping 2>/dev/null || echo "Redis not responding"
    echo ""

    echo "=== API Health Check ==="
    curl -sf "http://localhost:3000/api/health" 2>/dev/null | jq . || echo "API not responding"
    echo ""

    echo "=== Disk Usage ==="
    df -h / | tail -1
}

#############################################
# View Logs
#############################################
logs() {
    LOG_TYPE=${1:-"all"}

    case $LOG_TYPE in
        pm2)
            pm2 logs xertiq-api --lines 100
            ;;
        nginx)
            tail -f /var/log/nginx/error.log /var/log/nginx/access.log
            ;;
        mysql)
            tail -f /var/log/mysql/error.log
            ;;
        all)
            log_info "Showing PM2 logs (use 'logs nginx' or 'logs mysql' for specific logs)"
            pm2 logs xertiq-api --lines 50
            ;;
        *)
            log_error "Unknown log type: $LOG_TYPE"
            echo "Usage: ./deploy-vps.sh logs [pm2|nginx|mysql|all]"
            ;;
    esac
}

#############################################
# Backup Database
#############################################
backup() {
    BACKUP_DIR="/var/backups/xertiq"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/xertiq_db_$TIMESTAMP.sql.gz"

    log_info "Creating database backup..."

    mkdir -p "$BACKUP_DIR"

    # Read DB credentials from .env if available
    if [ -f "$APP_DIR/xertiq_backend/.env" ]; then
        DB_URL=$(grep "^DATABASE_URL" "$APP_DIR/xertiq_backend/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        # Parse: mysql://user:pass@host:port/dbname
        PARSED_USER=$(echo "$DB_URL" | sed -n 's|mysql://\([^:]*\):.*|\1|p')
        PARSED_PASS=$(echo "$DB_URL" | sed -n 's|mysql://[^:]*:\([^@]*\)@.*|\1|p')
        PARSED_HOST=$(echo "$DB_URL" | sed -n 's|mysql://[^@]*@\([^:]*\):.*|\1|p')
        PARSED_DB=$(echo "$DB_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')

        mysqldump -u "$PARSED_USER" -p"$PARSED_PASS" -h "$PARSED_HOST" "$PARSED_DB" | gzip > "$BACKUP_FILE"
    else
        log_warn "No .env found, using interactive mode"
        mysqldump -u "$DB_USER" -p "$DB_NAME" | gzip > "$BACKUP_FILE"
    fi

    # Keep only last 7 backups
    ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm

    log_success "Backup created: $BACKUP_FILE"
    ls -lh "$BACKUP_FILE"

    echo ""
    log_info "Available backups:"
    ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "No backups found"
}

#############################################
# Restore Database
#############################################
restore() {
    BACKUP_FILE=$1

    if [ -z "$BACKUP_FILE" ]; then
        log_error "Please specify a backup file"
        echo "Usage: ./deploy-vps.sh restore /path/to/backup.sql.gz"
        echo ""
        log_info "Available backups:"
        ls -lh /var/backups/xertiq/*.sql.gz 2>/dev/null || echo "No backups found"
        exit 1
    fi

    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    log_warn "This will OVERWRITE the current database!"
    read -p "Are you sure? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    log_info "Restoring database from: $BACKUP_FILE"

    # Stop the application
    pm2 stop xertiq-api 2>/dev/null || true

    # Read DB credentials from .env
    if [ -f "$APP_DIR/xertiq_backend/.env" ]; then
        DB_URL=$(grep "^DATABASE_URL" "$APP_DIR/xertiq_backend/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        PARSED_USER=$(echo "$DB_URL" | sed -n 's|mysql://\([^:]*\):.*|\1|p')
        PARSED_PASS=$(echo "$DB_URL" | sed -n 's|mysql://[^:]*:\([^@]*\)@.*|\1|p')
        PARSED_HOST=$(echo "$DB_URL" | sed -n 's|mysql://[^@]*@\([^:]*\):.*|\1|p')
        PARSED_DB=$(echo "$DB_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')

        # Drop and recreate
        mysql -u root <<EOF
DROP DATABASE IF EXISTS \`$PARSED_DB\`;
CREATE DATABASE \`$PARSED_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`$PARSED_DB\`.* TO '$PARSED_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
        gunzip -c "$BACKUP_FILE" | mysql -u "$PARSED_USER" -p"$PARSED_PASS" -h "$PARSED_HOST" "$PARSED_DB"
    else
        mysql -u root <<EOF
DROP DATABASE IF EXISTS \`$DB_NAME\`;
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
        gunzip -c "$BACKUP_FILE" | mysql -u "$DB_USER" -p "$DB_NAME"
    fi

    # Restart application
    pm2 start xertiq-api 2>/dev/null || true

    log_success "Database restored successfully!"
}

#############################################
# Main
#############################################
case "$1" in
    setup)
        setup
        ;;
    setup-db)
        setup_db
        ;;
    ssl)
        setup_ssl
        ;;
    deploy)
        deploy
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    logs)
        logs $2
        ;;
    backup)
        backup
        ;;
    restore)
        restore "$2"
        ;;
    *)
        echo "XertiQ VPS Deployment Script (Hostinger KVM2)"
        echo ""
        echo "Usage: $0 {command}"
        echo ""
        echo "Commands:"
        echo "  setup      - Initial VPS setup (Node, Nginx, PM2, MySQL, Redis)"
        echo "  setup-db   - Create MySQL database and user"
        echo "  ssl        - Setup Let's Encrypt SSL certificate"
        echo "  deploy     - Deploy/update the application"
        echo "  restart    - Restart all services"
        echo "  status     - Check status of all services"
        echo "  logs       - View logs [pm2|nginx|mysql|all]"
        echo "  backup     - Backup the database"
        echo "  restore    - Restore database from backup file"
        echo ""
        echo "First-time deployment:"
        echo "  1. ./deploy-vps.sh setup"
        echo "  2. mysql_secure_installation"
        echo "  3. ./deploy-vps.sh setup-db"
        echo "  4. Configure .env (copy .env.example)"
        echo "  5. git clone <repo> $APP_DIR"
        echo "  6. DOMAIN=yourdomain.com ./deploy-vps.sh ssl"
        echo "  7. ./deploy-vps.sh deploy"
        ;;
esac
