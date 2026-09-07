Under Active Development

# steam-native-notify

A Millennium plugin that mirrors Steam's in-client notification toasts to the
desktop notification daemon, keeping the artwork and the click. Toasts land
in your notification centre with everything else, and clicking one does
exactly what clicking Steam's own toast would — because it *is* Steam's own
click: at capture time the plugin stashes the click handler Steam attached to
the toast, and a click on the desktop notification re-runs it. There is no
per-type routing table to maintain; notification types Steam adds tomorrow
are clickable on day one.

`docs/architecture.md` is the full picture; `docs/notification-types.md`
lists every notification type and what Steam's click does for it.

## Why a plugin

Steam draws each toast as its own CEF window whose title is the only text
outside the process; the message exists only in that window's DOM. Compositor
rules, Steam's logs, and AT-SPI carry none of it, so the reader must run
inside Steam's UI.

## Install

Requires [Millennium](https://steambrew.app) >= v3.5 (the `.star` plugin
format) and [Bun](https://bun.com). There is no tagged release yet, so build
from a checkout:

```sh
bun install
bun run build
```

Building **is** installing: starlight packs the plugin and writes it straight
into Millennium's plugins directory —
`~/.local/share/millennium/plugins/` on Linux, and
`<Steam>\millennium\plugins\` on Windows (the Steam path comes from the
registry). Then restart Steam and enable **Steam Native Notify** under
Millennium > Plugins. After any rebuild, restart Steam fully: `plugin.restart`
and disable/enable leave the plugin stopped.

The packed `.star` is platform-independent, so it can also be built on one
machine and copied into the other's plugins directory — which is how the
Windows support was developed and tested.

Runtime dependencies: Linux needs `notify-send`, `curl`, `steam` and `sh`;
Windows needs only what it ships with (Windows PowerShell 5.1 — *not* pwsh 7,
which cannot use the WinRT notification APIs). The plugin registers its
Windows toast identity per-user at load, and
`notify-action.ps1 -Teardown` removes it.

## Settings

Two toggles, both on by default:

- **Use native notifications when outside of games**: send Steam
  notifications to the desktop daemon while no game has focus.
- **Use native notifications when inside games**: also send them while a
  game has focus, alongside Steam's in-game toast. Off keeps in-game
  notifications inside Steam only.

Steam's own toast is hidden once the native notification is confirmed
delivered — it replaces Steam's toast rather than duplicating it, and a
failed or unimplemented delivery leaves Steam's toast alone. That and the
`tools/fire` test-command door are developer toggles (`hideSteamToast`,
on by default; `devFire`, off), hidden unless `devMode` is set in the
plugin's stored settings — there is deliberately no UI for it (see
`docs/architecture.md`, testing methodology).

## Diagnosing

```sh
tools/capture   # is the running .star current, did the hook attach,
                # what did the last notifications carry
```

The plugin logs to `~/.cache/steam-native-notify/plugin.log` (truncated at
each backend load); Millennium's loader lines are in
`~/.steam/steam/logs/console-linux.txt` under `me.tysmith.steam-native-notify`.
Every stage of a click logs one line, and every failure mode names itself —
the vocabulary table is in `docs/architecture.md`.
