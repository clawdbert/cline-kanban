# Theory: Containerizing cline-kanban for Persistent Deployment

## Problem

cline-kanban runs as a multi-agent orchestration platform — a long-lived Node.js process that
manages ephemeral git worktrees, spawns AI coding agents, streams terminal output, and persists
task state across sessions. When run directly on a headless Linux server (the natural team/shared
deployment mode), there is no process supervisor: a reboot silently kills the service, agent
sessions are lost, and recovery requires manual SSH. This is not a scaling problem — it is a
reliability contract problem. The system makes implicit promises about persistence that the
deployment model cannot keep.

The deeper issue: the gap between "runs on my laptop" and "runs as a team service" was entirely
operational friction. The codebase was already server-capable (no Electron dependency, no desktop
assumptions), but there was no sanctioned way to deploy it durably. Every team installation was
ad-hoc.

## Operating Theory

The containerization strategy treats Docker Compose + systemd as the minimal viable operations
layer — not Kubernetes, not a managed platform, just a single-host deployment that survives
reboots. The theory is that most teams deploying cline-kanban share one server (or a small VM),
so single-host reliability buys almost everything they need with near-zero ops burden.

Three design principles drive the implementation:

**State durability through named volumes.** Agent state lives in `~/.cline/kanban/` (config,
workspaces, worktrees). This maps to a named Docker volume (`kanban-data`) that survives
`docker compose down` and host reboots. The worktrees themselves are ephemeral within tasks but
the workspace registry and config are not — they must survive.

**Host tool reachability through bind mounts.** Agents inside the container invoke host-installed
CLIs (`claude`, `gh`, `node` via nvm, etc.) as child processes. Rather than bundling these tools
or reimplementing them, the compose file bind-mounts `~/.nvm` and `~/.local` read-only, making
the host's tools reachable at known paths. This is deliberate coupling — the container delegates
tool management to the host operator.

**Configuration through environment variables.** Everything an operator needs to tune (host port,
projects root, nvm version, API keys) flows through a single `.env` file. No config files to
edit inside the container; no rebuild required to change settings. The `.env.ck-prod.example`
template is the contract between the codebase and the operator.

## Strategy

The implementation is a 2-stage Dockerfile (build → runtime), a `compose.yaml` that wires
volumes/bind-mounts/env/ports, a `deploy/ck-prod.service` systemd unit that invokes compose on
boot with restart-on-failure, and an example `.env` template.

The sequencing was: establish the Dockerfile and smoke-test basic startup → add project directory
bind mounts → apply review feedback on edge cases (NVM path fallback, .dockerignore scope) →
verify with smoke test. The PRD (`.plan/PRDs/02-containerize.md`) specified the deliverables
precisely; the implementation tracked it closely.

The current state: **done**. Smoke tests pass. The containerization workstream is complete and
merges into the broader server-deployment track.

## Key Discoveries

**The agent tool path problem is the crux.** The hardest design question was: how do agents inside
the container invoke `claude`, `codex`, or `gemini`? Bundling them would require re-shipping large
binaries and tracking upstream versions. The chosen approach — bind-mounting the host's `~/.nvm`
and `~/.local` — keeps the container thin but creates an explicit dependency on the host's tool
installation. The compose file documents this coupling clearly via the volume mounts.

**AGENTS.md already captured the interactive-shell anti-pattern.** A prior incident showed that
spawning `zsh -i` for agent detection on shell-heavy setups (nvm, conda) can freeze the runtime.
The container deployment doesn't change that constraint — agents still launch via direct PATH
checks, not interactive shells.

**State separation is clean.** The codebase already separated runtime state (`~/.cline/kanban/`)
from code projects (wherever `CK_PROJECTS_ROOT` points). This made volume strategy
straightforward: one named volume for runtime state, one bind-mount for projects.

## Open Questions

**Multi-host scaling.** The current model assumes one server. If teams want multiple instances
sharing one workspace registry, the named-volume approach breaks — state would need to move to a
shared store. No signal that this is imminent, but the design does not preclude it.

**Agent binary updates.** When `claude` or `gh` updates on the host, the container sees the new
version immediately (bind-mount). This is mostly good, but a breaking CLI change could silently
break agent sessions. No mitigation today.

**Terminal core rewrite.** A separate in-progress workstream (`.plan/03-terminal-core-rewrite/`)
is modernizing the PTY-backed terminal runtime. That work is orthogonal to containerization but
shares the agent-launch code path. Changes there may affect how the container's PATH environment
is constructed for agent child processes.
