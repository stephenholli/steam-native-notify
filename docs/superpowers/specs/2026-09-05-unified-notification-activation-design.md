# Unified notification activation

## Goal

Make every clickable native notification activate one plugin-owned Steam URL.
The URL must prefer Steam's captured callback and fall back to a verified route
after a surface change or Steam restart.

## Scope

- use one URL contract on Linux and Windows
- preserve exact callbacks for the current Steam session
- preserve verified routing across Steam and desktop-session restarts when the
  operating system retains the notification
- route against the game or desktop surface focused at click time
- keep notifications without a proved callback or fallback inert

This change does not preserve old `steam://snn/...` notifications. It does not
serialize JavaScript closures. It does not guarantee a click after an operating
system discards its notification history.

## URL namespace

The canonical activation URL is:

```text
steam://steam-native-notify/notification/<base64url-envelope>
```

The plugin registers `steam-native-notify` directly with
`SteamClient.URL.RegisterForRunSteamURL`. Millennium registers and owns the
`millennium` section without a plugin dispatcher, so
`steam://millennium/steam-native-notify/...` would depend on an interface that
does not exist. A descriptive plugin slug also avoids the collision and support
cost of the former `snn` abbreviation.

Source:
[Millennium URL registration](https://github.com/SteamClientHomebrew/Millennium/blob/5cbebb86628767f365de987c451a2839afe153bc/src/typescript/frontend/index.tsx#L170).

## Activation envelope

The existing version-1 envelope remains the durable value:

```ts
interface ClickEnvelope {
  v: 1;
  token: string;
  captureAppId: number;
  fallback: string | null;
  focus: "main" | "chat";
}
```

The URL contains the complete envelope. No OS notification ID or plugin-side
route file is required to interpret it after restart. The decoder rejects an
unknown version, malformed token, invalid app ID, malformed fallback, or
unexpected focus target.

Fallback validation accepts known action-token forms or a bounded `steam://`
URL without ASCII spaces or characters below U+0020. The catalog can mirror Steam's
server-supplied links, so URL validation is syntactic, not a static destination
allowlist.

## Dispatch

Every activation enters `frontend/steamurl.ts`, then the shared dispatcher:

1. Decode and validate the envelope.
2. Determine the currently focused Steam surface.
3. Invoke the token's captured handler when it remains in the 256-entry stash
   and its capture surface matches.
4. Use the embedded catalog fallback when replay is missing, throws, or belongs
   to another surface.
5. Request route-specific focus after a successful desktop dispatch.
6. Do nothing when neither action is safe.

Captured functions stay in CEF memory and disappear with Steam. The fallback
survives because it is data in the URL. The 256-entry cap bounds memory, not
time.

## Deliver on Windows

`tools/notify-action.ps1` stores the canonical URL as the WinRT toast's protocol
activation target. Windows launches or forwards Steam, and the registered URL
handler dispatches the envelope. Existing setup, artwork, focus pulse, and
payload validation remain unchanged.

A retained notification-center row is designed to remain actionable after a
Steam restart. Task 7 must verify that behavior and determine whether Windows
retains an actionable row across a VM reboot.

## Deliver on Linux

`tools/notify-action` constructs the canonical URL before delivery.

- The standard `notify-send` default action waits for a live click, then runs
  `steam <canonical-url>`. It no longer writes `.click`.
- The detached helper is designed to keep a still-live FreeDesktop action
  available across a Steam restart. Task 6 must verify that behavior.
- The helper requests a 30-second timeout. This reaches Quattro's current
  normal-urgency maximum and is intended to extend the live click window
  without claiming persistence.
- When `GetServerInformation` identifies Quickshell, delivery also carries
  `omarchy-exec-argv` with `["steam", "<canonical-url>"]`. Quattro is intended
  to persist that fixed argv vector in its history JSON. Task 6 must verify
  launch after the original helper, Steam, shell, or login session has ended.
- Other daemons ignore the absent vendor adapter and use the standard action.

FreeDesktop notification actions return an action identifier to the client;
the standard does not persist an executable command. Cross-reboot history on an
arbitrary daemon therefore remains best effort. Adding a D-Bus-activatable
GApplication would strengthen that case but would add a Linux runtime,
installation files, packaging, and backend-specific validation. Defer it until
a supported daemon demonstrates the need.

Source:
[Desktop Notifications Specification](https://specifications.freedesktop.org/notification/latest-single/).

## Intended restart behavior

| state at click | intended result |
|---|---|
| same Steam session and surface | exact captured callback |
| same session, different surface | verified fallback against current focus |
| Steam restarted or stopped | start/forward Steam, then verified fallback |
| desktop shell restarted | same result if its history retained the URL or argv |
| full reboot | same result if the OS retained an actionable history row |
| no callback and no fallback | no action |

The plugin does not promise persistence when the operating system removes the
notification itself.

## Security and failure handling

- persist only the validated envelope, never arbitrary shell text
- pass the URL as one argv element without shell evaluation
- keep Steam's executable and the URL as separate Quattro argv entries
- reject unknown URL paths and payload versions
- log whether activation replayed, fell back, or failed closed
- leave Steam's own toast visible when native delivery fails

## Validation

Offline tests cover:

- canonical URL encoding and decoding
- rejection of the old `snn` namespace
- Linux argv construction and shell metacharacters
- Quickshell detection and persisted argv hint
- Windows activation XML
- replay, fallback, surface mismatch, and malformed envelopes

Planned Linux live validation must cover:

- FriendOnline and Achievement from the live banner
- both types from Quattro history after the live popup expires
- Steam restart and fully stopped Steam
- shell restart or login restart with retained history
- desktop focus, matching game focus, and changed surface

Planned Windows live validation must cover the same live/history,
running/stopped Steam, desktop/game, and focus cases when the VM is available.
A VM reboot must determine whether Windows retains actionable notification
history.
