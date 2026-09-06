# Durable Click Routing Design

> Historical implementation record. Unified notification activation supersedes
> the POSIX click-file and abbreviated Steam URL transport below. See
> `2026-09-05-unified-notification-activation-design.md` for current behavior.

## Goal

Keep exact Steam handler replay available for the current Steam session, and
make supported notification actions continue to work from Windows notification
history and after Steam restarts.

## Decisions

- keep live JavaScript handlers only in Steam's current CEF process
- remove handler age expiry and cap the stash at 256 delivered clickable toasts
- address replay entries with random 128-bit tokens, never reusable popup names
- carry a versioned, validated fallback action inside each notification's click payload
- replay only when the capture surface still matches the live click surface
- dispatch the restored catalog action when replay is absent or the surface changed
- fail closed when neither a proven handler nor a verified catalog action exists
- poll the POSIX click file for the Steam session after the first delivery
- encode the complete click payload in Windows' `steam://snn/click/...` activation URI
- spawn Windows focus work only after a click; do not retain one PowerShell process per toast
- focus a Steam chat window for chat actions and the main Steam window otherwise

## Durable boundary

The operating system persists the Windows activation URI. The plugin does not
serialize JavaScript functions or maintain a second disk database. After a
restart, the URI supplies the verified fallback action while the missing live
handler is treated as expected.

## Restored source of truth

Restore the schema, catalog, URL-store, identity, overlay doors, generator, and
route fixtures from `backup/routing-catalog` as directed by
`docs/regeneration.md`. Preserve handler replay as the preferred same-surface
path.

## Safety

- validate every decoded external click field and action shape
- reject unknown versions, malformed tokens, unknown surfaces, and unknown actions
- preserve the catalog's documented fail-closed mappings
- log replay, fallback, refusal, and focus outcomes without throwing

## Validation

- offline tests for payload round trips, malformed payloads, surface matching,
  stash capacity, no age expiry, catalog routes, and Windows focus mode
- typecheck, pack, and complete backend/frontend suite
- full Steam restart and live friend/achievement clicks on Windows
- notification-history click after a Steam restart
