#!/usr/bin/env pwsh
# Report what the plugin is doing, in the order the answers are needed:
# is the running .star current, did the notification hook attach, and what did
# the last notification carry.
#
# Usage: tools/capture.ps1 [n]   n = how many notification lines to show (default 8)
#
# One log source, not two. The plugin's own diagnostics go to PLUGIN_LOG
# (%LOCALAPPDATA%\steam-native-notify\plugin.log): Millennium buffers a packed
# (.star) plugin's logger output in memory, so backend/main.lua mirrors every
# line there, truncated at each backend load.
#
# Windows twin of tools/capture; same three sections, same verdict vocabulary.
# Deliberate divergences, each forced by the platform:
#   - there is no Millennium loader log here. Steam's console_log.txt carries
#     no plugin lines on Windows (Millennium logs to its console window), so
#     the "loaded" stamp is the newest "hook installed" line in plugin.log:
#     the frontend writes it once per real start. The backend's own stamp
#     will not do -- plugin.restart and disable/enable truncate the log and
#     write a fresh "backend loaded" (then "backend unloaded") while the old
#     frontend keeps running (AGENTS.md, "Hard constraints"), which would
#     date a stale bundle as current. A log with a backend stamp and no hook
#     line is that state, and is reported as such.
#   - "current" cannot be answered by rebuilding here: bun run build overwrites
#     the live plugin. Instead the .star's mtime is compared with the newest
#     build input in the working tree (read from millennium.toml), and the
#     .star's SHA-256 is printed so a build made elsewhere can be compared
#     byte for byte.
#   - the .star is read from the Steam install the backend published (or the
#     registry before the backend has ever run), not ~/.local/share/millennium.
#   - section 2 also prints `steam-url: registered`. Clicks on Windows ride
#     Steam's own steam:// dispatch (frontend/steamurl.ts), so registering
#     that handler is startup work in exactly the way the hook is.
#   - section 3 also prints the newest toast Windows itself recorded: on
#     Windows the second half of "what did the last notification carry" (the
#     XML delivered, its launch URL) lives in the notification database, not
#     the log.
#   - pure ASCII, no PowerShell-7-only syntax, so Windows PowerShell 5.1 gets
#     the one-line refusal instead of a parse error (tools/lib/snn.ps1). The
#     verdict lines say "--" where tools/capture says an em dash; log lines
#     are printed as the plugin wrote them.
#
# Needs PowerShell 7 (pwsh), as the sibling tools do.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\snn.ps1')
Assert-Pwsh7 -Tool 'capture.ps1'
Set-Utf8Console

# $args, not a [Parameter()] block, for the reason tools/fire.ps1 gives: an
# advanced-function param block would let the binder claim dash-prefixed
# tokens meant for this tool.
$Lines = 8
if ($args.Count -ge 1 -and $args[0]) { $Lines = [int]$args[0] }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SteamDir = Get-SteamDir
if (-not $SteamDir) {
    [Console]::Error.WriteLine('No Steam install found (no published steam-dir, nothing in HKCU\Software\Valve\Steam) -- is Steam installed and has it run?')
    exit 1
}
$Bundle = Get-StarPath -SteamDir $SteamDir
$plugin = Read-PluginLog

function Write-Hr { '----------------------------------------------------------------' }
function Get-Stamp { param([datetime] $T) $T.ToString('yyyy-MM-dd HH:mm:ss') }

'== 1. is the running plugin the .star on disk? =='
$built = $null
if (Test-Path -LiteralPath $Bundle) {
    $built = (Get-Item -LiteralPath $Bundle).LastWriteTime
    "   built   $(Get-Stamp $built)"
    "   sha256  $((Get-FileHash -LiteralPath $Bundle -Algorithm SHA256).Hash.ToLower())"
} else {
    '   built   (no .star -- run: bun run build)'
}

$loadedLine = @($plugin | Where-Object { $_ -cmatch 'hook installed' }) | Select-Object -Last 1
$backendLine = @($plugin | Where-Object { $_ -cmatch 'backend loaded' }) | Select-Object -First 1
if ($loadedLine -and $loadedLine -cmatch '^\[([0-9-]+ [0-9:]+)\]') {
    $loaded = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
    "   loaded  $(Get-Stamp $loaded)"
    if ($built -and $built -gt $loaded) {
        '   STALE -- Steam is running an older build.'
        '   ANY change needs a FULL Steam restart (plugin.restart and disable/enable'
        '   leave the backend stopped and never reload the frontend):'
        '   steam.exe -shutdown, wait, relaunch, re-run this.'
    } else {
        '   current.'
    }
} elseif ($backendLine) {
    '   loaded  (unknown) -- plugin.log holds a backend stamp but no "hook installed":'
    '   a plugin restart or toggle truncated it, the backend is stopped, and the'
    '   frontend still running is of unknown age. Full Steam restart.'
} else {
    '   loaded  (never) -- enable the plugin in Millennium > Plugins.'
}

# No rebuild here (bun run build would overwrite the running plugin), so the
# working tree answers "would a build change anything" by mtime alone. The
# build inputs are whatever millennium.toml names: every quoted path under
# [frontend] and [backend] taken at its first path segment (the entry pulls
# in its whole tree), every [assets] path as the file it is (tools/ holds
# more than the two assets), plus the manifest itself. A new source root in
# the manifest is picked up here without editing this list.
$manifest = Join-Path $RepoRoot 'millennium.toml'
$roots = @('millennium.toml')
$section = ''
foreach ($line in [IO.File]::ReadAllLines($manifest)) {
    if ($line -match '^\s*\[(\w+)\]') { $section = $Matches[1]; continue }
    if ($section -in @('frontend', 'backend')) {
        foreach ($m in [regex]::Matches($line, '"([^"]+)"')) { $roots += ($m.Groups[1].Value -split '/')[0] }
    } elseif ($section -eq 'assets') {
        foreach ($m in [regex]::Matches($line, '"([^"]+)"')) { $roots += $m.Groups[1].Value }
    }
}
$newest = $roots | Sort-Object -Unique | ForEach-Object { Join-Path $RepoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -ErrorAction SilentlyContinue } |
    Sort-Object LastWriteTime | Select-Object -Last 1
if ($newest) {
    "   sources $(Get-Stamp $newest.LastWriteTime)  ($($newest.FullName.Substring($RepoRoot.Length + 1)))"
    if ($built -and $newest.LastWriteTime -gt $built) {
        '   the working tree is newer than the .star -- run: bun run build'
    }
}

Write-Hr
'== 2. did the hook attach, and did startup data load? =='
# The prefixes are the contract in frontend/log.ts (tools/lib/snn.ps1 holds
# them). `steam-url: registered` is the Windows half of startup: without the
# steam://snn/replay/<toast> handler a toast still delivers but every click
# is a no-op, so it belongs beside the hook lines rather than in section 3.
$verdict = @($plugin | Where-Object { $_ -cmatch $SnnLog.Startup } | Select-Object -Last 6)
if ($verdict.Count) { $verdict } else { '   (nothing yet -- no plugin.log; has the backend loaded?)' }

Write-Hr
'== 3. what did the last notifications carry? =='
# A `dev-fire:` line with no `from-toast` line after it means Steam's own
# per-type gating swallowed the test fire, not a break. `replay: candidates`
# shows what the walk stashed for each toast; `steam-url: replay` +
# `replay: invoke` show what a click did with it (the Windows shape of
# `click-bridge:`).
# The newest toast Windows recorded for the plugin's identity: what the
# helper actually delivered, from the notification platform's own database.
try {
    . (Join-Path $PSScriptRoot 'lib\toastdb.ps1')
    $row = @(Get-ToastRows -Limit 1) | Select-Object -First 1
    if ($row) {
        $facts = Get-ToastFacts -Xml $row.Xml
        "   delivered $($row.ArrivedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))  '$($facts.Title)' / '$($facts.Body)'  launch=$($facts.Launch)"
    } else {
        "   delivered (nothing recorded for $SnnAumid)"
    }
} catch {
    "   delivered (notification database not readable: $($_.Exception.Message))"
}
$notifs = @($plugin | Where-Object { $_ -cmatch $SnnLog.Notification } | Select-Object -Last $Lines)
if ($notifs.Count) { $notifs } else { '   (no notifications captured yet -- trigger one)' }
