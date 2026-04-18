# PRD: Containerize cline-kanban for Headless Server Deployment

## Status
Ready for implementation.

---

## Problem

cline-kanban currently runs as a bare Node.js process launched manually from a user's shell. On a headless remote server there is no persistent process supervisor, no restart-on-reboot, and no isolation from the host environment. A server restart silently kills the service and all agent state becomes inaccessible until someone SSHes in to restart it by hand.

---

## Goal

Ship a production-grade container deployment that:

1. Packages cline-kanban as a Docker image built from source in this repo.
2. Defines a single `compose.yaml` that names the container `ck-prod`, exposes the runtime port, and keeps all stateful data on a named Docker volume so a `docker volume rm` is the only way to lose data.
3. Provides a systemd service unit, checked into this repo, that starts `docker compose up` on system boot and restarts the container on failure.
4. Exposes every tuneable parameter through one `.env` file so that operators never need to edit YAML.

### Out of scope

- Multi-service orchestration (database, reverse proxy). cline-kanban is a single-process app with file-based state; no external database is needed.
- TLS termination inside the container (handled at the host or a reverse proxy layer).
- Image publishing to a registry.
- Kubernetes / Nomad / other orchestrators.

---

## Background: how the app stores state

The runtime stores all persistent data under a single directory tree resolved from `os.homedir()` at startup:

```
$HOME/.cline/kanban/
  config.json          # global runtime preferences
  workspaces/          # per-repo board state (board.json, sessions.json, meta.json, index.json)
  worktrees/           # git worktrees created by task sessions
```

There is no external database. Durability = protecting this directory tree across container restarts and host reboots.

---

## Deliverables

### 1. `Dockerfile`

Location: repo root (`Dockerfile`).

**Build stage** — node:22-alpine, installs all deps and builds the full project:
```
npm run install:all
npm run build
```

**Runtime stage** — node:22-alpine, copies only:
- `dist/`
- `package.json` + `package-lock.json` (production deps only, `npm ci --omit=dev`)

Runs as an unprivileged user (`node`, uid 1000). `HOME` is `/home/node`.  
`ENTRYPOINT ["node", "dist/cli.js"]`  
Default `CMD` passes `--host 0.0.0.0` so the port is reachable from outside the container.

### 2. `compose.yaml`

Location: repo root (`compose.yaml`).

```yaml
name: ck-prod

services:
  app:
    build: .
    container_name: ck-prod
    restart: unless-stopped
    ports:
      - "${CK_HOST_PORT:-3484}:${CK_CONTAINER_PORT:-3484}"
    environment:
      KANBAN_RUNTIME_HOST: "0.0.0.0"
      KANBAN_RUNTIME_PORT: "${CK_CONTAINER_PORT:-3484}"
    volumes:
      - kanban-data:/home/node/.cline
      - "${CK_PROJECTS_ROOT:-/srv/projects}:/projects:rw"
    env_file:
      - .env.ck-prod   # operator config — see §4

volumes:
  kanban-data:
    name: ck-prod-data
```

Key design decisions:
- `restart: unless-stopped` so Docker itself recovers from crashes without waiting for systemd.
- `kanban-data` named volume (not a bind mount) so data survives `compose down` and host path changes.
- Projects bind mount is separate from state. Operators point `CK_PROJECTS_ROOT` at wherever their code lives.
- All tuneable values flow through `.env.ck-prod`; the compose file contains only safe defaults.

### 3. `deploy/ck-prod.service`

Location: `deploy/ck-prod.service` (checked into the repo).

```ini
[Unit]
Description=Cline Kanban (ck-prod)
Documentation=https://github.com/cline/kanban
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/ck-prod          # operator symlinks or copies repo here
ExecStartPre=docker compose pull --quiet || true
ExecStart=docker compose up --remove-orphans
ExecStop=docker compose down
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

**Installation steps** (documented in README, not automated here):
```bash
# 1. Place the repo (or a release tarball) at /opt/ck-prod
sudo ln -s /home/deploy/projects/cline-kanban /opt/ck-prod

# 2. Copy .env.ck-prod.example → .env.ck-prod and fill in secrets
cp /opt/ck-prod/.env.ck-prod.example /opt/ck-prod/.env.ck-prod

# 3. Install and enable the unit
sudo cp /opt/ck-prod/deploy/ck-prod.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ck-prod
```

### 4. `.env.ck-prod.example`

Location: repo root (`.env.ck-prod.example`). **Never commit `.env.ck-prod`** (add to `.gitignore`).

```dotenv
# ── Network ──────────────────────────────────────────────────────────────────
# Port exposed on the host. Container always listens on CK_CONTAINER_PORT.
CK_HOST_PORT=3484
CK_CONTAINER_PORT=3484

# ── Storage ───────────────────────────────────────────────────────────────────
# Absolute path on the host where operator repos live.
# Mounted read-write at /projects inside the container.
CK_PROJECTS_ROOT=/srv/projects

# ── Telemetry (optional) ──────────────────────────────────────────────────────
# Leave blank to disable PostHog telemetry.
POSTHOG_KEY=
POSTHOG_HOST=https://data.cline.bot
```

`.gitignore` addition:
```
.env.ck-prod
```

---

## Configuration reference

| Variable | Default | Purpose |
|---|---|---|
| `CK_HOST_PORT` | `3484` | Port bound on the host machine |
| `CK_CONTAINER_PORT` | `3484` | Port the Node process listens on inside the container |
| `CK_PROJECTS_ROOT` | `/srv/projects` | Host path bind-mounted as `/projects` for code repos |
| `POSTHOG_KEY` | _(empty)_ | PostHog API key; empty = telemetry off |
| `POSTHOG_HOST` | `https://data.cline.bot` | PostHog ingest URL |
| `KANBAN_RUNTIME_HOST` | `0.0.0.0` | Hardcoded in compose; override only if you know what you're doing |

---

## Success criteria

1. `docker compose up -d` starts the `ck-prod` container; `curl http://localhost:3484` returns an HTTP response.
2. A board created before `docker compose restart` still exists and is intact after restart (data persisted in `ck-prod-data` volume).
3. After `sudo reboot`, the service is running and the board is intact (systemd started the container on boot).
4. All parameters in the configuration reference table are honoured when set in `.env.ck-prod`.
5. No data is lost by `compose down` / `compose up` (only `docker volume rm ck-prod-data` destroys state).
6. No secrets, tokens, or API keys appear in the committed files (`Dockerfile`, `compose.yaml`, `deploy/ck-prod.service`, `.env.ck-prod.example`).

---

## Open questions

1. **Projects mount access**: agent sessions spawn git worktrees under the projects directory. The container `node` user (uid 1000) must have write permission to `CK_PROJECTS_ROOT` on the host. Should we document a `chown` step, or add a `user:` override in compose that maps to the host's `deploy` uid?

2. **Agent binaries**: agent sessions run `claude`, `codex`, etc. as child processes. These binaries are not present in a stock `node:22-alpine` image. Do we install them in the Dockerfile (and pin versions), or bind-mount the host's PATH somehow? This may scope-creep into "agent-in-container" territory and could be deferred.

3. **TLS**: if the instance sits behind a reverse proxy (nginx, Caddy), no TLS config is needed. If it's exposed directly, the existing `--https` / `--cert` / `--key` CLI flags could be surfaced as env vars. Defer unless needed.
