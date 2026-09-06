# Windows testing

Windows delivery ships and is marked EXPERIMENTAL (`backend/main.lua:517`,
README "Limits"). `docs/platforms.md`, "Windows", records the design and
the first validation pass in a VM; this document is the repeatable version
of that pass, the specification for a test suite that would make most of it
automatic, and what CI could run.

Three parts: the manual and semi-automated gate list a tester walks to
validate a build (Part 1), the suite spec that takes `frontend/`,
`backend/main.lua` and `tools/notify-action.ps1` to 90% line coverage
(Part 2), and the automation shape (Part 3).

The live tier — firing, toast-DB and UI-Automation oracles, clicking
without a human — lives in `tests/windows/`; Part 1 names the gates it can
run and Part 3 names where it fits in CI. The developer tools have Windows
twins: `tools/fire.ps1`, `tools/capture.ps1` and `tools/mep.ps1`, with the
same subcommands and output vocabulary as their bash originals. All three
need PowerShell 7 (`pwsh`), unlike `tools/notify-action.ps1`, which needs
Windows PowerShell 5.1 and nothing else.

---

## Part 1 — The Windows test plan

### The Windows facts every gate depends on

| fact | value |
|---|---|
| Runtime directory | `%LOCALAPPDATA%\steam-native-notify` (`backend/main.lua:65-77`) |
| Plugin log | `<runtime>\plugin.log`, truncated at each backend load (`backend/main.lua:485-490`) |
| Helper | `<runtime>\notify-action.ps1`, re-materialized at every load (`backend/main.lua:81-82`, `115-134`) |
| Installed bundle | `<Steam>\millennium\plugins\me.tysmith.steam-native-notify.star`; `<Steam>` is the `steam-dir` the backend publishes, falling back to `HKCU\Software\Valve\Steam` only before the backend has ever run, and never to a hardcoded guess (`tools/lib/snn.ps1:73-109`) |
| AUMID | `me.tysmith.steam-native-notify`, `HKCU\Software\Classes\AppUserModelId\...` (`tools/notify-action.ps1:33-34`, `61-91`) |
| Toast DB | `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` (copy the `.db`, `-wal` and `-shm` together; a live read misses recent rows) |
| Shell for the helper | Windows PowerShell 5.1 only — pwsh 6+ removed WinRT projection (`tools/notify-action.ps1:5-6`, `backend/main.lua:185-196`) |
| Shell for the dev tools | `pwsh` 7 only — `tools/mep.ps1` needs `UnixDomainSocketEndPoint` (`tools/mep.ps1:26-29`); each tool refuses 5.1 in one line (`tools/lib/snn.ps1:38-45`) |

**There is no Millennium loader log on Windows.** Steam's
`console_log.txt` carries no plugin lines here (Millennium logs to its own
console window), so `tools/capture.ps1` dates the running build from the
first `backend loaded` line in `plugin.log` instead
(`tools/capture.ps1:15-20`, `77-90`). Under the `.star` format a backend
load only happens on a full Steam start, so that line dates the running
frontend just as the loader stamp does on Linux.

Two rules carry over from Linux and are the source of most wrong verdicts:

- **Confirm the running bundle before diagnosing anything.**
  `pwsh tools/capture.ps1` says so first; a stale `.star` is
  indistinguishable from a broken feature (AGENTS.md, "Hard constraints").
- **A full Steam restart is required for any change, backend included.**
  `plugin.restart` and disable/enable leave the backend stopped under the
  `.star` format.

### Known Windows-build issues (check these before blaming a gate)

- **A panel named `frontend/Settings.tsx` collides with
  `frontend/settings.ts` on a case-insensitive filesystem**, and a tree
  carrying both fails `bun run build` on Windows for that reason alone. The
  panel is `frontend/SettingsPanel.tsx` (imported at
  `frontend/index.tsx:8`), and `tsconfig.json:8` sets
  `forceConsistentCasingInFileNames`, so `tsc` reports the collision as a
  type error rather than leaving it to the pack step. A build failure
  naming both files means the tree predates the rename.
- **`tools/test-backend` assumes POSIX `mktemp` and `/tmp`**
  (`tools/test-backend:12-20`) and does not run in Git Bash on Windows.
  Under WSL it passes: `wsl -d Ubuntu -e bash -lc 'cd
  /mnt/c/<path>/steam-native-notify && tools/test-backend'`.
- **The 64-bit SteamRT3 Linux client does not work** (Millennium #840) —
  irrelevant on Windows, but the same symptom (`hook installed` plus zero
  toast lines) is what a genuinely dead hook looks like here too.

- **The click file plays no part on Windows.** `TakeClick` and the poll in
  `frontend/clickbridge.ts` exist on every platform and the frontend arms
  the bridge after each delivery (`frontend/index.tsx:192`), but nothing
  writes `<runtime>\.click` here: `tools/notify-action.ps1` has no click
  writer, and a click arrives as a `steam-url:` line instead
  (`frontend/steamurl.ts:63-65`). A `click-bridge:` line on Windows means
  something outside the plugin wrote that file.

### Prerequisites

Everything below assumes all of this. A gate that fails because one of
these is missing is not a plugin result.

| need | check |
|---|---|
| Millennium 3.5 or newer (beta is fine) | `pwsh tools/mep.ps1 millennium.version` |
| Steam installed and **signed in**, and running | `pwsh tools/capture.ps1` reaches section 2 |
| The plugin enabled under Millennium > Plugins | `pwsh tools/mep.ps1 plugin.status name=me.tysmith.steam-native-notify` reports `running: true` |
| PowerShell 7 for the dev tools | `pwsh -v`; every tool refuses to run under 5.1 with one line and exit 1 (`tools/lib/snn.ps1:38-45`) |
| Windows PowerShell 5.1 present for the helper | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` (it ships with Windows) |
| Branch `windows-build` or later checked out | `frontend/SettingsPanel.tsx` exists, `frontend/Settings.tsx` does not |
| `bun` on PATH, `bun install` done | `bun run typecheck` exits 0 |
| WSL with Ubuntu and `lua5.4`, for the backend suite only | `wsl -d Ubuntu -e lua5.4 -v` |

**Reading the log.** Every gate below that asserts a `plugin.log` line is
read with:

    Get-Content $env:LOCALAPPDATA\steam-native-notify\plugin.log -Tail 30

Add `-Wait` to follow it live while firing. `pwsh tools/capture.ps1` shows
the same lines filtered to the ones that matter, and answers the
staleness question first; use the raw tail when a gate needs a line
`capture.ps1` does not grep.

### The gates

Ordered: a failure at gate N makes every later gate meaningless. Each gate
names its precondition, the action, the expected `plugin.log` line, and
what counts as a pass. Lines marked **Evidence** are from the validation
run of 2026-09-05 on a 64-bit Windows Steam client.

Each gate is marked **automated** or **manual**. Automated means
`tests/windows/run.ps1` asserts it; the harness runs one scenario
(`download-complete`) against the live client, prints PASS/FAIL per
assertion and exits with the failure count
(`tests/windows/README.md`). Its coverage in one line:

| gate | who runs it |
|---|---|
| G1 build, G2 load, G3 hook | manual — `run.ps1` never builds and never restarts Steam |
| G4 delivery, client | **automated** — `pwsh -File tests/windows/run.ps1 -Click none` |
| G5 delivery, server | manual — no server scenario exists; a new one is a hashtable in `tests/windows/scenarios/` |
| G6 text and artwork | **automated** for the recorded XML (title, body, `appLogoOverride` src, `hint-crop`); manual for "does a human see it" |
| G7 banner click | **automated** — `pwsh -File tests/windows/run.ps1` (the default) |
| G8 Notification Center click | **automated** — `pwsh -File tests/windows/run.ps1 -Click center`, or `-Click both` to click the banner first |
| G9 in-game, G10 fullscreen/DND, G11 toggles | manual — the harness fires desktop toasts only and changes no settings |
| G12 real event | manual — nobody automates a 0.89 GB download |
| G13 teardown | manual |
| G14 update smoke | manual, but `run.ps1 -Click none` is the fastest way to produce the `replay: candidates` line it reads |

`pwsh -File tests/windows/run.ps1 -FailDemo` poisons one expectation on
purpose, which is how to confirm the harness reports FAIL honestly before
trusting a PASS. `-Scenario <name>` selects a file in
`tests/windows/scenarios/` (an unknown name exits 2 and lists the ones that
exist). Each assertion prints `PASS`, `FAIL` or `WARN` — `WARN` marks a
condition that explains a later failure without being one, such as a game
running or a single unanswered `dev-fire:` — and the exit code is the
number of `FAIL`s. The run refuses to fire at all when its pre-check finds
Steam's toast queue stalled after a long test session; `-IgnoreQueueStall`
overrides that (`tests/windows/README.md`).

#### G1 — Build on Windows

- **Precondition:** a clone of the branch under test, `bun install` done.
- **Action:** `bun run typecheck`, then `bun run build`.
- **Expect:** typecheck silent; starlight writes
  `<Steam>\millennium\plugins\me.tysmith.steam-native-notify.star`
  (`millennium.toml:29-32`, `output_path = "auto"`, so building is
  installing).
- **Pass:** both exit 0 and the `.star` mtime is now.
- **Fail modes:** the `Settings.tsx`/`settings.ts` collision above; a
  `.star` under 20 KB (the size floor `.github/workflows/build.yml:43-54`
  enforces) means the frontend or an asset fell out of the bundle.
- **Note:** `bun run build` overwrites the *running* plugin. On a machine
  mid-validation, build first and restart once, never build to "just
  typecheck" — use `bun run typecheck`. `tools/capture.ps1` answers "would
  a build change anything" without rebuilding: its `sources` line names the
  newest build input in the working tree and warns when that is newer than
  the installed `.star`. The inputs it compares are whatever
  `millennium.toml` names — the `[frontend]` and `[backend]` source roots
  plus every `[assets]` path — so a new source root needs no edit to the
  tool (`tools/capture.ps1:92-119`).

#### G2 — Install, enable, and load

- **Precondition:** G1. Steam fully stopped.
- **Action:** start Steam; enable **Steam Native Notify** under Millennium
  > Plugins if it is not already; restart Steam fully.
- **Expect,** in order, in `plugin.log`:

      backend loaded
      platform: windows runtime: C:\Users\<user>\AppData\Local\steam-native-notify
      helper: C:\Users\<user>\AppData\Local\steam-native-notify\notify-action.ps1
      windows delivery is EXPERIMENTAL and unvalidated -- docs/platforms.md lists the checks
      setup: AUMID branding registered

- **Pass:** all five present, in that order, with no `error` line between
  them.
- **Fail modes:** `helper install FAILED: <reason>` — the asset could not
  be written (`backend/main.lua:509-515`). `ffi unavailable in this Lua
  host` — the Millennium build has no LuaJIT ffi and Windows delivery
  cannot work at all (`backend/main.lua:190-193`). `helper -Setup could not
  run` — `CreateProcessW` failed (`backend/main.lua:519-522`); toasts will
  be unbranded but may still deliver. Missing `setup: AUMID branding
  registered` with no error means the helper started and died before its
  first log write — run it by hand:

      & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -NoProfile -ExecutionPolicy Bypass `
        -File "$env:LOCALAPPDATA\steam-native-notify\notify-action.ps1" -Setup

- **Also assert:**
  `HKCU:\Software\Classes\AppUserModelId\me.tysmith.steam-native-notify`
  has `DisplayName` = `Steam`, and `IconUri` pointing at
  `<runtime>\steam.ico`. Icon extraction is cosmetic and may legitimately
  be absent — `tools/notify-action.ps1:71-84` logs `setup: icon extraction
  failed` and leaves DisplayName-only branding.

#### G3 — Hook attach and click-path registration

- **Precondition:** G2.
- **Action:** `pwsh tools/capture.ps1` (optionally
  `pwsh tools/capture.ps1 20` for more notification lines; the default is
  8), then read the registration line out of the log directly:

      Get-Content $env:LOCALAPPDATA\steam-native-notify\plugin.log |
        Select-String 'hook installed|steam-url: registered'

- **Expect:** section 1 prints `built`, `sha256`, `loaded`, then
  `current.`, followed by the `sources` line; the log carries

      hook installed
      steam-url: registered steam://snn/replay/<toast>

- **Pass:** `current.` and both lines present.
- `capture.ps1`'s section 2 is the convenience form of the same two lines:
  its filter greps `hook installed|hook failed|g_PopupManager never
  appeared|helper|steam-url: registered` — the `Startup` entry of the
  prefix table in `tools/lib/snn.ps1:29-36`, consumed at
  `tools/capture.ps1:127` — and shows the last six matches. The direct
  read above is what a gate asserts,
  because it does not depend on that filter keeping the prefix or on six
  being enough lines.
- **Fail modes:** `STALE — Steam is running an older build` — restart Steam
  and re-run before reading anything else. `loaded (never)` — the plugin is
  not enabled, or the backend never loaded. `g_PopupManager never appeared;
  bridge inactive` — the popup manager moved or was renamed
  (`frontend/index.tsx:231-241`). `hook failed: <reason>`
  (`frontend/index.tsx:247-249`). `steam-url: RegisterForRunSteamURL
  unavailable; no steam:// click path` — the client is too old for the URL
  API and **every later click gate is expected to fail**
  (`frontend/steamurl.ts:52-55`). `capture.ps1` itself exits 1 with `No
  Steam install found` when the registry has no `SteamPath`
  (`tools/capture.ps1:57-60`).

#### G4 — Delivery, client-sourced toast

- **Precondition:** G3, and the `devFire` and `devMode` settings on:

      pwsh tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=devMode value=true
      pwsh tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=devFire value=true

  `mep.ps1` parses each `key=value` as JSON when it can, so `value=true`
  arrives as a boolean. **Exit codes: 0 on success, 1 on every failure.**
  That covers a reply carrying an `error` key, a call that never reaches
  Millennium (a missing socket, a refused connection, a bad `key=value`
  token) and the refusal to run under Windows PowerShell 5.1 alike
  (`tools/mep.ps1:20-23`, `208-221`; the version guard is
  `tools/lib/snn.ps1:38-45`); `--help` and `--methods` exit 0. A
  script that needs to tell "Steam is not up" from "Millennium said no"
  has to read the stderr line or the JSON, not the exit code.
  `pwsh tools/mep.ps1 plugin.config.get_all name=me.tysmith.steam-native-notify`
  reads the whole store back.
- **Action:** `pwsh tools/fire.ps1 TestDownloadComplete 1073390` (Aircar;
  the appid is required — a bare `TestDownloadComplete` is silently refused
  by Steam). The script prints `queued: TestDownloadComplete [1073390]
  (needs the tools/fire toggle on in the plugin settings; picked up within
  ~3s)`, and exits 1 with `not installed: <path>` if the `.star` is missing
  (`tools/fire.ps1:66-74`) — "queued" alone never means delivered.
- **Expect,** within ~3 s of the fire plus the paint poll:

      dev-fire: NotificationStore.TestDownloadComplete([1073390])
      replay: candidates notificationtoasts_<N>_desktop n=5 stashed=onClick@15 (twin)
      from-toast notificationtoasts_<N>_desktop type=1 source=client array=[1073390,0]
      toast notificationtoasts_<N>_desktop -> {"title":"Download Complete","body":"Aircar — Your game is ready to play","image":"https://steamloopback.host/assets/1073390/...jpg","type":1,"route":"replay:notificationtoasts_<N>_desktop"}

  and a Windows toast branded "Steam" carrying the Aircar library art.
- **Pass:** all four lines, `route` non-empty, Steam's own toast gone (the
  frontend closes it once the backend answers `ok`,
  `frontend/index.tsx:201-215`), and a toast on screen.
- **Fail modes:** no `dev-fire:` line — the `devFire` toggle is off or the
  bundle is stale. `dev-fire:` with no `from-toast` — either one of Steam's
  own gates ate the toast (a user whose `Notifications_ShowOnline=0` sees
  exactly this from `TestFriendOnline`) or Steam's toast queue has stalled
  after a long run of test fires; "Steam's toast queue stalls in long test
  sessions" below tells them apart, and neither is a plugin fault. `toast ... -> {...}` with no toast on screen — the
  delivery half; check
  `delivery suppressed during platform back-off` and `toast delivery
  failed:` in the log (`tools/notify-action.ps1:127`, `240`), then
  `<runtime>\.wpn-backoff`.
- **Oracle without a screen:** the toast's XML is in `wpndatabase.db`,
  `Notification.Payload`, joined to `NotificationHandler.PrimaryId =
  me.tysmith.steam-native-notify`. Assert the two `<text>` nodes, the
  `appLogoOverride` `src`, and `launch="steam://snn/replay/<toast>"`.
  `tools/lib/toastdb.ps1` reads it — `Get-ToastRows` for the plugin's own
  rows (`-Since` filters in SQL, `140-150`), `Get-ToastFacts` for those
  slots out of one row's XML (`161-184`) — over a WAL-safe copy through
  `winsqlite3.dll`, so nothing has to be installed. `tests/windows/run.ps1`
  asserts against it, and `pwsh tools/capture.ps1` prints the newest row in
  one line:

      delivered 2026-09-05 17:19:14  'Download Complete' / 'Aircar - Your game is ready to play'  launch=steam://snn/replay/notificationtoasts_10014_desktop

  which is the fastest confirmation that delivery reached Windows rather
  than that the helper exited 0 (`tools/capture.ps1:138-151`).
- **Evidence (2026-09-05 17:19:14):** the four lines above, verbatim, for
  `notificationtoasts_10014_desktop`.

#### G5 — Delivery, server-sourced toast

- **Precondition:** G4.
- **Action, needing no other account:** `pwsh tools/fire.ps1 --wishlist`
  (the appid defaults to 1073390; `--wishlist <appid>` overrides it). For a
  type that carries a sender, `pwsh tools/fire.ps1 --server 2
  '{"gifter_account":<a friend accountid>}'` — JSON bodies take single
  quotes on the outside and stay JSON inside, and a JSON *string* argument
  is written `'"like this"'` (`tools/fire.ps1:34-35`). A method name, an
  appid, a replay call and a toast name are each checked against
  `[A-Za-z0-9_.-]` before they are interpolated into the JSON, and a
  value that fails exits 1 (`tools/fire.ps1:57-64`); the call arguments
  themselves stay raw, because they are JSON literals by contract.
  `--server` with no
  type exits 1.
- **Expect:** `dev-fire: OnServerNotification type=<N> body={...}`
  (`frontend/devfire.ts:82`), then the same `from-toast`/`toast` pair with
  `source=server`.
- **Pass:** a toast, and `from-toast ... source=server type=...`.
- **Fail modes:** `dev-fire: server notification store not found` — the
  webpack export search for `OnServerNotification` + `MarkItemRead` no
  longer matches (`frontend/devfire.ts:34-48`); this is the Steam-update
  failure mode, not a Windows one. A `dev-fire:` line with no toast is
  Steam's per-type notification preference.
- **Evidence (2026-09-05 17:18:50):** `dev-fire: OnServerNotification
  type=8 body={"appid":1073390,"count":1}` from `--wishlist`.

#### G6 — Text and artwork fidelity

- **Precondition:** G4 produced a toast.
- **Action:** read the delivered toast (screen, or the `Payload` XML from
  the DB oracle). Fire a second, avatar-bearing toast for the crop case:
  `pwsh tools/fire.ps1 TestFriendMessage null '"Ready to play?"'`.
- **Pass:** the em dash in `Aircar — Your game is ready to play` renders as
  an em dash, not mojibake; the title is `Download Complete`; the image is
  the Aircar capsule. The friend message carries the sender's name as the
  title, the message as the body, and a circle-cropped
  `avatars.steamstatic.com` avatar.
- **Fail modes:** mojibake means the helper stopped reading the payload as
  UTF-8 (`tools/notify-action.ps1:112` reads it `-Encoding UTF8`; PowerShell
  5.1 reads ANSI by default, so this is a live regression risk, not a
  hypothetical). No image: `Resolve-Icon` returned null — the library-cache
  file is absent under the published `steam-dir`
  (`tools/notify-action.ps1:138-144`), or an oversized image was silently
  dropped by Windows and `Limit-IconSize` failed to re-encode
  (`tools/notify-action.ps1:175-196`). A circle-cropped game capsule, or a
  square avatar, means the `avatars\.` test at
  `tools/notify-action.ps1:220` misfired.
- **Evidence (2026-09-05 17:21:05):** `toast notificationtoasts_10017_desktop
  -> {"title":"The Brave Little Toaster","body":"Ready to
  play?","image":"https://avatars.steamstatic.com/...jpg","type":8,...}`.

#### G7 — Click the banner

- **Precondition:** G4, toast still on screen, Steam running.
- **Action:** click the toast body while the banner is up (~5 s).
- **Expect:**

      steam-url: replay:notificationtoasts_<N>_desktop
      replay: invoke notificationtoasts_<N>_desktop onClick@15 age=<N>s
      replay: invoke notificationtoasts_<N>_desktop -> returned without throwing

  (`frontend/steamurl.ts:63-65`, `frontend/replay.ts:271-279`) and the
  Steam client showing what Steam's own toast click would have shown.
- **Pass:** all three lines *and* a visible destination change. **Watch the
  client** — a `steam://nav/...`-shaped replay changes a page inside the
  existing window and looks like nothing if unwatched.
- **Also expected:** Steam's window comes to the foreground, from
  minimized too. Measured on the workstation (`docs/platforms.md`,
  "Focus"): the foreground passes to the forwarding `steam.exe`, then to
  the client's "Steam" window, within about 200 ms of the click. The
  harness asserts it as a WARN after every click, since the foreground is
  Windows' to grant.
- **Fail modes:** no `steam-url:` line — Windows did not launch the URI
  (check the toast XML actually carried `launch=`; no `route` in the `toast
  ... ->` line means the walk refused an ambiguous handler and the toast is
  unclickable *by design*). `steam-url: ignored <url>` — the URL did not
  match the one accepted shape (`frontend/steamurl.ts:40-43`). `replay:
  invoke ... -> no stash entry` — the toast is past the 120 s window and
  `pruneStash` has already dropped it, or Steam restarted
  (`frontend/replay.ts:32`, `62-72`); the `-> expired (Ns old)` variant
  appears only when nothing has stashed since, so the entry is still there
  to be aged out (`frontend/replay.ts:262-266`). `-> THREW ...` — the
  handler's captured Steam stores moved; a Steam-update failure.
- **Evidence (2026-09-05 17:16:42):** a human banner click produced all
  three lines for `notificationtoasts_10009_desktop`, `onClick@15 age=4s`,
  `returned without throwing`. Repeated at 17:14:15 and 17:25:46.

#### G8 — Click the Notification Center copy

- **Precondition:** G7's toast has moved to the Notification Center (the
  banner is gone).
- **Action:** open the Notification Center with **Win+N** — Win+A is
  Quick Settings on Windows 11, a different panel — and click the
  notification. Win+N toggles, so sending it to an already-open panel
  closes it (`tests/windows/lib/ui.ps1:150-156`).
- **Expect:** the same three lines as G7, provided the click lands inside
  `CLICK_WINDOW_MS` (120 s) of the delivery.
- **Pass:** as G7. This is the Windows-only capability Linux does not have
  — the notification-centre copy is inert on Linux because the click rides
  a live popup, while on Windows the click is protocol activation and needs
  no living sender (`tools/notify-action.ps1:205-212`).
- **Fail mode to expect and record, not fix:** a replay of a toast
  delivered more than 120 s ago logs `replay: invoke <name> -> no stash
  entry` and does nothing. That is the stash bound, by design.
- **Evidence (2026-09-05 17:18:08):** `replay: invoke
  notificationtoasts_10004_desktop -> no stash entry`, for a toast
  delivered at 17:14:38 — 210 s earlier. That line carries no `steam-url:`
  line in front of it, so this particular attempt came through
  `pwsh tools/fire.ps1 --replay invoke <name>` rather than a desktop click;
  it demonstrates the stash bound, not the click transport.

#### G9 — In-game, windowed

- **Precondition:** a windowed game running and focused, `notifyInGame` on
  (default).
- **Action:** fire a client toast.
- **Expect:** an overlay-context toast name
  (`notificationtoasts_uid<appid>-...`, `frontend/index.tsx:150`) and a
  delivered Windows toast.
- **Pass:** `toast notificationtoasts_uid... -> {...}` with no
  `(suppressed: ...)` suffix, and a toast on screen.
- **Measured, exclusive fullscreen (2026-09-06):** a real achievement
  produced `notificationtoasts_uid<appid>-9_uid<pid>`, captured with a
  stashed handler and delivered; Windows' game rule held the banner and
  the toast waited in the Notification Center. Every game launch also
  yields Steam's overlay hint toast (type 33), captured and mirrored.
- **Then** set `notifyInGame` to false —
  `pwsh tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify
  key=notifyInGame value=false`; it takes effect within one toast, no
  restart — and fire again.
- **Expect:** `toast ... -> {...} (suppressed: in-game notifications off)`
  and **no** Windows toast; Steam's own toast stays on screen
  (`frontend/index.tsx:174-186`). Restore the setting afterwards.
- **A running game is not enough to make a toast in-game.** Steam picks the
  surface by which one the user is on, so a game running *without* focus
  still renders `_desktop` toasts, which the desktop toggle governs. Test
  the overlay path with a focused, windowed game; a headless or VR title in
  the background exercises the desktop path.
- **Evidence (2026-09-05, 17:18 onward):** with Aircar running (VR,
  headless, unfocused) every toast still arrived as
  `notificationtoasts_<N>_desktop` and delivered normally.
- **Click sub-gate:** click an in-game-captured toast *while the game is
  still focused*. The handler is frozen to the surface its toast rendered
  on; captured in-game and clicked after the game exits, the invoke logs
  `-> returned without throwing` and does nothing visible. That is the
  measured known limit (`docs/experiments/click-replay.md`), not a Windows
  defect.

#### G10 — Fullscreen, with Do Not Disturb / Focus Assist on and off

- **Precondition:** G4 green on this client session — a delivery that is
  known to work when nothing suppresses it, so an empty screen here reads
  as suppression rather than as a broken chain — and a fullscreen
  (exclusive or borderless) game running. Manual.
- **Action A, DND off:** fire a client toast.
- **Expect:** the `toast ... ->` line and a toast; whether Windows draws it
  over an exclusive-fullscreen game is Windows' call.
- **Action B, DND on** (Settings > System > Notifications > Do not disturb,
  or the automatic "when playing a game" rule): fire again.
- **Expect:** the plugin-side lines are identical — capture and delivery
  both succeed — and **no banner**. The toast lands in the Notification
  Center.
- **Pass:** in both cases the log shows delivery; the DB oracle shows the
  row. Suppression is Windows', and the plugin must not report an error for
  it.
- **Fail mode:** any `toast delivery failed:` line in `plugin.log`. Note
  that Windows' automatic DND-during-fullscreen rule is on by default, so
  **most in-game toasts are invisible on a stock machine** — the documented
  next step is `scenario="urgent"` on the toast XML
  (`docs/platforms.md:521-525`), which is not sent today. Recording which
  types Windows suppresses is the point of this gate.

#### G11 — The surface toggles

- **Precondition:** G4 green on this client session, and no game focused,
  so the toast takes the desktop surface (`frontend/index.tsx:150`, `176`).
  Manual — the harness changes no settings.
- **Action:** turn the desktop surface off, fire, turn it back on:

      pwsh tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=notifyOutsideGame value=false
      pwsh tools/fire.ps1 TestDownloadComplete 1073390
      pwsh tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=notifyOutsideGame value=true
      pwsh tools/fire.ps1 TestDownloadComplete 1073390

  A config write reaches the running frontend without a restart, and
  `settings()` is read per toast (`frontend/settings.ts:88-105`,
  `frontend/index.tsx:176`), so the toggle takes effect on the very next
  fire.
- **Expect:** the first fire logs `toast ... -> {...} (suppressed: desktop
  notifications off)` with no Windows toast and Steam's own toast left on
  screen; the second logs the plain `toast ... -> {...}` and delivers.
- **Pass:** both halves, in that order, with no Steam restart between them.
- **Fail modes:** no `(suppressed: ...)` suffix on the first fire — the
  write never reached the frontend; read it back with `pwsh tools/mep.ps1
  plugin.config.get_all name=me.tysmith.steam-native-notify` (the value
  should be `false`), and if the store holds `false` while the log says
  otherwise, the subscription in `frontend/settings.ts:89-92` is the
  suspect. A Windows toast *despite* the suffix means something other than
  this plugin delivered it — check the AUMID on the toast's DB row. Neither
  fire producing a `toast ... ->` line at all is the queue stall, not the
  toggle.
- **Leave the setting on.** `notifyOutsideGame` false suppresses every
  desktop notification, so a run abandoned mid-gate silently disables the
  plugin for the user. The same applies to `notifyInGame` in G9.

#### G12 — Real event, not a test method

- **Precondition:** everything above green. Aircar (1073390, free, 0.89 GB)
  available.
- **Action:** `steam steam://uninstall/1073390` then
  `steam steam://install/1073390`, and wait for the download to finish.
- **Pass:** the same four lines as G4 with no `dev-fire:` line in front of
  them, and a toast. This is the only self-service real-event trigger;
  every other type needs `tools/fire.ps1`, another person, or a
  server-side event.
- **Evidence (2026-09-05 17:18:47):** a real download completion delivered
  as `notificationtoasts_2_desktop` — `replay: candidates ... n=5
  stashed=onClick@15 (twin)`, `from-toast ... type=1 source=client
  array=[1073390,0]`, and the `toast ... ->` line with a `replay:` route.
  **Note the name:** a real event took the low popup-counter series while
  `tools/fire.ps1` toasts were in the 10000s. A harness must match
  `notificationtoasts_` and the `_desktop` suffix, never the number.

#### G13 — Teardown leaves nothing

- **Precondition:** all click gates finished (teardown removes the branding
  the toasts use).
- **Action:**

      & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -NoProfile -ExecutionPolicy Bypass `
        -File "$env:LOCALAPPDATA\steam-native-notify\notify-action.ps1" -Teardown

- **Expect:** `teardown: registrations removed` in `plugin.log`
  (`tools/notify-action.ps1:93-100`).
- **Pass:**
  `HKCU:\Software\Classes\AppUserModelId\me.tysmith.steam-native-notify`
  gone, `HKCU:\Software\Classes\snn` gone, `<runtime>\steam.ico` gone.
  Nothing outside `HKCU` and the runtime directory was ever written, so
  nothing else needs checking.
- **Then:** restart Steam; `setup: AUMID branding registered` must come
  back — `-Setup` runs at every load and is idempotent
  (`backend/main.lua:516-523`).

#### G14 — Steam-update smoke

Run after any Steam client update; this is the Windows spelling of
`.claude/skills/steam-update-smoke`.

- **Action:** `pwsh tools/capture.ps1`; one client fire; one server fire;
  `pwsh tools/fire.ps1 --replay invoke` (no name targets the most recent
  stash entry; `--replay inspect` dumps the whole stash instead).
- **Read the `replay: candidates` line as the layered health probe**
  (`frontend/replay.ts:14-19`):

  | line | broken layer |
  |---|---|
  | `n=0 (no fiber key in toast document)` | the `__reactFiber` convention moved (`frontend/fiber.ts:9-14`) |
  | `... portal=miss` | the HostPortal boundary moved (`frontend/replay.ts:93-112`) |
  | `stashed=none (ambiguous)` | Steam stopped drilling the handler object (`frontend/choose.ts:28-39` has nothing to prove) |
  | `stashed=onClick@N (twin)` | healthy |
  | no line at all, `from-toast` present | the walk threw — look for `replay: walk failed` |
  | `dev-fire: server notification store not found` | the webpack search at `frontend/devfire.ts:37-42` no longer matches |

- **Pass:** a healthy candidates line and `replay: invoke ... -> returned
  without throwing` with a visible destination.
- Every one of these failures is fail-closed: notifications still deliver,
  unclickable.

### Steam's toast queue stalls in long test sessions

After a long run of test fires (roughly twenty in a session is the
budget) Steam can stop creating toast popups and stay that way until the
client restarts. The `dev-fire:` line lands, `frontend/devfire.ts` calls
the test method, and no popup is ever created — so no `replay:
candidates`, no `from-toast`, no `toast ... ->`, and nothing for any
downstream gate to assert. It has only been seen under `tools/fire.ps1`
bursts; real events at real cadence have not shown it. **It looks exactly
like a delivery regression**, which is why the harness checks for it
before every fire.

- **The tell, first line.** `tests/windows/run.ps1` opens with a
  toast-queue pre-check:

      FAIL Steam toast queue is granting popups
             STALLED -- 4 fires with no toast since the last one; full Steam restart required

  The rule is `dev-fire:` lines for either door piling up after the last
  `from-toast`: none is healthy, one is ordinary (Steam gates individual
  types), two or more is the stall (`Get-ToastQueueVerdict`,
  `tools/lib/snn.ps1`). The run refuses to fire, so a stalled client never
  reports as a delivery regression; `-IgnoreQueueStall` fires anyway.
- **The tell, confirmation.** Steam's own log says whether the popup was
  ever created — no `CreatingPopup name:notificationtoasts_` line in
  `<Steam>\logs\webhelper.txt`:

      Select-String -Path 'C:\Program Files (x86)\Steam\logs\webhelper.txt' `
        -Pattern 'CreatingPopup name:notificationtoasts_' | Select-Object -Last 3

  A recent line there with no `from-toast` in `plugin.log` is a plugin
  problem; no line at all is Steam refusing to create the popup, which the
  plugin never sees.
- **Recovery.** A full Steam restart. Nothing else clears it — not
  toggling the plugin, not waiting.
- **What it means for a gate.** Any `from-toast`-shaped failure is provisional
  until the run is repeated on a freshly restarted client. Budget the toast
  count: a validation pass that fires more than a dozen times should restart
  Steam partway rather than trust the tail of it.

### Never fire `TestIncomingVoiceChat`

A fake incoming call has no caller to hang up: its notification never
resolves and every later toast queues behind it until Steam restarts.
Verified by A/B with zero clicks and zero invokes; not a plugin defect.
This applies on every platform and it invalidates the rest of a validation
run.

---

## Part 2 — Test suite spec, targeting 90% line coverage

### What exists today

| suite | what it loads | runner |
|---|---|---|
| `tools/test-backend` | `backend/main.lua` three times — Linux, Windows (with and without a stubbed ffi), macOS — with `logger`, `millennium`, `json`, `fs` preloaded and `os.execute` captured (`tools/test-backend:28-113`, `715-850`, `852-925`) | `lua5.4`; POSIX only (WSL on Windows) |
| `tools/test-frontend` | `notification` and `choose` only, compiled to CommonJS by `tools/load-frontend.mjs:25-46` (`tools/test-frontend:17`) | `bun` / `node` |
| the import-boundary check | asserts `choose`, `fiber`, `notification`, `replay` carry no direct `millennium` import (`tools/test-frontend:40-45`) | — |
| the `steam://` URL check | the seven-case URL table in `tools/test-frontend` | — |

Neither suite measures coverage today, and no suite loads
`tools/notify-action.ps1` at all.

Two structural facts set the ceiling:

1. **`tools/load-frontend.mjs` can only load the Millennium-free
   subgraph.** Everything that imports `millennium` — `log.ts`, and
   therefore `replay.ts`, `clickbridge.ts`, `steamurl.ts`, `settings.ts`,
   `devfire.ts`, `index.tsx` transitively — cannot be `require`d. That is
   681 of the frontend's 766 code lines sitting at 0%.
2. **`tools/notify-action.ps1` has no test seams.** The POSIX helper
   exposes `--resolve-icon`, `--click-plan` and `--escape-markup`, which is
   how `tools/test-backend:345-437` reaches it; the PowerShell helper
   exposes only `-Setup`, `-Teardown` and `-Id`, all of which have side
   effects on the real registry and the real notification platform.

### Measurement method, per language

- **Frontend:** `c8` over V8 coverage of the `node` process that runs
  `tools/test-frontend`. **c8 measures the compiled JavaScript that node
  actually executes**, not the TypeScript — it only reports against
  `frontend/*.ts` because a source map lets it remap the ranges. That
  makes three requirements of `tools/load-frontend.mjs`:
  - **Emit inline source maps.** Add `--inlineSourceMap --inlineSources`
    to the `tsc` flags at `tools/load-frontend.mjs:28-37`. Inline rather
    than separate `.js.map` files, so a map is never looked for beside a
    file that has been deleted.
  - **Keep the compiled output alive.** `tools/load-frontend.mjs:43-45`
    removes the temp directory in a `finally`; c8 resolves maps after the
    process exits, so the directory has to survive the run (remove it on
    the next run instead, or write under a fixed path the coverage step
    cleans).
  - **Compile every module, not just the entries under test.** The
    denominator is what node loaded; a module nothing requires contributes
    nothing, and it cannot be conjured with a flag, because `--all` scans
    *source files on disk* and would try to instrument the `.ts` that node
    never ran. So the entry list at `tools/test-frontend:17` grows to name
    every module the suite covers, and each one gets at least the
    smoke-level exercise Part 2 specifies.

  Then, from the repo root:

      c8 --reporter=text --reporter=lcov \
         --include 'frontend/**' node tools/test-frontend

  A file that ends up at 0% in that report is a file the suite forgot to
  require, not a file with no tests — worth checking before reading the
  number.
- **Backend:** `luacov`. `luarocks install luacov`, then
  `lua5.4 -lluacov tools/test-backend && luacov backend/main.lua`.
  `main.lua` is `dofile`d three times (`tools/test-backend:113` and the
  second and third loads); luacov accumulates hits across all three, which
  is exactly the wanted denominator.
- **PowerShell:** Pester's `-CodeCoverage`. Pester 5
  (`New-PesterConfiguration`, `CodeCoverage.Path =
  tools/notify-action.ps1`) — Windows PowerShell 5.1 ships Pester 3.4.0,
  whose `Invoke-Pester -CodeCoverage` works but reports differently; pin
  Pester 5 with `Install-Module Pester -MinimumVersion 5.5 -Force
  -SkipPublisherCheck`. Coverage is breakpoint-based and in-process, so the
  helper must be invoked with `&` (an `exit` inside a script called that
  way ends the script, not the session) — which is also why the seams below
  matter: `& .\notify-action.ps1 -Id x` in-process would call the real
  `Show()`.

All coverage figures in this document are **estimates read off the
source**, not measurements; none of the three tools is installed on the
validation machine. The first job of the suite is to replace them with real
numbers.

### Harness changes the 90% target depends on

1. **A `millennium` stub for `tools/load-frontend.mjs`.** Write a
   `millennium.js` into the same temp directory as the compiled modules,
   exporting `ffi`, `pluginConfig`, `subscribePluginConfig`,
   `usePluginConfig`, `findModuleExport`, `definePlugin`, `IconsModule`,
   `DialogControlsSection` and `ToggleField` as recording stubs, plus the
   `package.json`/resolution mapping that makes `require('millennium')`
   find it. The import-boundary assertion at `tools/test-frontend:40-45`
   **stays as it is** — it guards a different property (that the core
   walkers stay portable), and a stub that makes the rest loadable does not
   weaken it.
2. **An injectable clock and `window`.** `clickbridge.ts` and `devfire.ts`
   call `window.setInterval` (`frontend/clickbridge.ts:30`,
   `frontend/devfire.ts:109`); `index.tsx` calls `setTimeout`
   (`frontend/index.tsx:124`, `236`). The harness sets `globalThis.window`
   to an object whose `setInterval`/`clearInterval` return handles into a
   manual queue the test drains, and drives `Date.now` through a settable
   offset. Without this, `loadSettings`' five-attempt retry
   (`frontend/settings.ts:93-104`) alone costs 2.5 s of wall time per
   exercise.
3. **Read-only seams in `tools/notify-action.ps1`,** mirroring the POSIX
   helper's: `-ResolveIcon <url>` (print `Resolve-Icon`'s answer, exit),
   `-BuildXml -Id <id>` (print the toast XML that would be sent, exit
   before `Show()`), and honouring `$env:SNN_RUNTIME_DIR` /
   `$env:SNN_AUMID` overrides so a test can point the script at a scratch
   directory and a scratch registry key. Without these three, the
   automatable ceiling for this file is roughly the 45% that
   `-Setup`/`-Teardown` and the early exits reach; with them, 90%.

### Per-file enumeration

Denominator is code lines (non-blank, non-comment). Tiers: **O** offline
(extends `tools/test-frontend` / `tools/test-backend`), **L** live-only
(needs the running client), **W** Windows-only (needs a real Windows
session).

#### `frontend/fiber.ts` — 7 code lines. Now 0% direct. Target 100%. Tier O.

`firstFiber` (`9-14`). Cases: an element list whose first element carries a
`__reactFiber$x` key returns it; a list where only the third element
carries one; an empty list and a list with no keyed element both return
`null`.

#### `frontend/choose.ts` — 24 code lines. Now ~100%. Target 100%. Tier O.

`chooseHandler` (`28-39`) is already exercised by
`tools/test-frontend:143-172` across twin, sole and all three refusals.
Missing only the `c.prop !== 'onClick'` continue in isolation (a candidate
list of `onActivate` alone) and the `!twin || c.depth >= twin.depth`
tie-break with two twinned onClicks at equal depth. **Never loosen a
refusal fixture** — they encode the measured toast-slot leak.

#### `frontend/log.ts` — 15 code lines. Now 0%. Target 100%. Tier O (needs stub 1).

`dlog` (`16-22`): the happy path, and an `ffi` stub that throws (the catch
must swallow). `safeJson` (`29-34`): a plain object; a `BigInt` value (the
replacer at `31` — this branch is the one whose absence once killed every
notification); a value whose `toJSON` throws (the catch at `32`);
`undefined` (the `?? 'undefined'` fallback).

#### `frontend/notification.ts` — 54 code lines. Now ~75%. Target 100%. Tier O.

`notificationFromToast` (`37-85`). Covered today: client decode, server
decode, unparseable `body_data`, a notification found two levels up the
`return` chain, and a window with no fiber
(`tools/test-frontend:92-128`). Missing, all plain-object fixtures:
`win.document` absent (`42-43`); `pendingProps` used when `memoizedProps` is
missing (`48`); `data.array` not an array, which must yield `raw: []`
(`74`); a server notification with no `url` (`69`); a chain longer than 30
fibers, which must return `null` rather than loop (`47`); a fiber whose
`memoizedProps` getter throws *above* an already-decoded notification,
which must still return the decode (`38-40`, `81-85` — this is the whole
reason `decoded` is declared outside the `try`).

#### `frontend/steamurl.ts` — 41 code lines. Now ~0%. Target 95%. Tier O (needs stub 1).

The URL cases in `tools/test-frontend` cover the seven replay-URL shapes;
the parser under test is `replayNameFromSteamUrl` (`40-43`).
`registerSteamUrlClicks` (`49-75`): `SteamClient` absent and
`RegisterForRunSteamURL` not a function, both logging `steam-url:
RegisterForRunSteamURL unavailable` and returning `null` (`52-55`); a
registration whose callback is then invoked with a good URL (asserts
`steam-url: replay:<name>`, `raiseSteamWindow` called,
`invokeReplayHandler` called); with a rejected URL (asserts `steam-url:
ignored ...` and no invoke); with an `invokeReplayHandler` returning false
(asserts `steam-url: replay did not run`); a callback whose body throws
(`66-68`); and a `RegisterForRunSteamURL` that throws (`72-75`).

#### `frontend/settings.ts` — 53 code lines. Now 0%. Target 95%. Tier O (needs stubs 1 and 2).

`absorb` (`57-61`): a known key with the right type lands; a known key with
the wrong type is ignored; an unknown key is ignored. `parseCallableJson`
(`68-77`): a non-string passes through; `null` falls back; a
single-encoded JSON string; a double-encoded one (`72`); unparseable text
falls back. `loadSettings` (`88-105`): subscribes exactly once across two
calls (`89-92`); a `getAll` returning an object folds every key; a `getAll`
that throws once then succeeds; five consecutive throws return the
unchanged snapshot (`93-105`, driven through the fake clock).

#### `frontend/clickbridge.ts` — 48 code lines. Now 0%. Target 95%. Tier O (needs stubs 1 and 2).

`armClickBridge` (`27-72`). Cases, each one tick of the fake interval: a
second arm while a timer exists does not create a second timer (`29`); a
tick past `armedUntil` clears the timer and stops (`31-35`); an empty
`TakeClick` return is a no-op (`45`); a JSON-quoted return is unwrapped
once (`44`); a payload with no `|` logs `click-bridge: unstamped click
dropped` (`46-52`); a non-numeric stamp does the same; a stamp older than
`CLICK_MAX_AGE_S` logs `click-bridge: stale click dropped (Ns old)`
(`53-57`); a fresh non-`replay:` payload logs `click-bridge: <route>` then
`unbridgeable route` and does **not** call `raiseSteamWindow` (`58-62`); a
fresh `replay:` payload calls `raiseSteamWindow` then `invokeReplayHandler`
with the name after the prefix (`65-66`); an invoke returning false logs
`click-bridge: replay did not run`; a `TakeClick` that rejects logs
`click-bridge failed:` (`69-71`).

This whole module is dead weight on Windows — nothing writes the click file
there, so every case above describes Linux behaviour. It is still worth
covering: the code ships on every platform, the poll runs on every
platform, and a regression here breaks Linux clicks silently.

#### `frontend/replay.ts` — 184 code lines. Now 0%. Target 92%. Tier O for the walk, **L** for the fibers it walks.

Everything here operates on plain objects, so fake fibers reach almost all
of it; what stays live-only is whether Steam's *real* tree still has the
shape the fixtures assume — which is what the `replay: candidates` health
line in G14 measures instead.

- `pruneStash` (`62-72`): an entry older than `CLICK_WINDOW_MS` is dropped;
  a ninth stash evicts the oldest (`STASH_MAX` = 8, `33`).
- `fnMeta` (`74-83`): a named function; an anonymous one; an object whose
  `String()` throws, yielding `<toString failed>`.
- `toastSubtreeRoot` (`93-112`): a tag-4 fiber whose
  `containerInfo.ownerDocument` matches returns `viaPortal: true`; no
  portal returns the highest same-document fiber with `viaPortal: false`; a
  host fiber in another document breaks the climb (`105`); a fiber whose
  `stateNode` getter throws does not stop it (`106-108`); an 80-deep chain
  terminates.
- `collectCandidates` (`118-145`): breadth-first order is shallowest-first;
  both `onClick` and `onActivate` on one fiber yield two candidates; a
  fiber with a throwing `memoizedProps` is skipped; a tree wider than
  `MAX_FIBERS` (5000) stops (`122`).
- `stashToastHandler` (`155-199`): no document; no fiber key, asserting the
  `n=0 (no fiber key in toast document)` line verbatim (`161`); a proven
  twin returning `replay:<name>`; an ambiguous set returning `null` but
  still stashing for inspect (`186-192`); a portal miss appending `
  portal=miss` (`168`); the capped candidate dump at 12 with a `+N more`
  line (`176-182`); a re-stash of the same name re-inserting for recency
  (`185`); a throw anywhere logging `replay: walk failed for <name>`
  (`195-198`).
- `inspectReplayStash` (`202-212`): an empty stash logs `size=0`; an entry
  with and without a chosen handler.
- `raiseSteamWindow` (`239-248`): calls
  `ExecuteSteamURL('steam://open/main')`; an absent `SteamClient` is a
  no-op; a throwing one logs `raise failed:`.
- `invokeReplayHandler` (`250-286`): a named hit; no name picking the most
  recent (`254-255`); no entry, the G8 case (`257-260`); an expired entry,
  which also deletes it (`262-266`); an entry with no handler (`267-270`);
  a handler that returns, asserting `-> returned without throwing`; a
  handler that throws, asserting the `THREW` line and the stack line
  (`280-285`).

#### `frontend/devfire.ts` — 103 code lines. Now 0%. Target 85%. Tier O with one **L** hole.

`findServerNotificationStore` (`34-48`): a `findModuleExport` stub that
matches; one that throws, logging `server store lookup failed:`;
memoization on the second call (`35`). **The live-only hole:** whether the
predicate at `37-42` still matches Steam's shipped bundle. No offline
fixture can answer that; G5 does. `injectServerNotification` (`55-84`): no
store logs `dev-fire: server notification store not found`; a store
receives a rollup whose `item.body_data` is the JSON of the body and whose
`notification_targets` is 15 (`71`), and the `dev-fire:
OnServerNotification type=N body=...` line is asserted. `runOverlayProbe`
(`92-106`): an unknown call; a successful `GetOverlayBrowserInfo`; a
rejecting one logging `overlay probe failed:`. `startDevFirePoll`
(`108-149`), one fake tick each: `devFire` off short-circuits before
`takeDevCommand` (`110`); a null command; an `overlay` command; `replay`
`inspect`, `invoke` and an unknown call (`127-132`); a `server` command; a
`call` naming a missing method, asserting `dev-fire: NotificationStore.X is
not a function`; a `call` that exists, asserting the `dev-fire:
NotificationStore.X([...])` line and the arguments applied; non-array
`args` becoming `[]` (`145`); a throwing `takeDevCommand` logging
`dev-fire failed:`.

#### `frontend/index.tsx` — 176 code lines. Now 0%. Target 88%. Tier O, with **L** for the popup manager itself.

- `toastName` (`71-75`): a name with the prefix; without; absent.
- `split` (`82-91`): empty text yields `{ title: 'Steam', body: '' }`; one
  line puts the text in the body under the `Steam` title; three lines join
  the tail with ` — `; whitespace-only lines are dropped.
- `toastImage` (`98-107`): first non-empty `src` wins; no images yields
  `null`; a throwing `document.images` yields `null`.
- `readWhenPainted` (`114-132`): a closed window logs `closed before it
  painted`; empty text re-polls and delivers when text appears; 15 empty
  attempts log `never painted any text`.
- `deliverToast` (`140-216`) — the densest function in the frontend: a
  second call with the same name is a no-op (`141`); the `toast <name> ->
  {...}` line carries title, body, image, type and route (`177-180`); an
  overlay-context name with `notifyInGame` off appends `(suppressed:
  in-game notifications off)` and never calls `notify` (`176-186`); the
  desktop equivalent; a suppressed toast still arms the bridge (`192`); a
  `notify` resolving `ok` closes the popup; resolving `"ok"` closes it too
  (`204`); resolving anything else logs `left open: backend answered ...`;
  a rejecting `notify` logs `left open: notify failed:`; a `win.close()`
  that throws logs `could not close <name>` (`210-212`); `hideSteamToast`
  off never closes (`201`); a `notificationFromToast` returning a server
  decode produces the `server type=... url=... body=...` detail and a
  client one produces `array=[...]` (`165-169`).
- `onPopupCreated` / `onPopupDestroyed` (`218-229`): a non-toast popup is
  ignored; a destroyed toast is removed from `delivered`.
- `installHook` (`231-250`): a manager present registers both callbacks and
  logs `hook installed`; an absent one retries and, after 60 attempts, logs
  `g_PopupManager never appeared; bridge inactive`; a manager whose
  `AddPopupCreatedCallback` throws logs `hook failed:`.
- `pluginIcon` (`259-272`): the first resolvable name wins; a
  `createElement` that throws falls through to the next; none resolving
  returns `null` — this function exists because a bad icon name takes down
  the whole Steam UI with React error #130, so it is worth its four cases.
- The `definePlugin` body (`274-302`): `onDismount` unregisters the
  steam-url registration and every popup registration, and survives both
  throwing (`287-300`).

#### `frontend/SettingsPanel.tsx` — 61 code lines (mostly JSX). Now 0%. Target 60% without new dependencies, 95% with. Tier O.

`useToggle` (`10-13`) has the two branches that matter: a stored boolean is
used, and `undefined` falls back to `DEFAULTS[key]` — that fallback *is*
what a fresh install sees. The `devMode &&` gates at `46` and `57` decide
whether the developer toggles render. Reaching them means rendering React,
which needs `react` + `react-test-renderer` as devDependencies (the panel
uses Steam's global `SP_REACT` at runtime, so neither is a runtime
dependency today). **Recommendation:** exercise `useToggle` through a
hand-rolled `usePluginConfig` stub, leave the JSX uncovered, and hold this
file out of the 90% target rather than add React to the offline suite for
two boolean branches.

#### `backend/main.lua` — 338 code lines. Now ~85%. Target 95%. Tier O.

`tools/test-backend` already loads the module three times and covers
`join`, `shell_quote`, the POSIX and Windows spawns with and without ffi,
the migration, `Identity` across every candidate directory, both
consume-once callables, and the macOS refusal. The gap is error branches:

| lines | what is uncovered | the case |
|---|---|---|
| `28-33` | the `SystemVersion.plist` probe | a fourth load with no `jit` table and `io.open` shimmed to answer that path |
| `69` | `USERPROFILE` fallback for the runtime dir | Windows load with `LOCALAPPDATA` unset |
| `94-97` | `log_line`'s failed `io.open` | shim `io.open` to refuse the log file; nothing may throw |
| `117-119` | asset missing from the bundle | `assets.read` returns `nil`; assert `helper install FAILED: asset ... missing` |
| `121-122` | `io.open` refuses the helper target | shim; assert the reason is logged |
| `128` | a failed `close` | shim a handle whose `close` returns `nil` |
| `177-178` | `MultiByteToWideChar` answering 0 | ffi stub returns 0; `spawn_windows_helper` must return false |
| `206-208` | `CreateProcessW` returning 0 | ffi stub returns 0; assert the `CreateProcessW failed` line and that the `.notify` file is removed |
| `257-259`, `269-274` | the Windows payload file failing to open, write or close | shim `io.open`; assert `notification dropped` and no orphan file |
| `358-361` | `Log` | call it; assert the line reaches the log file |
| `375-379` | `steam_path` throwing | a `millennium.steam_path` that errors; `millennium_steam_dir` must return `nil` |
| `422-424` | the single-user `loginusers.vdf` fallback | a vdf with no `MostRecent` line |
| `446-453` | `publish_steam_dir` removing the file | `steam_path` answers `""`; assert `steam-dir` is gone |
| `489-490` | the truncate `io.open` failing | shim; `on_load` must still complete |
| `530` | `on_unload` | call it |

`os.execute` is captured (`tools/test-backend:106-111`) and every
Millennium module is preloaded, so none of these spawn or write outside the
throwaway cache.

#### `tools/notify-action.ps1` — 165 code lines. Now 0%. Target 90%, conditional on the seams; ~45% without. Tier **W** throughout.

| lines | function / block | cases | needs |
|---|---|---|---|
| `39-46` | `Write-PluginLog` | appends a stamped line; an unwritable path is swallowed | `$env:SNN_RUNTIME_DIR` |
| `48-59` | `Get-SteamDir` | file present; absent; present but blank | " |
| `61-91` | `-Setup` | key + `DisplayName` written; icon extracted from a fixture exe and `IconUri` set; extraction failure logs `setup: icon extraction failed`; a pre-existing `snn` key is removed | `$env:SNN_AUMID` pointing at a scratch key |
| `93-100` | `-Teardown` | both keys and the icon removed; a second run on an already-clean machine does not throw | " |
| `102`, `107` | early exits | no `-Id` exits 2; a missing `<id>.notify` exits 1 | — |
| `108-118` | payload read | valid UTF-8 JSON with an em dash round-trips; malformed JSON logs `payload <id> unreadable` and removes the file | — |
| `124-129` | back-off | a `.wpn-backoff` younger than 60 s logs `delivery suppressed during platform back-off` and exits 1; one older than 60 s does not suppress | — |
| `135-173` | `Resolve-Icon` | empty input; a `steamloopback.host` URL with no `steam-dir`; with one, hitting an existing file; with one, missing the file; an `http` URL already cached; one downloaded once (a local HTTP fixture); a download that fails, leaving no `.part`; an extension not in the allow-list becoming `.img` (`155`); a rooted local path that exists; garbage | `-ResolveIcon` |
| `175-196` | `Limit-IconSize` | `$null`; a file under 190 KB passing through; one over it re-encoded to a ≤256 px PNG **into the plugin's own cache, never beside the source** (`187-189`); a corrupt image returning `$null` | `-ResolveIcon` or a dot-source |
| `198-226` | XML build | a `replay:` route producing `activationType="protocol" launch="steam://snn/replay/<name>"`; a route that fails the regex producing no launch attribute at all (`214`); an `avatars.` image producing `hint-crop="circle"` and a capsule not (`220`); a title containing `<`, `&` and `"` arriving XML-escaped (`203`, `225`); no icon producing no `<image>` node | `-BuildXml` |
| `228-243` | `Show()` and its failures | a message matching `notification platform` creates `.wpn-backoff` and logs the back-off line; any other exception logs `toast delivery failed:` — both drivable by stubbing the WinRT type in the test's runspace | Pester mocks |
| `229-234` | the successful `Show()` | **live-only.** Six lines that genuinely put a toast on a real desktop; asserted by G4 and by `tests/windows/` against the toast DB, never by unit coverage | — |

The regex at `214` deserves its own note: it is the one place where a value
that crossed three process boundaries (frontend → Lua → JSON file →
PowerShell) is interpolated into a document Windows then executes as a URI.
Its refusal cases are worth as much as its acceptance case.

### Reachable totals

| file | code lines | now (est.) | target | what holds it back |
|---|---|---|---|---|
| `frontend/fiber.ts` | 7 | 0% | 100% | — |
| `frontend/choose.ts` | 24 | ~100% | 100% | — |
| `frontend/log.ts` | 15 | 0% | 100% | stub 1 |
| `frontend/notification.ts` | 54 | ~75% | 100% | — |
| `frontend/steamurl.ts` | 41 | 0% | 95% | stub 1 |
| `frontend/settings.ts` | 53 | 0% | 95% | stubs 1, 2 |
| `frontend/clickbridge.ts` | 48 | 0% | 95% | stubs 1, 2 |
| `frontend/replay.ts` | 184 | 0% | 92% | stub 1; fixture fidelity is a live question |
| `frontend/devfire.ts` | 103 | 0% | 85% | the store predicate is live-only |
| `frontend/index.tsx` | 176 | 0% | 88% | stubs 1, 2; an `SP_REACT` stub |
| **frontend subtotal, the 90% target** | **705** | **~10%** | **91.7%** | the ten files above |
| `frontend/SettingsPanel.tsx` | 61 | 0% | 60% | JSX needs React devDeps; **excluded from the target** |
| **frontend, all files** | **766** | **~9%** | **89.2%** | the target is missed when the panel counts |
| `backend/main.lua` | 338 | ~85% | 95% | — |
| `tools/notify-action.ps1` | 165 | 0% | 90% | the three seams; `Show()` stays live-only |
| `tools/lib/snn.ps1` | 90 | 0% | 85% | pure helpers; see below |
| `tools/lib/toastdb.ps1` | 142 | 0% | 70% | the SQLite binding needs a real database |
| `tools/fire.ps1`, `capture.ps1`, `mep.ps1` | 69 + 81 + 156 | 0% | smoke only | live tools; see below |

The subtotal is the per-file targets weighted by code lines:

    7×100 + 24×100 + 15×100 + 54×100 + 41×95 + 53×95
      + 48×95 + 184×92 + 103×85 + 176×88          = 64661
    64661 / 705 = 91.7%

Adding the panel at its dependency-free 60% gives `(64661 + 61×60) / 766 =
68321 / 766 = 89.2%`, which misses the target. So the 90% line is drawn
over the ten files above and `frontend/SettingsPanel.tsx` is excluded by
name, rather than the number being quoted over a denominator it does not
clear. Adding `react-test-renderer` and taking the panel to 95% would give
`(64661 + 61×95) / 766 = 70456 / 766 = 92.0%` across every file — the
alternative, if a maintainer would rather have the dependency than the
exclusion.

#### `tools/lib/snn.ps1` — 90 code lines. Now 0%. Target 85%. Tier **W**, headless.

The shared library every Windows tool and the harness dot-source, and the
highest-value PowerShell target in the repo: it is nearly all pure logic,
and a mistake in it is a mistake in all four callers at once.

- `Get-ToastQueueVerdict` (`131-155`), the queue-stall detector: no fires after
  the last `from-toast` reports granting; one reports the ordinary
  single-gate case; two or more sets `Stalled` and says a restart is
  required; both doors count (`NotificationStore.Test*` and
  `OnServerNotification`, `33`); a log with no `from-toast` at all treats
  every fire as trailing; an empty array does not throw. Fixtures are
  string arrays, so this is a dozen assertions with no Steam anywhere.
- `Get-SteamDir` (`87-101`) and `Get-PublishedSteamDir` (`73-85`): a
  published `steam-dir` wins over the registry; a file holding whitespace,
  or a path that does not exist, reads as `$null` rather than throwing;
  with neither source the answer is `$null` and never a guess.
- `Get-SnnRuntimeDir` (`65-71`): `LOCALAPPDATA` when set, the
  `USERPROFILE` join when not.
- `Get-StarPath` (`103-109`): the path under a given Steam directory;
  `$null` in gives `$null` out.
- `Read-PluginLog` (`111-120`): a missing file is an empty array; CRLF and
  LF both split; blank lines are dropped; a file held open for writing is
  still readable.
- `Write-DevFire` (`122-129`): the bytes are the JSON plus one LF, UTF-8
  with no BOM, and the runtime directory is created if absent.
- `Show-HeaderUsage` (`54-63`) stops at the first non-comment line;
  `Assert-Pwsh7` (`38-45`) exits 1 with one line.

#### `tools/lib/toastdb.ps1` — 142 code lines. Now 0%. Target 70%. Tier **W**.

The toast oracle. `Get-ToastFacts` (`161-184`) is pure — feed it the XML
`tools/notify-action.ps1:198-226` builds and assert every slot: two texts,
a missing second text leaving `Body` null, `ImageSrc`/`ImageCrop` empty
when there is no `<image>`, and `Launch`/`ActivationType` off the root
element. The rest binds `winsqlite3.dll` and needs a real database file:
`Copy-WpnDatabase` (`70-93`) has to carry `-wal` and `-shm`, which is
testable against a fabricated SQLite file, and `Get-ToastRows` (`140-150`)
filters by AUMID and, when `-Since` is bound, by `ArrivalTime` in SQL. What
stays uncovered is the live database itself, which G4 asserts instead.

#### `tools/fire.ps1`, `tools/capture.ps1`, `tools/mep.ps1` — smoke, not coverage

These three are thin over the library above; what is left in them is I/O
against Steam, the registry or a unix socket, so line coverage is the wrong
measure. What they need is a smoke case each, runnable without Steam,
asserting the parts that are pure:

- `fire.ps1`: each subcommand writes the right `.dev-fire` JSON. Point
  `$env:LOCALAPPDATA` at a scratch directory, run
  `TestDownloadComplete 1073390`, `--wishlist`, `--wishlist 570`,
  `--server 2 '{"x":1}'`, `--replay inspect`, `--replay invoke <name>` and
  `--overlay-info`, and assert the file's bytes are the expected JSON,
  UTF-8 with no BOM (`Write-DevFire`, `tools/lib/snn.ps1:122-129`).
  Assert the refusals too:
  `--server` with no type and `--replay` with no call exit 1
  (`tools/fire.ps1:102-106`, `116-120`), no arguments exits 2, a
  subcommand that matches none of them case-sensitively exits 1 rather
  than being fired as a method name (`tools/fire.ps1:129-137`), a token
  outside `[A-Za-z0-9_.-]` exits 1 (`tools/fire.ps1:57-64`), and a
  missing `.star` exits 1 with `not installed:`
  (`tools/fire.ps1:66-74`).
- `capture.ps1`: point `$env:LOCALAPPDATA` at a scratch directory holding a
  fabricated `plugin.log`, and assert the verdict.
  A `backend loaded` stamp older than the `.star` mtime prints `STALE`, a
  newer one prints `current.`, and a log with no such line prints `loaded
  (never)` (`tools/capture.ps1:77-90`). The `sources` line names the
  newest file under the roots `millennium.toml` declares
  (`tools/capture.ps1:92-119`).
- `mep.ps1`: the msgpack pack/unpack pair round-trips without a socket —
  every type in `Pack-MsgPack`/`Unpack-MsgPack`
  (`tools/mep.ps1:66-171`, including the `Write-BE`/`Write-Len` helpers
  and the array32/map32 widths) through a `MemoryStream`, plus
  `ConvertFrom-ParamToken` (`tools/mep.ps1:175-180`) turning `key=true`
  into a boolean, `key=1` into a number and `key=x` into a string. Assert
  the exit contract: 1 for a missing socket, for a reply carrying `error`
  and for the PowerShell 5.1 refusal alike; 0 only on success
  (`tools/mep.ps1:20-23`, `208-221`, `tools/lib/snn.ps1:38-45`).

That is a few dozen assertions, all headless, and it is what stops a tool
rewrite from silently changing the file the plugin reads.

### What no offline suite can cover, and what covers it instead

| not coverable offline | why | covered by |
|---|---|---|
| the fiber walk against Steam's real tree | `__reactFiber` keys, `memoizedProps`, HostPortal tag 4 and the handler drilling are Steam's, and move with Steam updates | the `replay: candidates` health line, G4 and G14 |
| the server-store predicate (`frontend/devfire.ts:37-42`) | matches a minified export in Steam's bundle | G5 |
| `g_PopupManager` and the popup lifecycle | not public API; the object only exists in the client | G3, G4 |
| `SteamClient.URL.RegisterForRunSteamURL` dispatch | Steam decides whether a `steam://snn/...` URL reaches the plugin | G7 |
| a real `Show()` and what Windows draws | the notification platform, Focus Assist and the Notification Center | G4, G6, G8, G10, and `tests/windows/` against the toast DB |
| whether a replayed handler *does* anything | the frozen-surface limit means a clean invoke can still be visually inert | G7, G9 — a human or a screenshot |
| `CreateProcessW` from Millennium's Lua host | needs a LuaJIT host with `ffi`; the test runner is PUC Lua and stubs it | G2 |

Every one of these is fail-closed by design: the worst case is a
notification that arrives unclickable, never a missing notification and
never a wrong action.

---

## Part 3 — What automated testing would look like

### Where CI is today

`.github/workflows/ci.yml:15-19` calls `.github/workflows/build.yml`, one
`ubuntu-latest` job: `bun install --frozen-lockfile`, `bun run typecheck`,
`bun run test` (both suites), `starlight pack`, then a validation step that
asserts the `.star` exists, exceeds 20 KB, carries the `MILLENNIUM` shim
header and passes `starlight verify`
(`.github/workflows/build.yml:38-54`). Nothing Windows-specific runs, and
the packed `.star` is platform-independent, so the Linux pack is the
artifact Windows installs.

### Tier 1 — headless, every pull request

Extend the existing `ubuntu-latest` job with coverage, and add a
`windows-latest` job:

- **Linux job (existing, extended):** `bun run typecheck`; `lua5.4
  -lluacov tools/test-backend`; `c8 ... node tools/test-frontend`; pack and
  verify. Publish both lcov files and fail the job under a per-file floor —
  start at the measured baseline and ratchet up, because a flat 90% gate on
  day one blocks the very pull request that introduces the measurement.
- **Windows job (new), `windows-latest`:**
  - `bun install --frozen-lockfile`, `bun run typecheck`, `starlight pack
    -o dist` — this is the gate that would have caught the
    `Settings.tsx`/`settings.ts` collision, because a case-insensitive
    filesystem is the whole failure. It is the single highest-value
    addition here.
  - `bun tools/test-frontend` — pure Node, runs unmodified.
  - **Pester over `tools/notify-action.ps1`**, in Windows PowerShell 5.1
    (`shell: powershell` in the step, not `pwsh`): the seam tests from
    Part 2. `-Setup`/`-Teardown` against a scratch AUMID key are safe on a
    hosted runner — the registry is per-user and the runner is thrown away
    — and give the registration branches for free. Mock the WinRT type so
    `Show()` never runs. **Pester writes coverage as JaCoCo XML, not
    lcov**, so a report that merges all three languages either converts it
    or keeps the PowerShell figure in its own artifact; most coverage
    services read JaCoCo directly.
  - **Pester over the dev tools and their library**, in `pwsh` this time:
    the cases from Part 2 for `tools/lib/snn.ps1` (the queue-stall detector, the
    Steam-directory precedence, the dev-door bytes), `Get-ToastFacts` from
    `tools/lib/toastdb.ps1`, and the smoke cases for `tools/fire.ps1`,
    `tools/capture.ps1` and `tools/mep.ps1`. All of it is headless with
    `$env:LOCALAPPDATA` pointed at a scratch directory and no Steam
    anywhere. The library is the part worth a coverage floor; the three
    entry points are thin over it.
  - **`tools/test-backend` does not run here** and should not be made to:
    it needs `lua5.4`, POSIX `mktemp` and `/tmp`
    (`tools/test-backend:12-20`). Its Windows *coverage* comes from the
    second load inside the Linux run (`tools/test-backend:715-850`), which
    exercises the Windows branch with backslash-joined paths and a stubbed
    ffi on a POSIX box. That is the right place for it; a `windows-latest`
    port would only re-test Lua.
- **A log-vocabulary lint.** Renaming a log prefix blinds every triage path
  in this document, and nothing catches it today. The lint has three sides,
  and getting them right means knowing which file plays which role:
  - **The documented list** is the comment block at `frontend/log.ts:6-11`.
    `log.ts` declares the contract; it emits none of the lines itself.
  - **The emitters** are `frontend/index.tsx` (`hook installed`,
    `from-toast `, `toast <name> -> `), `frontend/replay.ts` (`replay:
    candidates`, `replay: candidate`, `replay: invoke`, `replay: stash`),
    `frontend/clickbridge.ts` (`click-bridge`),
    `frontend/steamurl.ts` (`steam-url:`), `frontend/devfire.ts`
    (`dev-fire:`) and `backend/main.lua` (`platform:`, `helper:`,
    `backend loaded`).
  - **The consumers** are `tools/capture` and `tools/capture.ps1`, whose
    filters are the actual greps
    (`tools/capture.ps1:127` and `:152`, both reading the prefix table in
    `tools/lib/snn.ps1:29-36`). The Windows twin matches
    `steam-url: registered` and `steam-url: replay`, which the Linux one
    does not, so the lint reads both.

  The assertion: every prefix either capture script greps appears
  literally in at least one emitter, and every prefix `log.ts` documents is
  grepped by at least one capture script. Both directions matter — the
  first catches a renamed emitter, the second catches a prefix that quietly
  stopped being triageable. It is a grep, and it is worth a step.

Total tier-1 wall time: a few minutes, no Steam, no session, no flake.

### Tier 2 — the live tier, self-hosted

Everything in Part 1 from G2 onward needs a logged-in Steam client, a real
desktop session and a real notification platform. A hosted GitHub runner
has none of those: it has no interactive desktop, so WinRT toasts do not
display and UI Automation has nothing to drive.

The shape that works:

- **A dedicated Windows machine or a persistent VM** (the first validation
  used a dockur/windows Win11 Pro VM), auto-logged-in to an interactive
  session, running the GitHub Actions runner as a **user-session process,
  not a Windows service** — a service runs in Session 0 and cannot show a
  toast.
- **Steam installed and signed in,** Millennium installed, the plugin
  enabled, `devMode` and `devFire` preset in Millennium's config store
  through `tools/mep.ps1`.
- **Credentials stay on the machine, never in the workflow.** Steam is
  signed in once by hand with "remember me", and the runner inherits that
  session; no Steam password or Steam Guard secret belongs in a repository
  secret, and a job must never be able to read the account out. Use a
  throwaway account that owns Aircar and nothing else, treat the machine as
  compromised if the repository is, and expect to sign in again by hand
  after a Steam Guard reset — which is one more reason this tier is nightly
  and attended, not a gate on a pull request.
- **Triggered, not automatic:** `workflow_dispatch` and a nightly schedule,
  never on every pull request. The job installs the `.star` artifact from
  the tier-1 build, restarts Steam, waits for `hook installed`, and runs
  `tests/windows/run.ps1` per scenario.
- **`tests/windows/` is the executor.** It fires through the dev door,
  asserts the toast row in `wpndatabase.db`, clicks through UI Automation,
  and asserts the `steam-url: replay:<toast>` and `replay: invoke ...` pair
  — the whole Windows click path, and the only lines a click produces here.
  There is no `click-bridge:` line to assert: nothing on Windows writes the
  click file.
  What it cannot assert — that a replayed click *visibly* did the right
  thing — stays a human gate (G7's "watch the client") or a screenshot a
  human reads.
- **State hygiene between scenarios:** the backend truncates `plugin.log`
  at load, so a Steam restart is the reset; each run removes stale
  `<id>.notify` and `.wpn-backoff` files, and ends with `-Teardown`
  followed by a fresh `-Setup` so G13 is exercised every night rather than
  once.
- **Cost of a restart:** a Steam restart is the only way to pick up a new
  build, and it kills every in-flight state. One restart per run, at the
  top, and every scenario after it.

### Flake risks, and what each one needs

| risk | shape | mitigation |
|---|---|---|
| **Focus Assist / Do Not Disturb** | Windows' automatic "while playing a game" rule is on by default, so in-game toasts silently do not display; the plugin logs a clean delivery either way | assert against the toast DB, not the screen — a suppressed toast still has a row. Set the DND state explicitly at the top of each scenario rather than inheriting it. `scenario="urgent"` is the documented fix and is not sent today (`docs/platforms.md:521-525`) |
| **Toast timing** | the banner shows ~5 s, then moves to the Notification Center; a click test that races the banner fails intermittently | make the Notification Center the primary click target (it is stable and persistent) and the banner a separate, retried scenario. Both must land inside the 120 s stash window (`frontend/replay.ts:32`) |
| **Steam's toast queue stalls in long test sessions** | after roughly 20 test fires Steam creates no more popups until a full restart, and every gate downstream of capture fails at once (Part 1, "Steam's toast queue stalls in long test sessions") | count the toasts a run fires and restart Steam before the budget; on any `from-toast`-shaped failure, check `<Steam>\logs\webhelper.txt` for a recent `CreatingPopup name:notificationtoasts_` line, restart, and re-run before recording a failure |
| **The 120 s stash window** | a slow click walk can push a click past `CLICK_WINDOW_MS` (`frontend/replay.ts:32`), which reads as a dead click path | assert the elapsed time in the harness and report a timing failure distinctly from a click failure; `replay: invoke ... -> no stash entry` after a long walk is a *harness* diagnosis, not a plugin bug. `CLICK_MAX_AGE_S` (30 s, `frontend/clickbridge.ts:22`) bounds the click *file*, which Windows does not use, so it is a Linux-only concern |
| **Toast name assumptions** | a real event and a `tools/fire.ps1` fire take different popup-counter series (`notificationtoasts_2_desktop` against `notificationtoasts_10014_desktop`, both 2026-09-05) | match `notificationtoasts_` and the surface suffix, never the number; correlate a fire with its toast by timestamp order, not by name |
| **Steam's own gates** | `TestSystemUpdate` is weekly and in-memory until restart; server types obey the user's notification preferences (with `Notifications_ShowOnline=0`, `TestFriendOnline` produces a `dev-fire:` line and nothing else); Gift/TradeOffer/FriendInvite need a sender persona | pick scenarios that do not depend on account state: `TestDownloadComplete <appid>` and `--wishlist` are the reliable ones. Treat "`dev-fire:` with no `from-toast`" as SKIP, not FAIL, and name the gate |
| **The notification platform wedging** | under bursts Windows answers "The notification platform is unavailable"; recovery is a service restart or a reboot | the helper already backs off 60 s after one such failure (`tools/notify-action.ps1:121-129`). The harness spaces fires (the dev poll is 3 s anyway, `frontend/devfire.ts:22`) and treats a `.wpn-backoff` file as an infrastructure failure that aborts the run rather than failing assertions one by one |
| **Steam client updates** | move the minified bundle under the plugin's feet mid-run | run G14 first in every nightly and abort the rest on a bad `replay: candidates` line; the failure names its own layer |
| **`TestIncomingVoiceChat`** | wedges Steam's toast queue until restart | never in any scenario list; worth an explicit deny-list assertion in the harness |
| **A stale bundle** | every downstream result is meaningless | `pwsh tools/capture.ps1` section 1 is the first assertion of every run, before anything else |

### What automation will never assert

That a replayed click landed *where Steam would have gone*. The invoke logs
`-> returned without throwing` whether it navigated, opened a page behind
another window, or hit the frozen-surface limit and did nothing. Proving
the destination means watching the client. That is the standing reason this
repo's verification norms end in a human, and no amount of tiering removes
it.
