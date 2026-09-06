# Routing/schema restoration record

The routing catalog and generated notification schema were removed by the
full-replay implementation, then restored on 2026-09-05 for durable hybrid
clicks. Their preserved source remains:

- **`backup/routing-catalog`** — a branch pinned at 21f731f (main's tip
  before the replay implementation was promoted), holding the complete
  original implementation. Nothing here needs to be rewritten from prose;
  check the files out of the branch.

Read this before repairing or refreshing either subsystem. The historical
reasoning remains useful because a future cleanup must preserve the durable
fallback.

## 1. The routing catalog (the original click path)

**What it is.** A hand-built mirror of Steam's per-type click logic:

| file (on backup/routing-catalog) | role |
|---|---|
| `frontend/routes.ts` | the catalog: `clientRoute(type, fields)` / `serverRoute(n)` -> `steam://` URL or null, ~40 mappings, every rule citing docs/steam-routing.md; `clientOverlayAction` emitted action tokens (screenshot/clip/chatroom/playtime) |
| `frontend/urlstore.ts` | Steam's URL templates via `SteamClient.URL.GetSteamURLList`, `resolveUrl(name, ...params)` |
| `frontend/identity.ts` | signed-in steamid64 (backend reads loginusers.vdf), `myProfilePath()` |
| `frontend/overlay.ts` | the surface doors: activate-overlay ingestion, `GetNavigator` media/playtime doors, chat dispatchers, live-focus tracking via `RegisterForOverlayGameWindowFocusChanged` |
| `frontend/clickbridge.ts` (old body) | click dispatch by LIVE focus at click time: overlay doors for the focused game, desktop doors (raising/creating the main window) otherwise |
| `tools/gen-types-table.mjs` | regenerated docs/notification-types.md and FAILED when catalog prose disagreed with routes.ts |
| `tools/test-routes` (old body) | 69 assertions locking every route URL literal offline |

**Why it exists / what replay lacks.** The catalog picks the click surface
from live focus at CLICK time; replay's handler is frozen to the surface the
toast rendered on. Measured consequence (docs/experiments/click-replay.md):
an overlay-captured handler invoked after the game exits silently no-ops
where the catalog opens the desktop destination. The catalog also has
offline-testable correctness; replay's oracle is the live client.

**Current use.** The hybrid replays only when capture and click surfaces match.
It dispatches the catalog route against live focus on mismatch, missing stash,
replay failure, or Steam restart. This is also the durable payload stored in
Linux and Windows notifications' canonical activation URL. Group chat was
excluded from durable fallback: its room dispatcher needs session-only toast
context, so only exact replay can preserve that click.

**Recovery command used.** `git restore --source backup/routing-catalog -- frontend/routes.ts
frontend/urlstore.ts frontend/identity.ts frontend/overlay.ts tools/test-routes
tools/gen-types-table.mjs` and take clickbridge.ts/index.tsx/notification.ts
from the same branch or re-wire by hand. The current versions are intentionally
adapted to the versioned envelope and ffi transport; do not overwrite them as a
bulk restore. `docs/steam-routing.md` is the analysis every route cites.

## 2. The generated protobuf schema

**What it is.** `vendor/steammessages_clientnotificationtypes.proto`
(Valve's published proto, provenance in `vendor/PROVENANCE.json`) →
`tools/gen-proto.mjs` (ran inside `bun run build`) →
`frontend/generated/notifications.ts` (576 lines: `typeName()` and
`fieldsForType()`), plus `tools/proto-sync.mjs` behind `bun run proto:check`
/ `proto:update` to detect upstream drift.

**What it does here.** Client-sourced notifications arrive as a Closure
protobuf whose values sit POSITIONALLY in `data.array` at
`fieldNumber + arrayIndexOffset_`. The schema turned that into named fields
(`steamid`, `appid`, `screenshot_handle`, ...) and numeric types into names
(`(SystemUpdate)`). On main that decoding fed routing — a mis-decode
misroutes, hence CLAUDE.md's old "keep the generated protobuf schema" rule.
The decoded fields feed the durable catalog and the readable log.

**Failure effect.** Without a generated decoder, client fields lose their
names and durable client routes cannot be derived safely. Exact replay may
still work during the current session, but mismatch and restart fallback must
fail closed.

**When to regenerate.** `bun run build` regenerates the checked-in TypeScript.
Use `bun run proto:check` for upstream drift and `bun run proto:update` only as
an intentional schema update.

**Recovery command used.** `git restore --source backup/routing-catalog -- vendor tools/gen-proto.mjs
tools/proto.mjs tools/proto-sync.mjs`, restore the `gen`/`proto:check`/`proto:update`
scripts and the `bun tools/gen-proto.mjs &&` prefix of `build` in
package.json, restore `fieldsForType`/`typeName` use in
frontend/notification.ts and index.tsx (the old shapes are in the same
branch), and re-add the decode fixtures to tools/test-routes.

## 3. Hybrid pieces that must stay together

- `docs/steam-routing.md` — the bundle analysis. It is knowledge, not
  machinery; both approaches cite it.
- `docs/notification-types.md` — the generated per-type reference.
- `docs/experiments/click-replay.md` — the measured comparison and the
  hybrid sketch.
- `frontend/choose.ts` + its fixtures — the click chooser, the one piece of
  replay that is pure logic and offline-tested.
- `frontend/click.ts` — the versioned, validated durable envelope.
- `frontend/routes.ts`, `urlstore.ts`, `identity.ts`, `overlay.ts` — fallback
  generation and click-time dispatch.
- `frontend/replay.ts`, `choose.ts`, `fiber.ts` — exact same-surface replay.
- `frontend/clickbridge.ts`, `steamurl.ts` — one dispatcher for Linux and
  Windows canonical protocol activation; the click-file poll is a legacy/test seam
