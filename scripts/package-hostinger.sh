#!/bin/bash
#
# Package XertiQ for Hostinger manual upload (tar.gz)
#
# Usage: bash scripts/package-hostinger.sh
#
# This script:
# 1. Builds the React frontend
# 2. Copies the build into xertiq_backend/public/
# 3. Creates a tar.gz of xertiq_backend (without node_modules)
#    ready for upload to Hostinger
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$ROOT_DIR/xertiq_frontend"
BACKEND_DIR="$ROOT_DIR/xertiq_backend"
OUTPUT_FILE="$ROOT_DIR/xertiq-hostinger.tar.gz"

echo "========================================="
echo "  XertiQ Hostinger Packaging Script"
echo "========================================="

# Step 1: Build frontend
echo ""
echo "Step 1/3: Building frontend..."
cd "$FRONTEND_DIR"
npm install
npm run build
echo "✅ Frontend built successfully"

# Step 2: Copy frontend build to backend/public
echo ""
echo "Step 2/3: Copying frontend to backend/public/..."
rm -rf "$BACKEND_DIR/public"
cp -r "$FRONTEND_DIR/dist" "$BACKEND_DIR/public"
echo "✅ Frontend copied to backend/public/"

# Step 3: Create tar.gz (exclude node_modules, .env, uploads)
echo ""
echo "Step 3/3: Creating tar.gz..."
cd "$ROOT_DIR"
tar -czf "$OUTPUT_FILE" \
  --exclude='xertiq_backend/node_modules' \
  --exclude='xertiq_backend/.env' \
  --exclude='xertiq_backend/.env.*' \
  --exclude='xertiq_backend/uploads/temp/*' \
  --exclude='xertiq_backend/display-certificates' \
  --exclude='xertiq_backend/.DS_Store' \
  xertiq_backend/

echo ""
echo "========================================="
echo "✅ Package created: xertiq-hostinger.tar.gz"
echo "   Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Upload xertiq-hostinger.tar.gz to Hostinger"
echo "     hPanel → Node.js Apps → Upload (tar.gz)"
echo ""
echo "  2. Set in Hostinger:"
echo "     Build command:  npm run build:hostinger"
echo "     Start command:  npm start"
echo "     Node version:   20.x"
echo ""
echo "  3. Add environment variables in hPanel"
echo "     (DATABASE_URL, JWT_SECRET, etc.)"
echo ""
echo "  4. Deploy!"
echo "========================================="
