# Windows Live Toast Focus

> Historical implementation record. Every URL and retained-helper lifetime
> below describes the superseded experiment, not current behavior.
>
> Superseded by `2026-09-05-durable-click-routing.md`: focus now runs as a
> route-aware one-shot helper after protocol dispatch, including history clicks.

> Outcome correction: repeated automated clicks disproved the original
> `AppActivate` focus observation. The implementation now uses a reversible
> z-order pulse for visibility; `docs/platforms.md` records the measured limit.

## Goal

Raise Steam above ordinary windows when a user clicks a live Windows
notification banner, while preserving the existing handler-replay click route.

## Observed behavior

- steam://snn/replay/<toast> reaches Steam and invokes the stashed handler
- protocol activation does not foreground an existing Steam window
- a running desktop sender receives ToastNotification.Activated
- Windows PowerShell cannot use Register-ObjectEvent for WinRT events
- a small in-memory .NET event sink can receive the WinRT callback
- WScript.Shell.AppActivate with the visible steamwebhelper process ID returns
  true but does not change the foreground owner
- a reversible topmost-then-not-topmost pulse raises Steam above an ordinary
  window without leaving it always-on-top
- Notification Center retains foreground after the same callback, including
  when activation is delayed until after the callback returns

## Design

Keep the current protocol URL as the only routing transport. For routed
Windows toasts, attach an in-memory .NET event sink before Show(). On
Activated, find the visible top-level steamwebhelper window titled Steam, call
the built-in WScript.Shell.AppActivate method with its process ID, then briefly
raise the window topmost and restore its normal z-order.

Keep the PowerShell sender alive only while the live banner can activate the
event sink. Exit after activation, dismissal, failure, or the existing
120-second replay lifetime. A toast without a replay route still exits
immediately after Show().

The protocol activation remains present. If event registration, target
discovery, or AppActivate fails, clicking still routes exactly as it does
today. Z-order handling must never block toast delivery or handler replay.

## Scope

- fix live-banner visibility on Windows
- preserve steam://snn/replay/<toast> routing
- add a Windows runtime test that proves routed senders remain alive
- update Windows platform documentation and backend lifecycle comments

## Non-goals

- foreground Steam from Notification Center history
- register a COM activator
- ship a binary or new dependency
- change Linux, Flatpak, or macOS behavior

## Validation

- run the Windows helper lifetime test before and after implementation
- run bun run typecheck, bun run build, and bun run test
- install the resulting .star in the Windows VM and restart Steam
- fire an achievement notification and verify a live-banner click both
  invokes the route and raises Steam above an ordinary window
- verify a Notification Center click still routes but remains documented as
  navigation-only
