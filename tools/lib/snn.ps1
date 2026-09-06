# Shared plumbing for the Windows tools (tools/fire.ps1, tools/capture.ps1,
# tools/mep.ps1) and the live harness (tests/windows). Dot-source it:
#
#   . (Join-Path $PSScriptRoot 'lib\snn.ps1')
#
# What lives here is everything more than one of them needs: the plugin's
# identity, where its runtime state and the installed .star are, how to read
# plugin.log without colliding with the backend, how to write the dev door,
# and the log-prefix contract from frontend/log.ts.
#
# This file and every script that dot-sources it are pure ASCII with no
# PowerShell-7-only syntax (no ??, ?., ternary). Windows PowerShell 5.1 parses
# a whole file before running a line of it, and reads a BOM-less file as the
# ANSI code page: a mis-decoded em dash closes a string literal early and a
# ?? is an unknown token, so either one is a parse error raised before any
# version guard could speak. Keeping the files parseable is what lets
# Assert-Pwsh7 print its one line instead.

Set-StrictMode -Version Latest

# millennium.toml [plugin] id; also the AppUserModelId tools/notify-action.ps1
# registers, so Windows records every toast under this string.
$SnnPluginId = 'me.tysmith.steam-native-notify'
$SnnAumid = $SnnPluginId

# The prefixes frontend/log.ts and backend/main.lua write. Case-sensitive
# matches throughout (-cmatch), because grep -aE in the bash tools is, and a
# renamed prefix must read as "nothing logged", not as a stale answer.
$SnnLog = @{
    Hook          = 'hook installed|hook failed|g_PopupManager never appeared'
    Startup       = 'hook installed|hook failed|g_PopupManager never appeared|helper|steam-url: registered'
    UrlRegistered = 'steam-url: registered'
    # A fire the frontend refused ("... is not a function") never reaches
    # Steam and must not count as one Steam swallowed.
    Fire          = 'dev-fire: (NotificationStore\.Test|OnServerNotification)(?!.*is not a function)'
    # Every delivery writes the "toast <name> -> {...}" line; "from-toast" is
    # written only when the fiber decode succeeded, so it under-counts.
    Delivered     = 'toast \S+ -> \{'
    Toast         = 'from-toast '
    Notification  = 'from-toast |toast .* -> |dev-fire|replay: candidates|replay: invoke|click-bridge|steam-url: replay'
}

function Assert-Pwsh7 {
    # One line and exit 1, matching the bash and Python twins' SystemExit.
    param([Parameter(Mandatory)][string] $Tool, [string] $Because = 'Windows PowerShell 5.1 is not supported.')
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Console]::Error.WriteLine("$Tool needs PowerShell 7 (pwsh): $Because")
        exit 1
    }
}

function Set-Utf8Console {
    # Log lines and toast bodies carry em dashes and game titles; without this
    # the console transcodes them to the OEM code page and the output lies
    # about what the plugin logged.
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
}

function Show-HeaderUsage {
    # The header comment is the usage text, the way tools/fire prints its own
    # and tools/mep prints __doc__.
    param([Parameter(Mandatory)][string] $Path)
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -eq '#!/usr/bin/env pwsh') { continue }
        if (-not $line.StartsWith('#')) { break }
        $line -replace '^# ?', ''
    }
}

function Get-SnnRuntimeDir {
    # backend/main.lua computes the same path; the packed .star has no plugin
    # directory at runtime, so every runtime file lives here.
    $local = $env:LOCALAPPDATA
    if (-not $local) { $local = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $local 'steam-native-notify')
}

function Get-PublishedSteamDir {
    # The backend writes millennium.steam_path() to steam-dir at every load
    # (backend/main.lua), rewritten each time and removed when there is no
    # answer, so the file is both the authoritative Steam path and the proof
    # that the backend has loaded at least once. An empty or whitespace file
    # is a failed publish and reads as $null, never as an exception.
    param([string] $RuntimeDir = (Get-SnnRuntimeDir))
    $file = Join-Path $RuntimeDir 'steam-dir'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $dir = ([IO.File]::ReadAllText($file).Trim()) -replace '/', '\'
    if ($dir -eq '' -or -not (Test-Path -LiteralPath $dir)) { return $null }
    return $dir
}

function Get-SteamDir {
    # The published path first (it is what Millennium actually resolved), the
    # registry only when the backend has never run. No hardcoded fallback: a
    # guess would let a tool report on a Steam that is not the one running.
    $published = Get-PublishedSteamDir
    if ($published) { return $published }
    foreach ($k in @(
            @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamPath' },
            @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' },
            @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Name = 'InstallPath' })) {
        try { $v = (Get-ItemProperty -LiteralPath $k.Path -Name $k.Name -ErrorAction Stop).($k.Name) } catch { continue }
        if ($v) { $v = ([string]$v) -replace '/', '\'; if (Test-Path -LiteralPath $v) { return $v } }
    }
    return $null
}

function Get-StarPath {
    # starlight's output_path = "auto" resolves to this under the Steam install
    # (Millennium: MILLENNIUM__PLUGINS_PATH = <install>/plugins).
    param([string] $SteamDir = (Get-SteamDir))
    if (-not $SteamDir) { return $null }
    return (Join-Path $SteamDir "millennium\plugins\$SnnPluginId.star")
}

function Read-PluginLog {
    # Every non-empty line of plugin.log, always as an array (the unary
    # comma keeps a zero- or one-line log from unrolling to $null or a bare
    # string on the way out). Opened share-ReadWrite so a read never
    # collides with the backend appending.
    param([string] $Path = (Join-Path (Get-SnnRuntimeDir) 'plugin.log'))
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $text = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)).ReadToEnd() }
    finally { $fs.Dispose() }
    return ,@($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Write-DevFire {
    # One JSON line into the dev door. UTF-8 without a BOM and an LF newline:
    # the backend hands the bytes to the frontend's JSON parse, and a BOM
    # would land in front of the opening brace.
    param([Parameter(Mandatory)][string] $Json, [string] $RuntimeDir = (Get-SnnRuntimeDir))
    [IO.Directory]::CreateDirectory($RuntimeDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $RuntimeDir '.dev-fire'), "$Json`n", [Text.UTF8Encoding]::new($false))
}

function Get-ToastQueueVerdict {
    # Is Steam still granting toast popups? After a long run of test fires
    # Steam can stop creating them and stay that way until a full restart
    # (docs/windows-testing.md, "Steam's toast queue stalls in long test
    # sessions"); from every other angle that looks like a delivery
    # regression. The tell is fires piling up after the last toast: both
    # doors count (Steam's own Test* methods and the server path). One
    # trailing fire is ordinary, Steam gates individual types; two or more
    # after the last toast is the stall. No log at all is "granting": there
    # is nothing to hold against Steam yet.
    param([AllowNull()][AllowEmptyCollection()][string[]] $Lines)
    if ($null -eq $Lines) { $Lines = @() }
    $lastToast = -1
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        if ($Lines[$i] -cmatch $SnnLog.Delivered) { $lastToast = $i; break }
    }
    $after = if ($lastToast + 1 -lt $Lines.Count) { $Lines[($lastToast + 1)..($Lines.Count - 1)] } else { @() }
    $orphans = @($after | Where-Object { $_ -cmatch $SnnLog.Fire })
    $text = if ($orphans.Count -eq 0) { 'granting (the last fire produced a toast)' }
    elseif ($orphans.Count -eq 1) { "1 fire with no toast after it (Steam gates single types; watch the next)" }
    else { "STALLED -- $($orphans.Count) fires with no toast since the last one; full Steam restart required" }
    return [pscustomobject]@{
        OrphanFires = $orphans.Count
        Newest      = if ($orphans.Count) { $orphans[-1] } else { $null }
        Stalled     = ($orphans.Count -ge 2)
        Text        = $text
    }
}
