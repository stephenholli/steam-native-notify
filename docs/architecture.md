# Architecture

A Millennium plugin that mirrors Steam's in-client notification toasts to the
desktop notification daemon, keeping the artwork and the click. Each click
carries both Steam's exact captured handler token and a catalog-derived durable
fallback. The bridge replays Steam's handler only while the click surface still
matches; otherwise, or after a Steam restart, it dispatches the verified route
against the live surface.

This file is the working context that is not obvious from the code. The rest
of the doc map: `docs/steam-routing.md` is the analysis of Steam's shipped UI
bundle (how its clicks actually work); `docs/notification-types.md` maps
every type number to a name and what Steam's click does;
`docs/experiments/click-replay.md` is the measured record behind the hybrid
design, including its incidents and memory result; `docs/regeneration.md`
records how the routing catalog and protobuf schema were restored from
`backup/routing-catalog`;
`docs/platforms.md` is the platform support matrix (the paths and calls
that differ per OS, and the delivery plan where nothing delivers yet).

## The pipeline

```
Steam renders a toast (its own CEF popup window)
  frontend/index.tsx      hook g_PopupManager, wait for paint, read the DOM
  frontend/notification.ts decode Steam's attached notification
  frontend/routes.ts      derive a durable fallback from the decoded fields
  frontend/replay.ts      walk the toast's fiber tree, stash its click handler
  frontend/choose.ts      which handler a click may run (pure, offline-tested)
  frontend/click.ts       make the versioned token/surface/fallback envelope
  backend/main.lua        marshal the payload to the helper
  tools/notify-action     escape, resolve artwork, deliver; a click returns
                          <epoch>|click:<base64url-envelope>
  frontend/clickbridge.ts consume all clicks for the Steam session
       same surface       invoke the exact handler by random token
       changed/restarted  dispatch the durable route against live focus
  backend/main.lua        Windows only: request one route-aware focus pulse
```

`frontend/fiber.ts` owns the `__reactFiber` discovery both walkers share;
`frontend/log.ts` owns `dlog`/`safeJson`, whose prefixes are `tools/capture`'s
grep contract; `frontend/settings.ts` + `Settings.tsx` hold the two
user-facing toggles (desktop notifications outside / inside games) and the
developer toggles behind `devMode`; `frontend/devfire.ts` is the `tools/fire`
door, gated on the `devFire` developer toggle.

## Capture

Steam draws every toast as its own CEF popup named
`notificationtoasts_<N>_desktop` (no game focused) or
`notificationtoasts_uid<appid>-...` (rendered in a game's overlay context).
The window title is all the compositor sees; the text exists only in the
popup's DOM, which is why the reader runs inside Steam's own JS context.
`g_PopupManager` is not public API — it is what the shipping
kitsune-notifications plugin uses, which is the only reason to trust it.

The popup exists before it paints, so delivery polls for text (~1.2s) rather
than trusting a settle delay. Each popup name delivers at most once. Delivery
is gated per surface by the two user toggles; a suppressed toast is left
entirely to Steam — nothing sent, popup not closed. The `hideSteamToast`
developer toggle closes Steam's own popup after a successful read.

## The click path

At capture, `replay.ts` walks the toast's tree: find the first fiber
(`fiber.ts`), climb to the toast's HostPortal root (toasts are
portal-rendered from the main window's tree — rooting higher once swept 673
candidates), BFS downward collecting every function-valued
`onClick`/`onActivate`, and let `choose.ts` pick:

- **twin** — the deepest `onClick` that IS (`===`) an `onActivate` seen
  shallower. Steam drills the same handler object down the toast's wrapper
  chain, and only the DOM end pairs the activate with the toast-dismissal
  bookkeeping; invoking anything less leaked toast display slots until no
  toast rendered at all.
- **sole** — every candidate is one function object; nothing to mis-choose.
- **refuse** — anything else stays unclickable, the mirror of a Steam toast
  whose click does nothing. A wrong invoke ACTS (a voice-chat accept answers
  the call), so there is no fallback and never should be.

A clickable notification carries `click:<base64url JSON>`. The version-1
envelope contains a cryptographically random 128-bit replay token, capture
surface appid (`0` for desktop), verified catalog fallback or `null`, and the
Windows focus target (`main` or `chat`). It contains no notification text or
artwork.

The bridge polls for the whole Steam session. It rejects malformed envelopes
and click-file writes older than 30 seconds. On a matching live surface it
tries exact replay first. On a surface mismatch, missing stash entry, replay
throw, or post-restart protocol activation, it uses the catalog fallback. A
toast with neither a proved handler nor a verified fallback is inert.

The replay stash holds the latest 256 chosen closures for the Steam session;
it has no time expiry. The cap is a memory bound, not a click-lifetime policy.
The durable data lives in the OS notification's activation URI, so cataloged
clicks survive a Steam restart without persisting a closure or a plugin file.

### Log vocabulary

All in `~/.cache/steam-native-notify/plugin.log` (the Linux runtime
directory; `docs/platforms.md` has the others), truncated at each backend
load (Millennium buffers a packed plugin's logger output away from Steam's
console log, so the backend mirrors every line there itself). The helper
appends there too when it refuses a platform:

| line | meaning |
|---|---|
| `from-toast <name> type=N (Name) source=...` | extraction worked; client payloads include schema-decoded named fields |
| `toast <name> -> {...}` | delivered; reports replayability, fallback, and whether a click envelope was attached |
| `toast <name> -> {...} (suppressed: ... notifications off)` | the surface toggle left this toast to Steam |
| `replay: candidates <name> n=K stashed=onClick@D (twin\|sole)` | the walk found and proved a handler |
| `replay: candidates ... n=0 (no fiber key ...)` | the `__reactFiber` convention moved |
| `replay: candidates ... portal=miss` | the HostPortal boundary moved (walked the fallback root) |
| `replay: candidates ... stashed=none (ambiguous)` | several distinct handlers, none provable; unclickable by design |
| `replay: candidate <name> #i ...` | per-candidate detail, logged only on anomaly and capped |
| `click-bridge: replay token=<prefix>` | matching-surface exact replay ran |
| `click-bridge: fallback <route>` | live-focus catalog dispatch ran |
| `click-bridge: no verified fallback token=<prefix>` | replay was unavailable and no safe route exists |
| `click-bridge: stale click dropped (Ns old)` | consumed but older than 30s; dropped by design |
| `replay: invoke <name> onClick@D age=Ns` then `-> returned without throwing` | the click ran |
| `replay: invoke ... -> no stash entry / THREW ...` | why exact replay did not run |
| `focus: raised kind=<main\|chat> ... target=...` | Windows pulsed the selected Steam window after dispatch |
| `platform: <linux\|macos\|windows> [flatpak: <id>] runtime: <dir>` | the backend's answer at load; `docs/platforms.md` |
| `unsupported platform: <os> delivery is not implemented, notification dropped` | the backend refused to spawn (macOS) |
| `notify-action: unsupported platform ...` / `notify-action: notify-send not found ...` | the helper refused before delivery |

Every reflective failure is fail-closed: the worst case is a notification
that arrives unclickable, never a missing notification and never a wrong
action.

### Known and accepted limits

- Exact handlers are frozen to their capture surface. The bridge checks before
  invoking and uses the durable catalog against current focus when it differs.
  Types without a verified catalog route still fail closed after a surface
  change or Steam restart.
- Windows focus is a reversible topmost pulse after every live or history
  protocol click. It selects the chat window for friend/chat routes and the
  main window otherwise. Windows can leave `ShellExperienceHost` as keyboard
  focus owner; this guarantees visibility above ordinary windows, not keyboard
  focus or precedence over an exclusive-fullscreen/topmost game. Real
  FriendOnline and Achievement history rows have worked after a full Steam
  restart; the friend route raised its named chat through the durable catalog
  fallback. An Achievement history click also launched a fully stopped Steam
  client and completed its persisted navigation after startup.
- The desktop popup is the whole click window: quickshell 1.2 expires it
  after ~8s despite `-t 0` and the action dies with it (the
  notification-centre copy is inert). Orthogonal to the plugin, but it
  bounds how a click can be tested or used here.
- Steam updates can move the fiber conventions (`__reactFiber` keys,
  `memoizedProps`, HostPortal tag 4) or stop drilling the handler object;
  each failure names its layer in the `replay: candidates` line.

## Verified facts

- Steam attaches its decoded notification to the toast's React tree:
  `{ notificationID, rtCreated, eType, eSource, data, ... }`. Client-sourced
  (`eSource=1`), `data` is a Closure protobuf whose values sit positionally
  in `array`; server-sourced (`eSource=2`), a plain rollup
  `{ type, item, url }` whose `item.body_data` is JSON.
- **The React path is strictly better than the notification feed.** An
  incoming voice chat renders as `notificationtoasts_10000_desktop` and
  produces no `RegisterForNotifications` event at all.
- Toast artwork: `steamloopback.host/assets/<appid>/<file>` maps to
  `<steam>/appcache/librarycache/<appid>/<file>`, where `<steam>` is the
  directory the backend publishes from `millennium.steam_path()`
  (`~/.steam/steam` on native Linux, a link to `~/.local/share/Steam`) or
  the helper's per-platform guess (`docs/platforms.md`); friend avatars
  are public CDN URLs, fetched once and cached by notify-action. The fetch
  runs curl with `LD_LIBRARY_PATH`/`LD_PRELOAD` cleared — the helper inherits
  Steam's loader environment, whose pinned_libs_64 libcurl the system curl
  refuses.
- A file-backed icon is sent as a `file://` reference in the `image-path`
  hint (`-i` stays the themed fallback) so the daemon can copy it and the
  icon survives into notification history; a path through `-i` becomes
  in-process image-data that history rows lose. Every delivery also names
  `steam.desktop` in a `desktop-entry` hint for app identity (name, logo
  badge, per-app grouping on daemons that read it).
- Notification actions must be named `default` to fire on a body click, and
  only while the popup is live, hence `-t 0`. The daemon does not auto-fire
  actions on expiry, so a logged click is a genuine click.
- Frontend-backend RPC rides Millennium's `ffi` bridge with positional
  arguments (`Notify(title, body, image, route, ingame)`); the retired
  `callable` transport could not order a multi-key object. A Lua string return
  has arrived both raw and JSON-quoted across transports — unwrap only what
  starts with a quote.
- Settings are per-key values in Millennium's config store (`usePluginConfig`
  in the panel, `pluginConfig`/`subscribePluginConfig` behind `settings()`);
  the backend migrates the earlier one-document form at load, and a config
  write from any source pushes to the running frontend (verified 2026-08-30).

## Testing methodology, which is easy to get wrong

- **`tools/capture` first, always.** A stale bundle is indistinguishable from
  a broken feature. A full Steam restart is required for ANY change, backend
  included (`steam -shutdown && sleep 15 && setsid uwsm-app -- gtk-launch
  steam.desktop`; relaunch again if it is not up — a launch while the old
  instance is dying is silently swallowed).
- **A Steam toast is only clickable while a Steam window has focus**, and a
  `steam://`-style navigation changes a page inside an existing window —
  watch the client, or a working click looks like nothing. Both produced
  wrong conclusions in this project's history.
- **`tools/fire`** needs the `devFire` developer toggle (visible with
  `devMode`; see `.claude/skills/live-verify`). No `dev-fire:` log line
  means the toggle is off or the bundle is stale; a `dev-fire:` line with no
  `from-toast` means one of Steam's own gates ate the toast: SystemUpdate
  allows each update type once a week (in-memory until restart), server
  types obey the user's notification preferences, Gift/TradeOffer/
  FriendInvite injections need a sender persona.
- **Never fire TestIncomingVoiceChat.** The fake call has no caller to hang
  up, never resolves, and wedges Steam's toast queue until restart —
  verified by A/B with zero clicks and zero invokes. Real calls resolve when
  the caller hangs up.
- Server-sourced types go through injection (`tools/fire --server <type>
  '<body-json>'`) into Steam's real `OnServerNotification` ingestion.
  Download completion is the only real-event self-service trigger:
  `steam steam://uninstall/1073390 && steam steam://install/1073390`.

## Dead ends: do not redo these

- **Invoking the bare outermost onActivate** — leaked a toast display slot
  per on-screen click; three clicks silenced every toast until restart.
- **Choosing the handler by source-text similarity** — replaced by function
  identity, which is exact and minification-proof.
- **Walking from the absolute fiber root** — sweeps the whole Steam UI
  (toasts are portals).
- **`OnRespondToClientNotification(id, true)`** as a universal replay
  primitive — only 2 of 45 messages carry a notificationid.
- **Reading the click target from the DOM** — no anchors, no href, no inline
  handlers; it is all React state.
- **Keeping the toast popup alive to dispatch a real DOM click later** —
  Steam owns the popup lifecycle and destroys it on its own schedule.
- **Config-change propagation to a running frontend** — Millennium delivers
  external config writes by evaluating JS in the main IPC context; a plugin
  frontend runs in its own isolated CDP world and never sees them. Presets
  take effect at the next Steam start.
- **Compositor rules for hiding Steam's toast** — the plugin closes the
  popup itself, which is portable and knows the read succeeded.
- The routing catalog's own dead ends (external steam:// URLs into the
  overlay, instance objects as browserInfo, the appid-0 playtime ingestion)
  are recorded beside the current rules in `frontend/routes.ts` and
  `docs/steam-routing.md`.
