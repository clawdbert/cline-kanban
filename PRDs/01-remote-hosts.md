# PRD: Remote Host VSCode Integration

## Status
Ready for implementation.

## Problem

When Cline Kanban runs on a remote Linux server and users access it from a Mac browser over SSH/tunnel, the **"Open in VS Code"** button fails with an error like:

```
Could not open in VS Code: unknown parameter -a
```

**Root cause** (`web-ui/src/utils/open-targets.ts:127`): `resolveOpenTargetPlatform()` reads `navigator.userAgent` — the *browser's* platform — not the server's. A Mac browser returns `"mac"`, so `buildOpenCommand()` generates `open -a 'Visual Studio Code' '/path'`. That macOS-only shell command is then sent via tRPC `runtime.runCommand` and executed on the Linux server, which has no `open` binary.

Even if the platform detection were fixed, running `code /path` on a headless Linux server still cannot open VS Code on the user's client machine. The entire "run a command server-side to open an editor" model is wrong for remote usage.

**Correct model**: When the server is remote, return a `vscode://vscode-remote/ssh-remote+{host}{path}?windowId=_blank` URL to the browser client. The client's local VS Code handles that URL scheme and connects over SSH to the remote host — no shell command executed on the server.

---

## Goal

Add a **Remote SSH Host** setting. When set, the Open Workspace button skips `runCommand` entirely and instead calls `window.open()` with a properly-formed `vscode://` (or equivalent) remote URL that the user's local editor handles.

### Out of scope

- SSH key provisioning or SSH config management (user is responsible for ensuring their SSH alias is in `~/.ssh/config` on their client).
- Cursor/Windsurf/Zed remote URL schemes beyond what is spec'd below — VS Code is the primary case; others are a bonus.
- Any changes to how the server-side `runCommand` path works for local (non-remote) usage.

---

## User-Facing Behaviour

1. User opens Settings → **General** tab.
2. A new field **"SSH Remote Host"** appears below the existing Open Workspace editor selector.
3. User types their SSH alias (e.g. `myserver`) matching an entry in `~/.ssh/config` on their *client* machine.
4. User clicks **Save**.
5. User clicks **Open in VS Code** on any workspace card.
6. Browser navigates to `vscode://vscode-remote/ssh-remote+myserver/absolute/path/to/workspace?windowId=_blank`.
7. Local VS Code opens a new window connected to the remote host at that path.

When the SSH host field is **empty or null**, behaviour is unchanged: the server runs `buildOpenCommand()` as before.

---

## Data Flow

```
Settings UI (new input)
  └─ draft.remoteEditorSshHost: string | null
       └─ save() → trpc.runtime.saveConfig
            └─ parseRuntimeConfigSaveRequest  [src/core/api-validation.ts]
            └─ updateRuntimeConfig / updateGlobalRuntimeConfig [src/config/runtime-config.ts]
            └─ buildRuntimeConfigResponse  [src/terminal/agent-registry.ts]
            └─ RuntimeConfigResponse.remoteEditorSshHost  [src/core/api-contract.ts]

Open Workspace button click
  └─ useOpenWorkspace({ remoteEditorSshHost })  [web-ui/src/hooks/use-open-workspace.ts]
       ├─ if remoteEditorSshHost is set:
       │     window.open(buildRemoteEditorUrl(host, path, targetId))
       └─ else (unchanged):
             trpc.runtime.runCommand.mutate({ command: buildOpenCommand(...) })
```

---

## Implementation

Work through the layers bottom-up: config storage → wire protocol → frontend hook → UI.

### Step 1 — Config storage (`src/config/runtime-config.ts`)

**a) Add field to file shape (line ~13)**

```typescript
interface RuntimeGlobalConfigFileShape {
  selectedAgentId?: RuntimeAgentId;
  selectedShortcutLabel?: string;
  agentAutonomousModeEnabled?: boolean;
  readyForReviewNotificationsEnabled?: boolean;
  commitPromptTemplate?: string;
  openPrPromptTemplate?: string;
  remoteEditorSshHost?: string;   // ← add this
}
```

**b) Add field to `RuntimeConfigState` (line ~26)**

```typescript
export interface RuntimeConfigState {
  // ... existing fields ...
  remoteEditorSshHost: string | null;   // ← add this
}
```

**c) Add field to `RuntimeConfigUpdateInput` (line ~40)**

```typescript
export interface RuntimeConfigUpdateInput {
  // ... existing fields ...
  remoteEditorSshHost?: string | null;   // ← add this
}
```

**d) Add normalizer** — add this pure function near the other `normalize*` helpers (line ~188):

```typescript
function normalizeRemoteEditorSshHost(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}
```

**e) Update `toRuntimeConfigState()`** — add to the returned object (line ~273):

```typescript
remoteEditorSshHost: normalizeRemoteEditorSshHost(globalConfig?.remoteEditorSshHost),
```

**f) Update `createRuntimeConfigStateFromValues()`** — add the field to both the input parameter type and the return statement (line ~449).

**g) Update `writeRuntimeGlobalConfigFile()`** — add `remoteEditorSshHost?: string | null` to the `config` parameter type, normalize it, and include it in `payload` using the same "only write if non-default" pattern as the other fields (i.e., write it when `hasOwnKey(existing, "remoteEditorSshHost") || normalized !== null`).

**h) Update `saveRuntimeConfig()` and `updateRuntimeConfig()` and `updateGlobalRuntimeConfig()`** — thread `remoteEditorSshHost` through each function exactly as the other optional fields are threaded. Follow the same pattern as `commitPromptTemplate`: read from `updates.remoteEditorSshHost ?? current.remoteEditorSshHost`, include in `hasChanges` check, and write through to `writeRuntimeGlobalConfigFile`.

**i) Update `toGlobalRuntimeConfigState()`** — include `remoteEditorSshHost: current.remoteEditorSshHost` in the `createRuntimeConfigStateFromValues` call.

---

### Step 2 — API contract (`src/core/api-contract.ts`)

**a) Add to `runtimeConfigResponseSchema`** (line ~909):

```typescript
export const runtimeConfigResponseSchema = z.object({
  // ... existing fields ...
  remoteEditorSshHost: z.string().nullable(),   // ← add this
});
```

**b) Add to `runtimeConfigSaveRequestSchema`** (line ~929):

```typescript
export const runtimeConfigSaveRequestSchema = z.object({
  // ... existing fields ...
  remoteEditorSshHost: z.string().nullable().optional(),   // ← add this
});
```

---

### Step 3 — API validation (`src/core/api-validation.ts`)

`parseRuntimeConfigSaveRequest` is generated from `runtimeConfigSaveRequestSchema` (Zod `.parse()` / `.safeParse()`). Because the field is `.optional()` in the schema, no change is needed here beyond verifying the parse call includes the new field. Open the file and confirm — if `parseRuntimeConfigSaveRequest` calls `runtimeConfigSaveRequestSchema.parse(input)` directly, nothing further is needed. If it explicitly picks fields, add `remoteEditorSshHost`.

---

### Step 4 — Build the response (`src/terminal/agent-registry.ts`)

In `buildRuntimeConfigResponse()` (line ~110), add to the returned object:

```typescript
remoteEditorSshHost: runtimeConfig.remoteEditorSshHost,
```

---

### Step 5 — Remote URL builder (`web-ui/src/utils/open-targets.ts`)

Add this pure function **after** `buildOpenCommand()` (after line 340):

```typescript
export function buildRemoteEditorUrl(
  sshHost: string,
  workspacePath: string,
  targetId: OpenTargetId,
): string {
  switch (targetId) {
    case "vscode":
      return `vscode://vscode-remote/ssh-remote+${sshHost}${workspacePath}?windowId=_blank`;
    case "vscode-insiders":
      return `vscode-insiders://vscode-remote/ssh-remote+${sshHost}${workspacePath}?windowId=_blank`;
    case "cursor":
      return `cursor://vscode-remote/ssh-remote+${sshHost}${workspacePath}`;
    case "windsurf":
      return `windsurf://vscode-remote/ssh-remote+${sshHost}${workspacePath}`;
    case "zed":
      return `zed://ssh/${sshHost}${workspacePath}`;
    default:
      // For editors without a known remote URL scheme, fall back to VS Code.
      return `vscode://vscode-remote/ssh-remote+${sshHost}${workspacePath}?windowId=_blank`;
  }
}
```

---

### Step 6 — Open workspace hook (`web-ui/src/hooks/use-open-workspace.ts`)

**a) Add `remoteEditorSshHost` parameter** to `UseOpenWorkspaceParams` (line ~17):

```typescript
interface UseOpenWorkspaceParams {
  currentProjectId: string | null;
  workspacePath?: string;
  remoteEditorSshHost?: string | null;   // ← add this
}
```

**b) Import `buildRemoteEditorUrl`** at the top (alongside the existing import from `@/utils/open-targets`).

**c) Rewrite `onOpenWorkspace`** — the remote path comes first; the existing server-command path is the else branch:

```typescript
const onOpenWorkspace = useCallback(() => {
  if (isOpeningWorkspace || !currentProjectId || !workspacePath) {
    return;
  }

  // Remote path: generate a vscode:// URL and open it client-side.
  if (remoteEditorSshHost) {
    const url = buildRemoteEditorUrl(remoteEditorSshHost, workspacePath, selectedOpenTarget.id);
    window.open(url, "_blank");
    return;
  }

  // Local path: run a shell command on the server.
  void (async () => {
    setIsOpeningWorkspace(true);
    try {
      const trpcClient = getRuntimeTrpcClient(currentProjectId);
      const payload = await trpcClient.runtime.runCommand.mutate({
        command: buildOpenCommand(selectedOpenTarget.id, workspacePath, openTargetPlatform),
      });
      if (payload.exitCode !== 0) {
        const details = getFirstOutputLine(payload.combinedOutput) ?? `Exited with code ${payload.exitCode}.`;
        showOpenFailureToast(details);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      showOpenFailureToast(message);
    } finally {
      setIsOpeningWorkspace(false);
    }
  })();
}, [
  currentProjectId,
  isOpeningWorkspace,
  openTargetPlatform,
  remoteEditorSshHost,
  selectedOpenTarget.id,
  showOpenFailureToast,
  workspacePath,
]);
```

---

### Step 7 — Wire config to the hook (`web-ui/src/App.tsx`)

`useOpenWorkspace` is called in `App.tsx`. Find the call site and add `remoteEditorSshHost: config?.remoteEditorSshHost ?? null` to the argument object. `config` is `RuntimeConfigResponse | null` available from the existing config hook already present in `App.tsx`.

---

### Step 8 — Settings dialog UI (`web-ui/src/components/runtime-settings-dialog.tsx`)

**a) Add draft state** near the other `useState` declarations (~line 369):

```typescript
const [remoteEditorSshHost, setRemoteEditorSshHost] = useState<string>("");
```

**b) Seed it from config** in the `useEffect` that runs when `open` changes (~line 515):

```typescript
setRemoteEditorSshHost(config?.remoteEditorSshHost ?? "");
```

**c) Include in `hasUnsavedChanges`** (~line 460) — the initial value comes from `config?.remoteEditorSshHost ?? null`. Add to the check:

```typescript
const initialRemoteEditorSshHost = config?.remoteEditorSshHost ?? null;
// ...in the useMemo:
if ((remoteEditorSshHost.trim() || null) !== initialRemoteEditorSshHost) return true;
```

**d) Include in the `save()` call** (~line 700):

```typescript
const saved = await save({
  // ... existing fields ...
  remoteEditorSshHost: remoteEditorSshHost.trim() || null,
});
```

**e) Update `saveRuntimeConfig` query function** — in `web-ui/src/runtime/runtime-config-query.ts` find the `saveRuntimeConfig` function's input type and add `remoteEditorSshHost?: string | null`.

**f) Add the UI field** — in the **General** section, immediately after the existing Open Workspace editor selector block (search for `openTargetOptions` in the JSX), add a new labelled input group:

```tsx
<div className="mt-3">
  <label
    htmlFor="remote-ssh-host"
    className="block text-[12px] font-semibold uppercase tracking-wider text-text-secondary mb-1"
  >
    SSH Remote Host
  </label>
  <input
    id="remote-ssh-host"
    type="text"
    value={remoteEditorSshHost}
    onChange={(event) => setRemoteEditorSshHost(event.target.value)}
    placeholder="e.g. myserver"
    disabled={controlsDisabled}
    className="h-7 w-full rounded-md border border-border bg-surface-2 px-2 text-xs text-text-primary placeholder:text-text-tertiary focus:border-border-focus focus:outline-none disabled:opacity-40"
  />
  <p className="text-text-secondary text-[12px] mt-1 mb-0">
    SSH alias from your client's <code>~/.ssh/config</code>. When set, "Open in editor" generates a
    remote URL instead of running a command on this server.
  </p>
</div>
```

The Open Workspace editor selector lives inside the General settings card. Search for `openTargetOptions` in the JSX to find exactly where to insert this. It does **not** currently render in `RuntimeSettingsDialog` — that component receives `openTargetOptions` as props but the selector lives in `top-bar.tsx`. You only need to add the SSH host field to the dialog. The existing Open Workspace selector in the top bar does not need to move.

> **Note:** The `save()` call currently in `handleSave` calls `saveRuntimeConfig(workspaceId, { ... })`. Trace `saveRuntimeConfig` in `web-ui/src/runtime/runtime-config-query.ts` (line ~44) — it calls `trpcClient.runtime.saveConfig.mutate(nextConfig)`. Add `remoteEditorSshHost` to the object passed there.

---

## Tests

### Unit tests — `web-ui/src/utils/open-targets.test.ts`

Add a new `describe("buildRemoteEditorUrl")` block to the existing test file. Use Vitest's `it` / `expect` pattern already in use.

```typescript
import { buildOpenCommand, buildRemoteEditorUrl, getOpenTargetOption, getOpenTargetOptions } from "@/utils/open-targets";

// ... existing tests ...

describe("buildRemoteEditorUrl", () => {
  it("builds a VS Code SSH remote URL", () => {
    expect(buildRemoteEditorUrl("myserver", "/home/user/project", "vscode")).toBe(
      "vscode://vscode-remote/ssh-remote+myserver/home/user/project?windowId=_blank",
    );
  });

  it("builds a VS Code Insiders SSH remote URL", () => {
    expect(buildRemoteEditorUrl("myserver", "/home/user/project", "vscode-insiders")).toBe(
      "vscode-insiders://vscode-remote/ssh-remote+myserver/home/user/project?windowId=_blank",
    );
  });

  it("builds a Cursor SSH remote URL", () => {
    expect(buildRemoteEditorUrl("myserver", "/home/user/project", "cursor")).toBe(
      "cursor://vscode-remote/ssh-remote+myserver/home/user/project",
    );
  });

  it("builds a Zed SSH URL", () => {
    expect(buildRemoteEditorUrl("myserver", "/home/user/project", "zed")).toBe(
      "zed://ssh/myserver/home/user/project",
    );
  });

  it("falls back to VS Code URL for editors without a remote scheme", () => {
    // "finder" and terminal-style editors have no remote URL scheme.
    expect(buildRemoteEditorUrl("myserver", "/home/user/project", "finder")).toBe(
      "vscode://vscode-remote/ssh-remote+myserver/home/user/project?windowId=_blank",
    );
  });

  it("preserves paths with spaces", () => {
    const url = buildRemoteEditorUrl("myserver", "/home/user/my project", "vscode");
    expect(url).toBe(
      "vscode://vscode-remote/ssh-remote+myserver/home/user/my project?windowId=_blank",
    );
  });

  it("handles a host alias that contains hyphens", () => {
    expect(buildRemoteEditorUrl("dev-box-42", "/srv/app", "cursor")).toBe(
      "cursor://vscode-remote/ssh-remote+dev-box-42/srv/app",
    );
  });
});
```

Run with: `npm run test -- open-targets`

---

### Unit tests — `web-ui/src/hooks/use-open-workspace.ts`

Create a new file `web-ui/src/hooks/use-open-workspace.test.ts`. Pattern: use `renderHook` from `@testing-library/react` and spy on `window.open` and the tRPC `runCommand` mutate.

```typescript
import { renderHook, act } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOpenWorkspace } from "@/hooks/use-open-workspace";

// Mock tRPC so we can assert it is/isn't called.
const runCommandMock = vi.fn(async () => ({ exitCode: 0, combinedOutput: "" }));
vi.mock("@/runtime/trpc-client", () => ({
  getRuntimeTrpcClient: () => ({
    runtime: {
      runCommand: { mutate: runCommandMock },
    },
  }),
}));

// Suppress sonner toast in unit tests.
vi.mock("sonner", () => ({ toast: { error: vi.fn() } }));
vi.mock("@/components/app-toaster", () => ({ showAppToast: vi.fn() }));

describe("useOpenWorkspace — remote path", () => {
  let openSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    openSpy = vi.spyOn(window, "open").mockImplementation(() => null);
    runCommandMock.mockClear();
  });

  afterEach(() => {
    openSpy.mockRestore();
  });

  it("calls window.open with a vscode remote URL when remoteEditorSshHost is set", async () => {
    const { result } = renderHook(() =>
      useOpenWorkspace({
        currentProjectId: "proj-1",
        workspacePath: "/home/user/myrepo",
        remoteEditorSshHost: "myserver",
      }),
    );

    await act(async () => {
      result.current.onOpenWorkspace();
    });

    expect(openSpy).toHaveBeenCalledWith(
      "vscode://vscode-remote/ssh-remote+myserver/home/user/myrepo?windowId=_blank",
      "_blank",
    );
    expect(runCommandMock).not.toHaveBeenCalled();
  });

  it("calls runCommand (not window.open) when remoteEditorSshHost is null", async () => {
    const { result } = renderHook(() =>
      useOpenWorkspace({
        currentProjectId: "proj-1",
        workspacePath: "/home/user/myrepo",
        remoteEditorSshHost: null,
      }),
    );

    await act(async () => {
      result.current.onOpenWorkspace();
    });

    expect(runCommandMock).toHaveBeenCalledTimes(1);
    expect(openSpy).not.toHaveBeenCalled();
  });

  it("does nothing when workspacePath is missing", async () => {
    const { result } = renderHook(() =>
      useOpenWorkspace({
        currentProjectId: "proj-1",
        workspacePath: undefined,
        remoteEditorSshHost: "myserver",
      }),
    );

    await act(async () => {
      result.current.onOpenWorkspace();
    });

    expect(openSpy).not.toHaveBeenCalled();
    expect(runCommandMock).not.toHaveBeenCalled();
  });
});
```

Run with: `npm run test -- use-open-workspace`

---

### Settings dialog test — `web-ui/src/components/runtime-settings-dialog.test.tsx`

Add one new test to the existing `describe("RuntimeSettingsDialog")` block. The existing `savedClineOauthConfig` fixture does not include `remoteEditorSshHost` — extend it or use `as unknown as RuntimeConfigResponse` with the field present. Add the test at the end of the describe block:

```typescript
it("seeds SSH host from config and enables save on change", async () => {
  const configWithSshHost = {
    ...savedClineOauthConfig,
    remoteEditorSshHost: "staging-server",
  } as unknown as RuntimeConfigResponse;

  const handleOpenChange = vi.fn();
  await act(async () => {
    root.render(
      <RuntimeSettingsDialog
        open={true}
        workspaceId={"workspace-1"}
        initialConfig={configWithSshHost}
        onOpenChange={handleOpenChange}
      />,
    );
  });

  const sshInput = document.querySelector<HTMLInputElement>("#remote-ssh-host");
  expect(sshInput).toBeInstanceOf(HTMLInputElement);
  expect(sshInput?.value).toBe("staging-server");

  const saveButton = findButtonByText(document.body, "Save");
  expect(saveButton?.disabled).toBe(true);  // no unsaved changes yet

  await act(async () => {
    if (sshInput) {
      sshInput.value = "new-server";
      sshInput.dispatchEvent(new Event("input", { bubbles: true }));
      // React uses onChange, not oninput — fire a change event
      const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype,
        "value",
      )?.set;
      nativeInputValueSetter?.call(sshInput, "new-server");
      sshInput.dispatchEvent(new Event("change", { bubbles: true }));
    }
  });

  expect(saveButton?.disabled).toBe(false);
});
```

> **Note for the implementor**: React synthetic `onChange` fires on the `change` event in jsdom. If the above event approach doesn't trigger the React handler, use `@testing-library/user-event` (`userEvent.type(sshInput, "x")`) which is already available in the project.

Run with: `npm run test -- runtime-settings-dialog`

---

### Config round-trip test — `src/config/runtime-config.ts`

There may not be an existing test file for `runtime-config.ts`. If `test/` contains a relevant suite, add a case there. Otherwise create `test/runtime/config/runtime-config.test.ts` following the patterns in `test/runtime/`:

```typescript
import { describe, expect, it } from "vitest";
// Import only the pure helpers that don't touch the filesystem:
// normalizeRemoteEditorSshHost is not exported, so test via the public API.
// Use toRuntimeConfigState (if exported) or loadRuntimeConfig with a temp dir.

// Minimal test: confirm the field round-trips through JSON serialisation.
it("normalizes remoteEditorSshHost: trims whitespace and treats empty as null", () => {
  // Access via the public RuntimeConfigState shape by exercising loadRuntimeConfig
  // against a temp config file. Use the existing test helpers in test/runtime/ for
  // creating temp config dirs if available; otherwise use node:fs/promises + tmp.
  //
  // If an existing test fixture already bootstraps a config file, simply add
  // { remoteEditorSshHost: "  myserver  " } to that fixture and assert the loaded
  // state has remoteEditorSshHost === "myserver".
  //
  // If no fixture exists, skip this test and rely on the unit tests above.
  expect(true).toBe(true); // placeholder — replace with real assertion
});
```

---

## Verification checklist

Before marking this complete, confirm each item:

- [ ] `npm run typecheck` passes with zero errors.
- [ ] `npm run lint` passes with zero warnings/errors.
- [ ] `npm run test` passes (all existing tests still green; new tests added and green).
- [ ] Open Settings → General: "SSH Remote Host" input appears, is empty by default, and Save is disabled.
- [ ] Type a host name, click Save: Save succeeds, dialog closes.
- [ ] Reopen Settings: the host field is pre-populated with the saved value.
- [ ] With the host set, click Open in VS Code on any workspace: browser opens a `vscode://vscode-remote/ssh-remote+{host}{path}?windowId=_blank` URL (visible in browser address bar / URL preview on hover).
- [ ] Clear the host field (save empty string), click Open in VS Code: falls back to server-side `runCommand` (check browser dev-tools network tab for the tRPC call).
- [ ] Config file on disk (`~/.cline/kanban/config.json`) contains `"remoteEditorSshHost": "myserver"` when set and the key is absent when cleared.

---

## File change summary

| File | Nature of change |
|------|-----------------|
| `src/config/runtime-config.ts` | Add field to types, normalizer, all read/write paths |
| `src/core/api-contract.ts` | Add field to response schema and save-request schema |
| `src/core/api-validation.ts` | Verify `parseRuntimeConfigSaveRequest` passes the new field |
| `src/terminal/agent-registry.ts` | Pass field through in `buildRuntimeConfigResponse` |
| `web-ui/src/utils/open-targets.ts` | Add `buildRemoteEditorUrl()` |
| `web-ui/src/hooks/use-open-workspace.ts` | Accept param; branch on remote vs local |
| `web-ui/src/runtime/runtime-config-query.ts` | Add field to `saveRuntimeConfig` input type |
| `web-ui/src/App.tsx` | Pass `remoteEditorSshHost` to `useOpenWorkspace` |
| `web-ui/src/components/runtime-settings-dialog.tsx` | State, seeding, hasUnsavedChanges, save call, input UI |
| `web-ui/src/utils/open-targets.test.ts` | New `describe` block for `buildRemoteEditorUrl` |
| `web-ui/src/hooks/use-open-workspace.test.ts` | New test file |
| `web-ui/src/components/runtime-settings-dialog.test.tsx` | One new test case |

No new npm packages are required.
