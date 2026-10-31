# ============================================================
# Patogh — Multi-stage Docker build
# ============================================================

# Stage 1: Production dependencies
#
# better-sqlite3 13.x is an N-API addon and ships its prebuilt binaries inside
# the npm package (prebuilds/linux-x64.node and linux-arm64.node among them), so
# the install downloads nothing extra and compiles nothing: this stage needs no
# Python and no C++ compiler (the package sets "gypfile": false, so npm adds no
# implicit `node-gyp rebuild`). The runtime stage copies
# the resulting node_modules and runs no install of its own.
#
# The base is node:24-slim, Node v24.20.0. All three stages pin it by the digest
# of the multi-arch index, so the same pin resolves on amd64 and on arm64.
FROM node:24-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS deps

WORKDIR /app

# Copy workspace config
COPY package.json package-lock.json ./
COPY tsconfig.base.json ./

# Copy package.json files for all workspace packages
COPY packages/shared/package.json packages/shared/
COPY packages/server/package.json packages/server/
COPY packages/web/package.json packages/web/

# The production dependency tree that ships in the runtime image. npm hoists
# into the root node_modules; the mkdir keeps the runtime stage's COPY of the
# server's own node_modules valid when nothing needed nesting.
# NPM_REGISTRY: a mirror for networks where registry.npmjs.org is blocked
# (install.sh picks one that answers). npm swaps the lockfile's registry host
# for it, so the pinned versions and integrity hashes still apply.
# --ignore-scripts: npm still runs an implicit `node-gyp rebuild` for
# better-sqlite3 because it ships a binding.gyp, despite "gypfile": false, and
# that fails here without Python and a compiler. Its prebuilt binary is loaded
# from prebuilds/ anyway, and esbuild (for tsx) finds its binary without its
# install script.
ARG NPM_REGISTRY=""
RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi && \
    npm ci --omit=dev --ignore-scripts -w @patogh/server && mkdir -p packages/server/node_modules

# ============================================================
# Stage 2: Build the frontend
#
# Installs only @patogh/web and what it depends on (@patogh/shared). That
# keeps the server dependencies, better-sqlite3 among them, out of this stage, so
# the native module is installed once, in `deps`.
#
# Base: node:24-slim, Node v24.20.0.
FROM node:24-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS builder

WORKDIR /app

# Copy workspace config
COPY package.json package-lock.json ./
COPY tsconfig.base.json ./

# Copy package.json files for all workspace packages
COPY packages/shared/package.json packages/shared/
COPY packages/server/package.json packages/server/
COPY packages/web/package.json packages/web/

ARG NPM_REGISTRY=""
RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi && \
    npm ci -w @patogh/web

# Copy source code (excluding desktop — not needed in Docker)
COPY packages/shared/ packages/shared/
COPY packages/web/ packages/web/

# The web build starts with the localization consistency check, which lives
# in scripts/ and reads its allowlist and pending list from there. Only the
# check is copied: scripts/metrics is a workspace package the image does not
# build, and its lockfile entries are already filtered out by the install above.
COPY scripts/check-i18n.mjs scripts/i18n-allowlist.json scripts/i18n-pending.txt scripts/
COPY scripts/i18n/ scripts/i18n/

# Build the web frontend
RUN npm run build -w @patogh/web

# ============================================================
# Stage 3: Production runtime
#
# Base: node:24-slim, Node v24.20.0.
FROM node:24-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS runtime

# No package manager ships in the runtime image. This stage installs nothing
# from a registry: node_modules arrives from `deps` as a finished tree and the
# CMD starts node directly, so npm is never invoked here. It
# used to be present anyway, because node:24-slim bundles it. It was
# most of the image's fixable HIGH/CRITICAL scan findings, all of it in code
# that never runs. Deleting it deletes the findings.
#
# If a future change needs to install something at image build time, do it in
# `deps` and copy the result in, the way better-sqlite3 already works.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

# Runtime deps only: ffmpeg (media processing) + gosu (drop to non-root in the
# entrypoint). No C toolchain. The native modules come from `deps` as prebuilt
# binaries and are copied in below.
# DEBIAN_MIRROR: a Debian mirror base URL (http://host, serving /debian) for
# networks where deb.debian.org is blocked; install.sh picks one that answers.
ARG DEBIAN_MIRROR=""
RUN if [ -n "$DEBIAN_MIRROR" ]; then \
      sed -i "s#http://deb.debian.org/debian#${DEBIAN_MIRROR}/debian#g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg gosu && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy workspace config
COPY package.json package-lock.json ./
COPY tsconfig.base.json ./

# Copy package.json files
COPY packages/shared/package.json packages/shared/
COPY packages/server/package.json packages/server/
COPY packages/web/package.json packages/web/

# Copy shared source (needed at runtime since server imports types directly)
COPY packages/shared/ packages/shared/

# Copy server source
COPY packages/server/ packages/server/

# Production dependencies, built in the `deps` stage. npm's workspace symlinks are
# relative to /app, so the tree works unchanged after the copy.
COPY --from=deps /app/node_modules node_modules
COPY --from=deps /app/packages/server/node_modules packages/server/node_modules

# Copy built frontend from builder stage
COPY --from=builder /app/packages/web/dist packages/web/dist

# Create data directories
RUN mkdir -p /app/data/uploads

# Non-root hardening: copy the privilege-dropping entrypoint. It chowns the
# data volume as root, then execs the CMD as the unprivileged `node` user.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Set environment defaults
ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0
ENV DB_PATH=/app/data/patogh.db
ENV UPLOAD_DIR=/app/data/uploads

# AGPL-3.0 § 13 source offer: bake the running build's git commit into the image
# so GET /api/instance/info can advertise the exact version. Passed via
# --build-arg PATOGH_COMMIT=$(git rev-parse --short HEAD) (see deploy.sh /
# docker-compose.yml). Empty when git is unavailable → server treats as null.
ARG PATOGH_COMMIT=""
ENV PATOGH_COMMIT=$PATOGH_COMMIT

EXPOSE 3000

# Health check — reads PORT from environment so it works with any configured port
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "fetch('http://localhost:' + (process.env.PORT || 3000) + '/api/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"

# Run the server using tsx from the server package directory
WORKDIR /app/packages/server
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "--import", "tsx/esm", "src/index.ts"]
