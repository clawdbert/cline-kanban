# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────────
FROM node:22-alpine AS build
WORKDIR /build

# Layer-cache dependency installs separately from source copy.
COPY package.json package-lock.json ./
COPY web-ui/package.json web-ui/package-lock.json web-ui/
RUN npm ci && npm --prefix web-ui ci

COPY . .

# SENTRY_AUTH_TOKEN not set → upload step is skipped automatically.
RUN npm run build

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM node:22-alpine AS runtime
WORKDIR /app

COPY --from=build /build/dist ./dist
COPY --from=build /build/package.json /build/package-lock.json ./

# Production deps only.
RUN npm ci --omit=dev

# Run as the unprivileged node user (uid 1000) that ships in the base image.
# HOME must be set so the app resolves ~/.cline/kanban/ correctly.
ENV HOME=/home/node
USER node

ENTRYPOINT ["node", "dist/cli.js"]

# --host 0.0.0.0 makes the port reachable from outside the container.
# compose.yaml also sets KANBAN_RUNTIME_HOST which the app reads at startup.
CMD ["--host", "0.0.0.0", "--no-open"]
