## npx kanban (Research Preview)

<p align="center">
  <img src="https://github.com/user-attachments/assets/2aa3dcc7-94e3-4076-bcfe-6d0272007cfe" width="100%" />
</p>

A replacement for your IDE better suited for running many agents in parallel and reviewing diffs. Each task card gets its own terminal and worktree, all handled for you automatically. Enable auto-commit and link cards together to create dependency chains that complete large amounts of work autonomously.

> [!WARNING]
> Kanban is a research preview and uses experimental features of CLI agents like bypassing permissions and runtime hooks for more autonomy. We'd love your feedback in #kanban on our [discord](https://discord.gg/cline).

<div align="left">
<table>
<tbody>
<td align="center">
<a href="https://www.npmjs.com/package/kanban" target="_blank">NPM</a>
</td>
<td align="center">
<a href="https://github.com/cline/kanban" target="_blank">GitHub</a>
</td>
<td align="center">
<a href="https://github.com/cline/kanban/issues" target="_blank">Issues</a>
</td>
<td align="center">
<a href="https://github.com/cline/kanban/discussions/categories/feature-requests?discussions_q=is%3Aopen+category%3A%22Feature+Requests%22+sort%3Atop" target="_blank">Feature Requests</a>
</td>
<td align="center">
<a href="https://discord.gg/cline" target="_blank">Discord</a>
</td>
<td align="center">
<a href="https://x.com/cline" target="_blank">@cline</a>
</td>
</tbody>
</table>
</div>

### 1. Open kanban
```bash
# Run directly (no install required)
npx kanban

# Or install globally
npm i -g kanban
kanban
```
Run this from the root of any git repo. Kanban will detect your installed CLI agent and launch a local running webserver in your browser. No account or setup required, it works right out of the box.

### 2. Create tasks
Create a task card manually, or open the sidebar chat and ask your agent to break work down into tasks for you. Kanban injects board-management instructions into that session so you can simply ask it to add tasks, link tasks, or start work on your board.

### 3. Link and automate
<kbd>⌘</kbd> + click a card to link it to another task. When a card is completed and moved to trash, linked tasks auto-start. Combine with auto-commit for fully autonomous dependency chains: one task completes → commits → kicks off the next → repeat. It’s a pretty magical experience asking your agent to decompose a big task into subtasks that auto-commit - he’ll cleverly do it in a way that parallelizes for maximum efficiency and links tasks together for end-to-end autonomy.

### 4. Start tasks
Hit the play button on a card. Kanban creates an ephemeral worktree just for that task so agents work in parallel without merge conflicts. Under the hood, it also symlinks gitignored files like `node_modules` so you don't have to worry about slow `npm install`s for each copy of your project.

> [!NOTE]
> [Symlinks (symbolic links)](https://en.wikipedia.org/wiki/Symbolic_link) are special "shortcuts" pointing to another file or directory, allowing access to the target from a new location without duplicating data. They work great in this case since you typically don't modify gitignored files in day-to-day work, but for when you do then don't use Kanban.

As agents work, Kanban uses hooks to display the latest message or tool call on each card, so you can monitor hundreds of agents at a glance without opening each one.

### 5. Review changes
Click a card to view the agent's TUI and a diff of all the changes in that worktree. Kanban includes its own checkpointing system so you can also see a diff from the last messages you've sent. Click on lines to leave comments and send them back to the agent.

To easily test and debug your app, create a Script Shortcut in settings. Use a command like `npm run dev` so that all you have to do is hit a play button in the navbar instead of remembering commands or asking your agent to do it.

### 6. Ship it
When the work looks good, hit **Commit** or **Open PR**. Kanban sends a dynamic prompt to the agent to convert the worktree into a commit on your base ref or a new PR branch, and work through any merge conflicts intelligently. Or skip review by enabling auto-commit / auto-PR and the agent ships as soon as it's done. Move the card to trash to clean up the worktree (you can always resume later since Kanban tracks the resume ID).

### 7. Keep track with git interface
Click the branch name in the navbar to open a full git interface to browse commit history, switch branches, fetch, pull, push, and visualize your git all without leaving Kanban. Keep track of everything your agents are doing across branches as work is completed.

---

## Server deployment (Docker)

Run cline-kanban as a persistent service on a headless Linux server.

### Quick start

```bash
# 1. Place the repo at /opt/ck-prod (symlink or copy)
sudo ln -s /home/deploy/projects/cline-kanban /opt/ck-prod

# 2. Configure
cp /opt/ck-prod/.env.ck-prod.example /opt/ck-prod/.env.ck-prod
# Edit .env.ck-prod — set CK_PROJECTS_ROOT and any other values

# 3. Grant the container's node user (uid 1000) write access to your projects root
sudo chown -R 1000:1000 /srv/projects   # adjust path to match CK_PROJECTS_ROOT

# 4. Install the systemd unit
sudo cp /opt/ck-prod/deploy/ck-prod.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ck-prod
```

The service auto-starts on boot and restarts on failure. State is stored in the
`ck-prod-data` Docker volume — `docker compose down` alone does not lose data.
Only `docker volume rm ck-prod-data` destroys state.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CK_HOST_PORT` | `3484` | Port bound on the host |
| `CK_CONTAINER_PORT` | `3484` | Port the Node process listens on inside the container |
| `CK_PROJECTS_ROOT` | `/srv/projects` | Host path bind-mounted as `/projects` |
| `CK_HOST_HOME` | `/home/deploy` | Home directory whose `.nvm` and `.local` hold agent CLIs |
| `CK_NVM_NODE_VERSION` | `v24.14.1` | NVM node version whose `bin/` is added to container PATH |
| `POSTHOG_KEY` | _(empty)_ | PostHog API key; empty = telemetry off |
| `POSTHOG_HOST` | `https://data.cline.bot` | PostHog ingest URL |

Agent CLIs (`claude`, `codex`, etc.) are mounted read-only from the host at runtime —
`$CK_HOST_HOME/.nvm` and `$CK_HOST_HOME/.local` — so no extra install step is needed.
Update `CK_NVM_NODE_VERSION` whenever you upgrade the node version that owns those CLIs.

### Manual compose commands

```bash
cd /opt/ck-prod
docker compose up -d        # start detached
docker compose logs -f      # stream logs
docker compose down         # stop (data preserved)
docker volume rm ck-prod-data  # ⚠ permanently deletes all board state
```

---

[Apache 2.0 © 2026 Cline Bot Inc.](./LICENSE)
