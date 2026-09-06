#!/usr/bin/env pwsh
# Fire a test notification through Steam's own toast pipeline, and drive the
# plugin's dev diagnostics. Every command writes a file the plugin's dev poll
# consumes within ~3s, gated on the devFire developer toggle.
#
# Client toasts (Steam's own NotificationStore Test* methods; args are JSON --
# bare numbers and null pass through, quote strings):
#   tools/fire.ps1 TestDownloadComplete 1073390
#   tools/fire.ps1 TestFriendOnline
#   tools/fire.ps1 TestFriendMessage null '"Ready to play?"'
#   tools/fire.ps1 TestAchievement 570
#   NEVER TestIncomingVoiceChat: the fake call cannot resolve and wedges
#   Steam's toast queue until restart (CLAUDE.md).
#
# Server-sourced (eSource=2) types, whose shipped test methods are stubbed, go
# through the real ingestion path instead (OnServerNotification):
#   tools/fire.ps1 --wishlist [appid]            store-bound wishlist toast
#                                                (defaults to 1073390, Aircar)
#   tools/fire.ps1 --server <type> '<body-json>' any type; see the body_data
#                                                fields in docs/steam-routing.md
#
# Diagnostics (results land in the plugin log):
#   tools/fire.ps1 --overlay-info                dump overlay browser PIDs
#   tools/fire.ps1 --replay inspect              dump the stashed handler entries
#   tools/fire.ps1 --replay invoke [toast-name]  invoke a stashed handler
#
# Windows twin of tools/fire; same subcommands, same "queued: ..." vocabulary.
# Deliberate divergences, each forced by the platform:
#   - the runtime dir is %LOCALAPPDATA%\steam-native-notify and the .star lives
#     under the Steam install, not $XDG_CACHE_HOME and ~/.local/share/millennium
#     (backend/main.lua:65; resolution in tools/lib/snn.ps1).
#   - the command file is written UTF-8 with no BOM and an LF newline; the
#     backend decodes .dev-fire as UTF-8.
#   - sh's quoting is not PowerShell's: a JSON string argument is '"like this"'
#     and a JSON object body is '{"appid":1073390}' (single quotes outside).
#   - PowerShell's binder claims a leading-dash token it recognises, so a call
#     argument must not start with "-". Everything this tool takes is JSON, a
#     number or a name, so nothing real is lost.
#   - subcommand matching is case-sensitive (as [[ $1 == --replay ]] is), and
#     a first argument starting with "-" that matches no subcommand is
#     refused rather than queued as a method name the way the bash tool
#     would: --Replay is a typo, not a notification to fire.
#   - pure ASCII, no PowerShell-7-only syntax, so Windows PowerShell 5.1 gets
#     the one-line refusal instead of a parse error (tools/lib/snn.ps1).
#
# Needs PowerShell 7 (pwsh), as the sibling tools do.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\snn.ps1')
Assert-Pwsh7 -Tool 'fire.ps1'
Set-Utf8Console

# Names are interpolated into the JSON, so they are checked rather than
# escaped: everything these doors accept is an identifier (a NotificationStore
# Test* method, a toast name like notificationtoasts_10004_desktop, an appid),
# and anything else is either a typo or an injection into Steam's own lookup.
function Assert-Token {
    param([string] $Value, [string] $What)
    if ($Value -cnotmatch '^[A-Za-z0-9_.-]+$') {
        [Console]::Error.WriteLine("$What must match [A-Za-z0-9_.-], got: $Value")
        exit 1
    }
    return $Value
}

# Writing without the plugin installed would queue into a void while still
# printing "queued", hence the .star check.
$Star = Get-StarPath
if (-not $Star -or -not (Test-Path -LiteralPath $Star)) {
    $where = if ($Star) { " ($Star)" } else { ' (no Steam install found)' }
    [Console]::Error.WriteLine("not installed: no $SnnPluginId.star under the Steam install$where")
    [Console]::Error.WriteLine('build first: bun run build (output_path=auto installs it)')
    exit 1
}

# $args, not a [Parameter()] block: any [Parameter()] attribute makes this an
# advanced cmdlet, and the binder would then claim -Deb as -Debug rather than
# passing it through.
$a = @($args | Where-Object { $null -ne $_ -and $_ -ne '' } | ForEach-Object { [string]$_ })
if ($a.Count -lt 1 -or $a[0] -ceq '-h' -or $a[0] -ceq '--help') { Show-HeaderUsage -Path $PSCommandPath; exit 2 }

$Queued = '(needs the tools/fire toggle on in the plugin settings; picked up within ~3s)'

# Case-sensitive, the way the bash tool's [[ $1 == --replay ]] is: --Replay is
# a typo, not a subcommand, and must not quietly fire something else.
switch -CaseSensitive ($a[0]) {
    '--wishlist' {
        $appid = if ($a.Count -ge 2) { Assert-Token $a[1] 'an appid' } else { '1073390' }
        Write-DevFire "{`"server`":{`"type`":8,`"body`":{`"appid`":$appid,`"count`":1}}}"
        "queued: server Wishlist appid=$appid  $Queued"
        exit 0
    }
    # Overlay diagnostics (which games have a live overlay surface; devfire.ts).
    '--overlay-info' {
        Write-DevFire '{"overlay":{"call":"info"}}'
        'queued: overlay info  (result lands in the plugin log)'
        exit 0
    }
    # Replay diagnostics (the click path on this branch; frontend/replay.ts):
    #   --replay inspect          dump the stashed handler candidates
    #   --replay invoke [name]    invoke a stashed handler (latest if unnamed)
    '--replay' {
        if ($a.Count -lt 2 -or -not $a[1]) {
            [Console]::Error.WriteLine('--replay needs a call (inspect or invoke)')
            exit 1
        }
        $call = Assert-Token $a[1] 'a replay call'
        $name = ''
        if ($a.Count -ge 3 -and $a[2]) { $name = Assert-Token $a[2] 'a toast name' }
        if ($name) { Write-DevFire "{`"replay`":{`"call`":`"$call`",`"name`":`"$name`"}}" }
        else { Write-DevFire "{`"replay`":{`"call`":`"$call`"}}" }
        $shown = if ($name) { $name } else { "'(latest)'" }
        "queued: replay $call $shown  (result lands in the plugin log)"
        exit 0
    }
    '--server' {
        if ($a.Count -lt 2 -or -not $a[1]) {
            [Console]::Error.WriteLine('--server needs a numeric ESteamNotificationType')
            exit 1
        }
        $type = Assert-Token $a[1] 'a notification type'
        $body = if ($a.Count -ge 3 -and $a[2]) { $a[2] } else { '{}' }
        Write-DevFire "{`"server`":{`"type`":$type,`"body`":$body}}"
        "queued: server type=$type body=$body  $Queued"
        exit 0
    }
}

# Falling through with a --switch means it matched no subcommand, and since
# the match is case-sensitive that is almost always a typo (--Replay). The
# bash tool would queue it as a method name; a NotificationStore method never
# starts with a dash, so refusing is strictly better than firing nonsense.
if ($a[0].StartsWith('-')) {
    [Console]::Error.WriteLine("unknown subcommand: $($a[0])")
    [Console]::Error.WriteLine('subcommands are case-sensitive; tools/fire.ps1 --help lists them')
    exit 1
}

# The call arguments stay raw: they are JSON literals by contract, exactly as
# in tools/fire. Only the method name is checked.
$call = Assert-Token $a[0] 'a method name'
$callArgs = '[' + (($a | Select-Object -Skip 1) -join ',') + ']'
Write-DevFire "{`"call`":`"$call`",`"args`":$callArgs}"
"queued: $call $callArgs  $Queued"
