# Durable Click Routing Implementation Plan

> Historical implementation record. Unified notification activation supersedes
> the POSIX click-file and abbreviated Steam URL transport below. See
> `2026-09-05-unified-notification-activation.md` for the current plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session-long exact replay with restart-safe catalog fallbacks and click-triggered Windows focus.

**Architecture:** A pure click-envelope module owns random tokens, encoding, validation, and capture-surface matching. The restored routing catalog supplies stable fallback actions; one dispatcher prefers a matching live handler and otherwise uses the catalog against current Steam focus. Windows stores the envelope in its activation URI and spawns focus work only after activation.

**Tech Stack:** TypeScript, Steam CEF/Millennium APIs, LuaJIT backend, PowerShell/WinRT, Bun test scripts

**Spec:** `docs/superpowers/specs/2026-09-05-durable-click-routing.md`

## Global Constraints

- mirror only Steam actions already evidenced in `docs/steam-routing.md`
- never serialize or persist JavaScript closures
- reject ambiguous replay handlers and malformed external payloads
- require a full Steam restart after every packed-plugin change
- preserve all existing uncommitted Windows work on this branch

---

### Task 1: Restore and lock the routing source of truth

**Files:** Restore `frontend/routes.ts`, `frontend/urlstore.ts`, `frontend/identity.ts`, `frontend/overlay.ts`, `frontend/generated/notifications.ts`, `vendor/`, `tools/gen-proto.mjs`, `tools/proto-sync.mjs`, `tools/gen-types-table.mjs`; modify `frontend/notification.ts`, `package.json`, `tools/test-frontend`.

**Interfaces:** `clientRoute`, `clientOverlayAction`, `serverRoute`, `fieldsForType`, `typeName`, `loadUrlTemplates`, `setIdentity`, and overlay door functions.

- [x] add the old literal route and schema fixtures to the active frontend test and verify they fail
- [x] restore the catalog/schema files from `backup/routing-catalog`
- [x] reconnect typed notification decoding and generator scripts
- [x] run the frontend test and verify it passes

### Task 2: Add a durable click envelope and session-long replay

**Files:** Create `frontend/click.ts`; modify `frontend/replay.ts`, `tools/test-frontend`.

**Interfaces:** `ClickEnvelope`, `createClickEnvelope`, `encodeClickEnvelope`, `decodeClickEnvelope`, `captureAppIdFromToastName`, `surfaceMatches`, `focusKindFor`; replay keyed by envelope token with a 256-entry cap.

- [x] add failing round-trip, validation, surface, capacity, and age-independence tests
- [x] implement the pure envelope and token validation
- [x] replace toast-name replay keys and the 120-second expiry with tokens and a 256-entry cap
- [x] run the frontend test and verify it passes

### Task 3: Dispatch replay or fallback through current focus

**Files:** Modify `frontend/clickbridge.ts`, `frontend/steamurl.ts`, `frontend/index.tsx`, `tools/test-frontend`.

**Interfaces:** both transports consume the same validated `ClickEnvelope`; the dispatcher replays only on a matching surface and otherwise executes one restored catalog action.

- [x] add failing parser and dispatch-selection tests
- [x] restore the old live-focus dispatcher using the current positional `ffi` transport
- [x] route Windows `steam://snn/click/<base64url>` through the shared dispatcher
- [x] build envelopes from typed notifications and start the click poll for the session
- [x] run the frontend test and verify it passes

### Task 4: Make Windows focus click-triggered and route-aware

**Files:** Modify `backend/main.lua`, `tools/notify-action.ps1`, `tools/test-backend`, `tools/test-windows-notify-action.ps1`.

**Interfaces:** frontend `ffi('FocusSteam')(kind)` accepts only `chat` or `main`; PowerShell `-FocusKind` performs a bounded one-shot topmost pulse on the matching Steam window.

- [x] add failing backend spawn and PowerShell source/short-lifetime tests
- [x] remove retained WinRT activation callbacks from notification delivery
- [x] add the one-shot focus backend seam and chat/main window selection
- [x] run backend and Windows PowerShell tests and verify they pass

### Task 5: Document and verify end to end

**Files:** Modify `docs/architecture.md`, `docs/platforms.md`, `docs/regeneration.md`, `docs/experiments/click-replay.md` as needed.

- [x] update lifetime, persistence, collision, fallback, and Windows focus documentation
- [x] run `bun run typecheck`, `bun run build`, and `bun run test`
- [x] fully restart Windows Steam and confirm the current bundle
- [x] test friend-message and achievement live clicks
- [x] restart Steam and test FriendOnline and Achievement history actions
- [x] confirm a history click launches Steam and completes its route from a
  fully stopped state
- [x] fully restart native Linux Steam and test live FriendOnline, live
  Achievement, server ingestion, and post-restart catalog fallback
