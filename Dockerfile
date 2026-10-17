# ==============================================================================
# Production Dockerfile for aws-cicd-demo
# Features:
# - Minimal Alpine Linux base image
# - Non-root security user (node:node)
# - Production-only dependency installation via `npm ci`
# - Built-in native Docker HEALTHCHECK probe
# - Proper signal handling for graceful shutdown (SIGTERM/SIGINT)
# ==============================================================================

FROM node:22-alpine AS runtime

# Install curl for robust healthcheck probes
RUN apk add --no-cache curl

# Set working directory
WORKDIR /usr/src/app

# Set default production environment variables
ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0

# Copy dependency manifests first to leverage Docker layer caching
COPY package.json package-lock.json ./

# Install production dependencies strictly and clean npm cache
RUN npm ci --omit=dev --ignore-scripts \
    && npm cache clean --force

# Copy application source and public assets
COPY src/ ./src/
COPY public/ ./public/

# Ensure application files are owned by the non-root user 'node' (UID: 1000)
RUN chown -R node:node /usr/src/app

# Switch to non-root user
USER node

# Expose application port
EXPOSE 3000

# Docker Healthcheck probe targeting /api/health
HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3000/api/health || exit 1

# Start the Node.js application directly (PID 1 receives SIGTERM cleanly)
CMD ["node", "src/server.js"]
