# Unified Notification Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every clickable Linux and Windows notification through `steam://steam-native-notify/notification/<envelope>` so exact replay remains available during the Steam session and verified fallback survives Steam restart.

**Architecture:** The existing click envelope remains the only durable payload. Windows stores its URL directly in WinRT; Linux launches the same URL from the live FreeDesktop action and gives Quattro a persisted argv hint containing that URL. Steam owns dispatch, choosing the captured callback or live-focus fallback.

**Tech Stack:** TypeScript, Millennium SteamClient URL API, POSIX shell, libnotify, GDBus, Windows PowerShell 5.1, WinRT toast XML, Bun test scripts

**Spec:** `docs/superpowers/specs/2026-09-05-unified-notification-activation-design.md`

## Global Constraints

- canonical URL: `steam://steam-native-notify/notification/<base64url-envelope>`
- do not accept or emit legacy `steam://snn/...` URLs
- keep the version-1 envelope and its validation unchanged
- keep exact callbacks RAM-only, capped at 256, with no time expiry
- persist no arbitrary shell command and perform no shell evaluation of the URL
- leave notifications without a proved callback or verified fallback inert
- preserve the five-position frontend/backend/helper RPC contract
- require a full Steam restart after any packed-plugin change

---

### Task 1: Canonical Steam URL contract

**Files:**
- Modify: `frontend/click.ts`
- Modify: `frontend/steamurl.ts`
- Modify: `tools/test-frontend`

**Interfaces:**
- Produces: `STEAM_URL_SECTION`, `steamNotificationUrl(encoded: string): string`, and `clickEnvelopeFromSteamUrl(url: string): ClickEnvelope | null`
- Consumes: `encodeClickEnvelope(value: unknown): string` and `dispatchClick(envelope: ClickEnvelope): Promise<void>`

- [ ] **Step 1: Add failing canonical URL tests**

Add assertions equivalent to:

```ts
is(
  'canonical notification URL round trips',
  JSON.stringify(click.clickEnvelopeFromSteamUrl(
    `steam://steam-native-notify/notification/${encoded}`,
  )),
  JSON.stringify(envelope),
);
is(
  'canonical single-slash URL round trips',
  JSON.stringify(click.clickEnvelopeFromSteamUrl(
    `steam:/steam-native-notify/notification/${encoded}/`,
  )),
  JSON.stringify(envelope),
);
is(
  'canonical URL formats once',
  click.steamNotificationUrl(encoded),
  `steam://steam-native-notify/notification/${encoded}`,
);
is(
  'legacy snn URL is refused',
  click.clickEnvelopeFromSteamUrl(`steam://snn/click/${encoded}`),
  null,
);
```

- [ ] **Step 2: Run the frontend test and confirm the new cases fail**

Run: `bun tools/test-frontend`

Expected: failures for the missing formatter and old URL grammar.

- [ ] **Step 3: Implement the canonical formatter and parser**

Keep the namespace in one module:

```ts
export const STEAM_URL_SECTION = 'steam-native-notify';
export const STEAM_URL_RESOURCE = 'notification';

export function steamNotificationUrl(encoded: string): string {
  if (!ENCODED.test(encoded) || encoded.length > 8192) return '';
  return `steam://${STEAM_URL_SECTION}/${STEAM_URL_RESOURCE}/${encoded}`;
}

export function clickEnvelopeFromSteamUrl(url: string): ClickEnvelope | null {
  const match = /^steam:\/{1,2}steam-native-notify\/notification\/([A-Za-z0-9_-]+)\/?$/
    .exec(String(url).trim());
  return match ? decodeClickEnvelope(match[1]) : null;
}
```

Register `STEAM_URL_SECTION` in `frontend/steamurl.ts`, update the health log,
and describe the handler as cross-platform rather than Windows-only.

- [ ] **Step 4: Run the frontend test**

Run: `bun tools/test-frontend`

Expected: `PASS`.

- [ ] **Step 5: Review the task diff**

Run: `git diff --check && git diff -- frontend/click.ts frontend/steamurl.ts tools/test-frontend`

Expected: only the canonical URL contract and its tests change.

---

### Task 2: Durable Linux activation

**Files:**
- Modify: `tools/notify-action`
- Modify: `tools/test-backend`

**Interfaces:**
- Consumes: route slot `click:<base64url-envelope>`
- Produces: canonical URL passed as one argument to `steam`
- Produces on Quickshell: `omarchy-exec-argv` JSON argv hint

- [ ] **Step 1: Replace click-file expectations with URL expectations**

Shim `steam`, `notify-send`, and `gdbus`. Assert the helper passes this as the
sole argument after `steam`:

```text
steam://steam-native-notify/notification/<encoded>
```

Assert that an empty, malformed, or non-`click:` route adds no action and
launches nothing. Assert that no `.click` file is created.

- [ ] **Step 2: Add failing Quickshell hint and timeout tests**

Make the GDBus shim return this for `GetServerInformation`:

```text
ssss "quickshell" "quickshell" "" "1.2"
```

Assert notify-send receives:

```text
-h
string:omarchy-exec-argv:["steam","steam://steam-native-notify/notification/<encoded>"]
-t
30000
```

Make another daemon response and assert the Omarchy hint is absent while the
standard default action remains.

- [ ] **Step 3: Run backend tests and confirm the new cases fail**

Run: `tools/test-backend`

Expected: failures for URL launch, Quickshell argv persistence, and timeout.

- [ ] **Step 4: Add strict route-to-URL conversion**

Implement a pure shell seam used by delivery and tests:

```sh
notification_url() {
  payload=${1#click:}
  [ "$payload" != "$1" ] || return 1
  case $payload in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#payload}" -le 8192 ] || return 1
  printf 'steam://steam-native-notify/notification/%s\n' "$payload"
}
```

Expose it as `--notification-url <route>`. Attach `-A default=Open` only when
this seam succeeds.

- [ ] **Step 5: Add Quickshell capability routing**

Call `GetServerInformation` and match server name `quickshell`. Append this as
one notify-send argument:

```sh
-h "string:omarchy-exec-argv:[\"steam\",\"$activation_url\"]"
```

The payload alphabet excludes JSON metacharacters. Other daemons receive no
vendor hint. Set `EXPIRE=30000`; do not mark ordinary Steam events critical.

- [ ] **Step 6: Launch the canonical URL after a live action**

After notify-send prints `default`, run:

```sh
steam "$activation_url" >/dev/null 2>&1 &
```

Refuse and log when `steam` is absent. Remove the click-file write path from
the helper without removing the backend's consume-once `TakeClick` seam yet.

- [ ] **Step 7: Run backend tests**

Run: `tools/test-backend`

Expected: `PASS`.

- [ ] **Step 8: Review the task diff**

Run: `git diff --check && git diff -- tools/notify-action tools/test-backend`

Expected: Linux delivery changes only.

---

### Task 3: Canonical Windows activation

**Files:**
- Modify: `tools/notify-action.ps1`
- Modify: `tools/test-windows-notify-action.ps1`

**Interfaces:**
- Consumes: route slot `click:<base64url-envelope>`
- Produces: WinRT `launch="steam://steam-native-notify/notification/<envelope>"`

- [ ] **Step 1: Change the PowerShell source assertion first**

Require this activation shape:

```powershell
steam://steam-native-notify/notification/$($Matches[1])
```

Reject any remaining `steam://snn/` string in the helper.

- [ ] **Step 2: Run the Windows source test and confirm failure**

Run on Windows:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/test-windows-notify-action.ps1`

Expected: the canonical activation assertion fails.

- [ ] **Step 3: Update WinRT activation XML**

Change only the protocol URI and comments. Keep route validation, WinRT
delivery, AUMID setup, image conversion, and focus helper unchanged.

- [ ] **Step 4: Run the Windows source test**

Run the command from Step 2.

Expected: every assertion prints `PASS`.

- [ ] **Step 5: Review the task diff**

Run: `git diff --check && git diff -- tools/notify-action.ps1 tools/test-windows-notify-action.ps1`

Expected: Windows changes only the canonical URI and coverage.

---

### Task 4: Align documentation

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/architecture.md`
- Modify: `docs/platforms.md`
- Modify: `docs/experiments/click-replay.md`
- Modify: older plans/specs where they claim current URL or Linux behavior

**Interfaces:**
- Consumes: completed behavior from Tasks 1 through 3
- Produces: current architecture, platform matrix, and test instructions

- [ ] **Step 1: Find obsolete claims**

Run:

```sh
rg -n 'steam://snn|/click/<|\.click.*Linux|Linux keeps the click file' \
  AGENTS.md docs frontend tools
```

- [ ] **Step 2: Update current behavior**

Document the canonical notification URL, Linux live URL launch, Quattro fixed
argv adapter, RAM-only exact callbacks, restart fallback, and arbitrary-daemon
reboot limitation. Historical documents may describe old behavior only when
labeled historical.

- [ ] **Step 3: Check consistency**

Run:

```sh
rg -n 'steam://snn|steam://steam-native-notify/click' AGENTS.md docs frontend tools
rg -n 'TBD|TODO|FIXME' docs/superpowers/specs/2026-09-05-unified-notification-activation-design.md
git diff --check
```

Expected: no active legacy URL or placeholder remains.

---

### Task 5: Run the offline gate and install

**Files:**
- Verify all modified files

**Interfaces:**
- Consumes: Tasks 1 through 4
- Produces: installed `.star` and offline evidence

- [ ] **Step 1: Run type checking**

Run: `bun run typecheck`

Expected: exit 0.

- [ ] **Step 2: Run all offline tests**

Run: `bun run test`

Expected: each suite ends `PASS`.

- [ ] **Step 3: Pack and install**

Run: `bun run build`

Expected: Starlight writes
`~/.local/share/millennium/plugins/me.tysmith.steam-native-notify.star`.

- [ ] **Step 4: Check the completed diff**

Run: `git diff --check && git status --short`

Expected: only planned files plus the pre-existing untracked `.agents/` path.

---

### Task 6: Verify Linux runtime behavior

**Files:**
- Verify installed plugin and runtime files
- Modify: `docs/platforms.md` with measured results

**Interfaces:**
- Consumes: installed `.star`, `tools/capture`, `tools/fire`
- Produces: runtime evidence for exact replay and durable fallback

- [ ] **Step 1: Restart Steam fully**

Use the documented shutdown, bounded TERM/KILL recovery if needed, and UWSM
launch sequence. Never use broad `pkill -f` patterns.

- [ ] **Step 2: Confirm the running artifact**

Run: `tools/capture`

Expected: current `.star`, plugin load, popup hook, identity, URL store, and
`steam-url: registered steam://steam-native-notify/notification/<payload>`.

- [ ] **Step 3: Verify exact replay without mouse automation**

Fire FriendOnline and Achievement separately. Inspect Quattro's newest history
JSON for the canonical two-element `execArgv`, then execute that exact argv.
Expected log: `steam-url: click`, `replay: invoke`, and `click-bridge: replay`.

- [ ] **Step 4: Verify fallback after Steam restart**

Keep one persisted Quattro argv, restart Steam, then execute it. Expected log:
`steam-url: click`, `replay: invoke ... no stash entry`, and
`click-bridge: fallback <route>` followed by navigation and focus evidence.

- [ ] **Step 5: Verify Linux cold start**

Shut Steam down fully and execute a persisted Achievement argv. Expected:
Steam starts, URL registration receives the queued activation, and the catalog
fallback navigates after the main window appears.

- [ ] **Step 6: Record limits**

Record direct observations. Leave UI-click, shell/login restart, host reboot,
and real in-game focus pending when they need the absent user or disruptive
host control.

---

### Task 7: Verify Windows runtime behavior

**Files:**
- Copy the installed artifact through the existing VM test path
- Modify: `docs/platforms.md` with measured results

**Interfaces:**
- Consumes: Windows VM, existing SSH/relay control, PowerShell tests
- Produces: WinRT live/history and restart evidence

- [ ] **Step 1: Confirm noninteractive VM control**

Use `omarchy-windows-vm status` and the existing SSH bootstrap. Do not request
sudo when direct Docker access works.

- [ ] **Step 2: Run Windows helper tests**

Run `tools/test-windows-notify-action.ps1` inside the VM.

Expected: every assertion prints `PASS`.

- [ ] **Step 3: Install and restart Steam**

Copy the current `.star`, restart Steam, and confirm the Windows log names the
canonical URL registration before firing notifications.

- [ ] **Step 4: Exercise protocol delivery**

Fire FriendOnline and Achievement. Use protocol invocation and logs to verify
exact replay while Steam runs and fallback after Steam restart or full stop.
Do not synthesize mouse clicks while the user is away.

- [ ] **Step 5: Measure guest reboot persistence**

Reboot the guest only. If Windows retains a notification-center row, leave its
UI click for the user's visual confirmation. Record whether the row survived;
do not infer persistence from a new notification.

---

### Task 8: Final review and commits

**Files:**
- Review the complete diff

**Interfaces:**
- Consumes: implementation and verification evidence
- Produces: reviewable commits without unrelated `.agents/` content

- [ ] **Step 1: Review correctness and scope**

Inspect each changed file for legacy URLs, shell interpolation, unbounded
payloads, wrong-surface replay, and documentation overclaims.

- [ ] **Step 2: Re-run the offline gate after review edits**

Run: `bun run typecheck && bun run test && bun run build`

Expected: every command succeeds and the installed bundle is current.

- [ ] **Step 3: Commit coherent changes**

Create separate conventional commits for implementation and measured runtime
documentation. Stage exact paths; never add `.agents/`.
