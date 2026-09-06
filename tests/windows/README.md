# Windows toast + click harness

An automated pass over the whole Windows delivery chain, from the plugin's dev door to a real click on a real toast. Nobody has to watch the screen or read a log to decide whether it worked — but the machine is not free while it runs, see **Prerequisites**.

Run from the repository root:

```
pwsh -File tests/windows/run.ps1                    # fire, assert delivery, click the banner
pwsh -File tests/windows/run.ps1 -Click both        # banner, then whatever is left in the Notification Center
pwsh -File tests/windows/run.ps1 -Click none        # delivery only, nothing is clicked
pwsh -File tests/windows/run.ps1 -FailDemo          # one expectation poisoned, to show FAIL is real
pwsh -File tests/windows/run.ps1 -Scenario <name>   # a file in scenarios/, without the .ps1
```

Other switches: `-IgnoreQueueStall` (fire even when the pre-check below says Steam's queue is stuck), `-FirstCardOffsetY <px>` (where the newest card sits in the Notification Center — overrides the default in `lib/ui.ps1`; see *Clicking without UI Automation*), `-EvidenceDir <path>`, `-KeepNotificationCentreOpen`.

Each assertion prints `PASS`, `FAIL` or `WARN` with the line, XML slot or measurement that decided it. `WARN` is for a condition that explains a later failure but is not itself one — a game running, or a single unanswered `dev-fire:` — and never counts as a failure. The exit code is the number of `FAIL`s; an unknown `-Scenario` exits 2 and lists the ones that exist. Screenshots land in `evidence/`, which is untracked (`-EvidenceDir` moves them).

A scenario is a hashtable in `scenarios/`, not code: what to fire, and what each oracle should then see. `run.ps1` owns the order the oracles are consulted, so a new notification type is a new file with no new logic.

## Prerequisites

- **PowerShell 7** (`pwsh`). Under Windows PowerShell 5.1 the run prints one line and exits 1 (`Assert-Pwsh7`, `tools/lib/snn.ps1`).
- **Steam running with the plugin loaded** — `tools/capture.ps1` says whether the running bundle is the `.star` on disk, whether the hook attached, and what the last notifications carried.
- **The plugin's dev door open.** `devMode` and `devFire` are plugin settings; set them from the plugin's settings panel, or over Millennium's external protocol:

  ```
  pwsh -File tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=devMode value=true
  pwsh -File tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=devFire value=true
  ```

  `pwsh -File tools/mep.ps1 plugin.config.get_all name=me.tysmith.steam-native-notify` reads them back.
- **An idle, unlocked desktop.** A run takes over input for a few seconds: it moves the mouse pointer to the toast and clicks (the pointer is put back afterwards), and `-Click center|both` sends **Win+N** to open and close the Notification Center. Anything else typing or clicking at the same time can eat the click or land it somewhere unintended. `-Click none` touches neither pointer nor keyboard.
- **One harness run at a time on a machine.** `.dev-fire` is a single file; see *Steam's toast queue can stall in a long test session*.

`docs/windows-testing.md` is the manual test plan for this platform — the checks a person walks through. This harness automates one path through it, not all of it.

## The chain, and who watches which link

```
.dev-fire ─► Steam NotificationStore ─► frontend/index.tsx ─► backend/main.lua
   │              │                          │                     │
   │              │                          │                     ▼
   │              │                          │              notify-action.ps1
   │              │                          │                     │
   ▼              ▼                          ▼                     ▼
dev door      plugin.log                plugin.log            Windows toast DB
                                                                   │
                click ◄── steam://snn/replay/<toast> ◄── the banner or the copy
                  │                                        in the Notification Center
                  ▼
              plugin.log (steam-url: / replay: invoke)
```

**The dev door** — `.dev-fire` disappearing is the frontend's acknowledgement (`backend/main.lua` hands the line over and deletes it). It proves a frontend is polling; it proves nothing about Steam.

**`plugin.log`** — the frontend's own account of what it captured and sent: `dev-fire:`, `replay: candidates … stashed=`, `from-toast`, and the `toast <name> -> {…}` payload it handed the backend. These are the prefixes `frontend/log.ts` declares as contract; the harness matches them through the `$SnnLog` table in `tools/lib/snn.ps1`, so one rename lands in one place. There is no per-delivery success line on Windows, so the harness asserts the *absence* of `toast <name> left open: backend answered …` — the line the frontend writes when the backend refuses.

**The toast database** — `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` stores the XML of every toast the notification platform accepted. `tools/lib/toastdb.ps1` reads the newest row for the AUMID `me.tysmith.steam-native-notify` (`Get-ToastRows -Since`, which filters on arrival time in SQL) and the harness asserts title, body, `appLogoOverride` src, `hint-crop`, `activationType="protocol"` and the `launch` URL — and that `launch` names *this* toast, which is what ties the Windows toast back to the Steam toast in the log. This is the only oracle that proves delivery reached Windows rather than that the helper exited 0. The DB is read through `winsqlite3.dll` (Windows' own SQLite, in System32) so the harness needs nothing installed; the live file is copied first, `-wal` and `-shm` included, or the row just written is missing from the copy. That copy is written to `%TEMP%\snn-wpn-copy.db` and left there — never into the repository, because it is a snapshot of the machine's whole notification history, every application included. Delete it if that matters on a shared machine.

**The click** — an actual left click on the painted toast, then `steam-url: replay:<toast>` → `replay: invoke <toast> …` → `-> returned without throwing` in the log. That sequence is the Windows click path end to end: Windows launched `steam://snn/replay/<toast>`, Steam handed the URL to the client's JS, `frontend/steamurl.ts` parsed it, and `frontend/replay.ts` ran the handler it stashed off Steam's own toast.

## Clicking without UI Automation

The brief for this harness assumed UI Automation. It does not work here, and the harness says so rather than pretending:

On this build (Windows 11, 26200) the banner is a top-level `Windows.UI.Core.CoreWindow` titled **"New notification"** owned by `ShellExperienceHost` — and it is invisible to a normal-integrity client:

| probe | result |
| --- | --- |
| `EnumWindows` | never returns the window |
| UIA root element's children | 15 windows, none of them ShellExperienceHost's |
| `AutomationElement.FromHandle(hwnd)` | `BoundingRectangle` = `Empty`, 0 descendants |
| `WindowFromPoint` over the painted banner | finds it: `Windows.UI.Core.CoreWindow` / "New notification" |
| `DwmGetWindowAttribute(…, EXTENDED_FRAME_BOUNDS)` | `3444,1387,3840,1552` while a banner is up; zero height when parked |

So there is no `Invoke` pattern to call and no element rectangle to read. `lib/ui.ps1` uses what the shell does expose — `FindWindow` for the window, DWM's extended frame bounds for where it is painted — and clicks with synthetic mouse input at that rectangle's centre, restoring the pointer afterwards. pywinauto/uiautomation would hit the same wall: they are clients of the same UIA provider, and the provider is what is missing.

The Notification Center copy is addressed the same way. Its panel is a sibling CoreWindow titled "Notification Center"; it is never destroyed and DWM reports it cloaked whether open or shut, so "is it open" is answered by hit-testing a point inside it, and the newest card is addressed by geometry: the top of the list, `-FirstCardOffsetY` pixels below the panel's top edge. The default is `$script:DefaultFirstCardOffsetY` in `lib/ui.ps1`, 165 — measured, so that it clears the panel's "Notifications" header and the app-group row and lands on the title/body block, which is what activates; 90 px hits the group row and only collapses it. `-FirstCardOffsetY 0`, the parameter's own default, means "use the value in `lib/ui.ps1`", and any other number overrides it for that run through `Get-NotificationCentreCardPoint`. That is the one number to retune if a Windows update moves the list, and a wrong one shows up as a failed click assertion, never as a false pass.

`-Click both` normally ends on a `WARN`, and that is the correct result: activating the banner removes the toast from the Notification Center, so the top card is an older toast and the guard below refuses to click it. Use `-Click center` to exercise that surface on a toast of its own.

A run closes the Notification Center before it fires: while that panel is open Windows sends the toast straight to the list and paints no banner, so a panel left open by an earlier run would fail the next run's banner assertion for no reason. The run says so with a `WARN` when it had to close one.

Two guards keep a click honest. Before clicking the banner the harness re-reads the window's DWM rectangle and aims at the fresh centre; if it has gone, or shrunk below `$script:BannerMinHeight` (40 px, `lib/ui.ps1`), the click is not fired at whatever is behind it and the assertion fails with `banner expired before click`. Windows shows a banner for about five seconds. Before clicking the Notification Center card it asks the database what the newest notification on the machine actually is: it must be this AUMID's, and its `launch` must name the toast under test. If another app's notification arrived in the meantime the card is not ours, and the click is skipped with a `WARN` instead of landing on a stranger's notification. A synthetic click can also simply not register: one Notification Center click in seven left the card untouched (its database row stayed, no `steam-url:` line followed) and the rerun passed. A FAIL on the click assertion alone, with the card correctly identified, is that case until it repeats.

## Steam's toast queue can stall in a long test session

After a long run of test fires (roughly twenty in a session) Steam can stop creating toast popups and stay that way until the client restarts: the `dev-fire:` line lands, `frontend/devfire.ts` calls the test method, and no popup is ever created. Real events at a normal cadence have not shown it. Treat it as test-session hygiene: end a long session with a full Steam restart.

So `run.ps1` checks for it *before* it fires. `Get-ToastQueueVerdict` (`tools/lib/snn.ps1`) counts the fires logged after the last toast — both doors, Steam's own `Test*` methods and the server path. One trailing fire is ordinary, since Steam gates individual types, so one warns; two or more stop the run with

```
  FAIL Steam toast queue is granting popups
         STALLED -- 2 fires with no toast since the last one; full Steam restart required

Steam toast queue stalled (long test session), or this type is gated by Steam twice in a row.
If the type is one Steam is allowed to raise: full Steam restart required.
```

before anything is fired. `-IgnoreQueueStall` runs anyway. Without that pre-check a stalled client is indistinguishable from a delivery regression: `FAIL plugin captured a Steam toast` looks identical either way.

Two workers sharing the dev door will also clobber each other: `.dev-fire` is a single file, and a second writer's line replaces one that has not been consumed yet. The harness catches that rather than mis-reporting it — the `frontend logged the dev-fire call` assertion names the exact call it expected — but a shared machine wants one harness run at a time.

## What has actually run here (2026-09-05)

Verified on this machine, against the live client, after a clean Steam restart at 17:49:

| run | result |
| --- | --- |
| `-Click none` | 27 assertions, all pass |
| `-Click none`, Do Not Disturb on (Settings UI) | 26 pass, 1 fail: `banner painted on screen`, as G10 expects; the DB row and every plugin-side assertion pass |
| `-Click center` at 125% display scaling | 32 assertions, all pass, card offset scaled to 206 px; before the library made its thread DPI aware the same run failed at `Notification Center opened` |
| `-Click center` | 33 assertions, all pass — the Notification Center card activated the toast and Steam's window came forward |
| `-Click both` | the banner click passes and the card guard then refuses a stale card: a `WARN`, which is the right answer |
| `-FailDemo` | the poisoned title expectation is the only failure; exit code 1 |

## What this cannot prove

- **That a human saw anything.** The oracles are the platform's own records plus a screenshot; nothing here reads pixels.
- **That Steam keeps the foreground.** A click does bring Steam's window forward on this client, from minimized too (measured: the foreground passes to the forwarding `steam.exe`, then to Steam's main window, within about 200 ms; `docs/platforms.md`, \"Focus\"), and the harness asserts it after every click. It is a WARN, not a FAIL: Windows may refuse the foreground to any process, and a refusal is Windows' decision, not a plugin fault.
- **That Steam will fire at all.** Steam gates its own test methods — a type switched off in Steam's settings, or a game running — and its queue can stall in a long test session (above). All of it looks the same: a `dev-fire:` line with no toast after it. The harness reports that as a failed *capture* assertion and names the candidates; restart Steam and re-run before believing a delivery failure.
- **Anything about a build that is not the running one.** `run.ps1` never builds or restarts Steam. A frontend change needs a full Steam restart before it is under test — `tools/capture.ps1` is the check for whether the running bundle is current: it compares the `.star`'s build time against the backend load in `plugin.log`, and the build inputs `millennium.toml` names against the `.star`.
- **The in-game (overlay) path.** Every scenario here is a desktop toast. In-game capture is `notificationtoasts_uid…` and is not covered.
- **A display the DPI read cannot describe.** The click and screenshot geometry is physical pixels from DWM's frame bounds, on a thread the library makes per-monitor DPI aware at load, and the card offset scales with the DPI it reads (165 px at 100%, 206 at 125%, both measured to activate the card). The pre-check `display DPI read` records the value; a read of 0 means the geometry is a guess.
- **Repeatability across Windows versions.** Both click surfaces depend on the shell's window titles and layout. They are read at runtime, not hardcoded, but a future build that renames "New notification" will fail the banner assertion loudly.

## Exercising the harness itself

`$env:SNN_PLUGIN_LOG` points the log oracle at a file instead of the live `plugin.log`, which is how the log-reading pre-checks are tested with no Steam running. Only the log moves — a fire still goes through the real dev door — so a run under it can inspect but never invent a delivery.

```
$env:SNN_PLUGIN_LOG = 'C:\tmp\stalled.log'; pwsh -File tests/windows/run.ps1 -Click none
$env:SNN_PLUGIN_LOG = $null   # back to the live log
```

## Files

| path | what it is |
| --- | --- |
| `run.ps1` | the entry point: one scenario, PASS/FAIL per assertion, exit code = failures |
| `scenarios/*.ps1` | one hashtable per scenario: what to fire, what each oracle should see |
| `lib/harness.ps1` | the dev door, log tailing, screenshots, the PASS/FAIL ledger |
| `lib/ui.ps1` | finding and clicking the banner and the Notification Center copy; the banner and card geometry |
| `evidence/` | screenshots written by the last run (untracked) |

The harness is not self-contained: it shares the tools' library, dot-sourced from `run.ps1` and `lib/harness.ps1`.

| path | what it is |
| --- | --- |
| `tools/lib/snn.ps1` | plugin identity, the `$SnnLog` prefix contract, runtime and Steam paths, the dev-door write, `Get-ToastQueueVerdict`, the PowerShell 7 refusal |
| `tools/lib/toastdb.ps1` | the notification-database oracle (`winsqlite3.dll`, WAL-safe copy) |
