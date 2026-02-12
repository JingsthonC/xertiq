# XertiQ Backend Dockerfile
# Multi-stage build for smaller production image

# ===== Build Stage =====
FROM node:20-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache python3 make g++

# Copy package files
COPY xertiq_backend/package*.json ./

# Install all dependencies (--ignore-scripts: schema not copied yet, generate runs below)
RUN npm ci --ignore-scripts

# Copy Prisma schema
COPY xertiq_backend/prisma ./prisma

# Generate Prisma client
RUN npx prisma generate

# Copy source code
COPY xertiq_backend/src ./src
COPY xertiq_backend/scripts ./scripts

# ===== Production Stage =====
FROM node:20-alpine AS production

WORKDIR /app

# Install production dependencies only
RUN apk add --no-cache tini

# Create non-root user
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

# Copy package files
COPY xertiq_backend/package*.json ./

# Install production dependencies only (--ignore-scripts: Prisma client already built in builder stage)
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# Copy built artifacts from builder
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/src ./src
COPY --from=builder /app/scripts ./scripts

# Create required directories
RUN mkdir -p uploads/temp /var/log/pm2 && \
    chown -R nodejs:nodejs /app uploads

# Switch to non-root user
USER nodejs

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1

# Use tini as init system for proper signal handling
ENTRYPOINT ["/sbin/tini", "--"]

# Start the application
CMD ["node", "src/index.js"]
