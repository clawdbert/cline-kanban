# PRD: Path-Preserving Projects Bind Mount

## Status
Ready for implementation.

---

## Problem

The `compose.yaml` defined in `02-containerize.md` mounts the host's projects directory at the container-internal path `/projects`:

```yaml
- "${CK_PROJECTS_ROOT:-/srv/projects}:/projects:rw"
```

The container-internal path (`/projects`) differs from the host path (`/home/deploy/projects`). Every absolute path that crosses the container boundary breaks: git worktree records, tRPC shell commands, VS Code remote URLs, and workspace root references stored in `~/.cline/kanban/workspaces/` all use the host-side absolute path, which does not exist at `/projects` inside the container.

---

## Goal

Mount `/home/deploy/projects` from the host into the container at the same absolute path — `/home/deploy/projects` — so no path translation is needed at the container boundary.

---

## Deliverables

### 1. Updated `compose.yaml`

Replace the projects volume line:

```yaml
# before
- "${CK_PROJECTS_ROOT:-/srv/projects}:/projects:rw"

# after
- /home/deploy/projects:/home/deploy/projects:rw
```

The source and target are identical. No environment variable indirection is needed; the path is a deployment-time constant for this host.

Full updated volumes block:

```yaml
    volumes:
      - kanban-data:/home/node/.cline
      - /home/deploy/projects:/home/deploy/projects:rw
```

### 2. Updated `Dockerfile` — UID alignment

The container `node` user (uid 1000) must match the host `deploy` user's UID so the bind-mounted directory is writable without a `chown` step on the host. Add a build argument that remaps the user at image build time:

```dockerfile
# Runtime stage — insert after the base FROM line
ARG DEPLOY_UID=1000
RUN if [ "$DEPLOY_UID" != "1000" ]; then \
      usermod -u "$DEPLOY_UID" node && \
      find /home/node -user 1000 -exec chown -h node {} \; 2>/dev/null || true; \
    fi
USER node
```

Wire the build arg in `compose.yaml`:

```yaml
    build:
      context: .
      args:
        - DEPLOY_UID=${DEPLOY_UID:-1000}
```

This is a no-op when `DEPLOY_UID=1000`, so existing deployments are unaffected.

### 3. Updated `.env.ck-prod.example`

Remove `CK_PROJECTS_ROOT` (the path is now hardcoded in `compose.yaml`) and add `DEPLOY_UID`:

```dotenv
# ── Network ──────────────────────────────────────────────────────────────────
CK_HOST_PORT=3484
CK_CONTAINER_PORT=3484

# ── Storage ───────────────────────────────────────────────────────────────────
# UID of the host user that owns /home/deploy/projects.
# Run `id -u` on the host to confirm. Default 1000 matches most single-user servers.
DEPLOY_UID=1000

# ── Telemetry (optional) ──────────────────────────────────────────────────────
POSTHOG_KEY=
POSTHOG_HOST=https://data.cline.bot
```

---

## Configuration reference (delta from 02-containerize.md)

| Variable | Default | Purpose |
|---|---|---|
| `DEPLOY_UID` | `1000` | UID of the host user that owns `/home/deploy/projects`; the container's `node` user is remapped to this UID at build time |

`CK_PROJECTS_ROOT` is removed — the mount path is fixed in `compose.yaml`.

---

## Constraints

- **The directory must exist on the host before `compose up`.** Docker does not create bind-mount source directories.
- **`/home/deploy/projects` must not contain a trailing slash** in the compose file. Docker normalises paths inconsistently; keep it exact.

---

## Success criteria

1. `docker compose up -d` starts the container without errors.
2. `docker exec ck-prod ls /home/deploy/projects` returns the same listing as `ls /home/deploy/projects` on the host.
3. `docker exec ck-prod touch /home/deploy/projects/.ck-probe` creates a file owned by the host `deploy` user, visible on the host at the same path.
4. Registering a workspace at `/home/deploy/projects/myrepo` and querying its worktrees from inside the container succeeds — git resolves the absolute path without error.
5. All success criteria from `02-containerize.md` continue to pass unchanged.

---

## Out of scope

- Making the projects path configurable (it is fixed to `/home/deploy/projects` for this deployment).
- Creating `/home/deploy/projects` on the host as part of `compose up`.
- Mounting additional host directories.
