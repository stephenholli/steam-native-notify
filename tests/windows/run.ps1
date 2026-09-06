<#
.SYNOPSIS
    Run one Windows notification scenario end to end and print PASS/FAIL per
    assertion, with the evidence each one read.

.DESCRIPTION
    The chain under test is: dev door -> Steam's NotificationStore -> the
    plugin's capture (frontend/index.tsx) -> the backend's spawn
    (backend/main.lua) -> tools/notify-action.ps1 -> the Windows notification
    platform -> a click -> steam://snn/replay/<toast> -> frontend/steamurl.ts
    -> frontend/replay.ts.

    Four independent oracles decide, in that order:
      dev door     the .dev-fire file disappearing (the frontend consumed it)
      plugin.log   what the frontend captured, sent and replayed
      toast DB     the XML Windows actually recorded for this AUMID
      the click    what the log says after the toast is clicked for real

    No window focus is needed and nothing is typed into Steam; the only
    on-screen action is the click itself.

.PARAMETER Scenario
    Name of a file in scenarios/ (without .ps1). Default: download-complete.

.PARAMETER Click
    Which surface to click: banner (default), center, both, or none.

.PARAMETER FirstCardOffsetY
    How far below the Notification Center's top edge the newest card's centre
    sits, in physical pixels. The panel's contents are invisible to UI
    Automation, so -Click center|both addresses the card by geometry; the
    default lives in lib/ui.ps1 (165 at 100% scaling, scaled to the display's
    DPI). Override it here, unscaled, if a Windows update moves the list.

.PARAMETER IgnoreQueueStall
    Fire even when the pre-check says Steam's toast queue has stalled (a
    long test session can leave it creating no popups until restart).

.PARAMETER FailDemo
    Deliberately expect the wrong toast title, to show the harness reports
    FAIL honestly rather than passing on a run that "looked" fine.

.EXAMPLE
    pwsh -File tests/windows/run.ps1
    pwsh -File tests/windows/run.ps1 -Click both
    pwsh -File tests/windows/run.ps1 -FailDemo
#>
[CmdletBinding()]
param(
    [string]$Scenario = 'download-complete',
    [ValidateSet('banner', 'center', 'both', 'none')][string]$Click = 'banner',
    [switch]$FailDemo,
    [string]$EvidenceDir = '',
    [int]$FirstCardOffsetY = 0,
    [switch]$KeepNotificationCentreOpen,
    [switch]$IgnoreQueueStall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\harness.ps1')   # dot-sources tools/lib/snn.ps1
Assert-Pwsh7 -Tool 'run.ps1'
Set-Utf8Console
. (Join-Path $PSScriptRoot '..\..\tools\lib\toastdb.ps1')
. (Join-Path $PSScriptRoot 'lib\ui.ps1')
# Resolved here, not in the param block: Windows PowerShell 5.1 has no
# $PSScriptRoot while binding parameters, and the refusal above must speak first.
if (-not $EvidenceDir) { $EvidenceDir = Join-Path $PSScriptRoot 'evidence' }
if (-not $FirstCardOffsetY) { $FirstCardOffsetY = Scale-Px $script:DefaultFirstCardOffsetY }

# A scenario is a name, not a path: without this guard, a name like
# '..\..' or 'sub/name' would dot-source an arbitrary file with this run's rights.
if ($Scenario -match '[\\/]' -or $Scenario.Contains('..')) {
    Write-Host "scenario names are plain file names, not paths: $Scenario" -ForegroundColor Red
    exit 2
}
$scenarioFile = Join-Path $PSScriptRoot "scenarios\$Scenario.ps1"
if (-not (Test-Path -LiteralPath $scenarioFile)) {
    Write-Host "no such scenario: $Scenario" -ForegroundColor Red
    Write-Host "available: $((Get-ChildItem (Join-Path $PSScriptRoot 'scenarios') -Filter *.ps1 | ForEach-Object BaseName) -join ', ')"
    exit 2
}
$s = & $scenarioFile
if ($FailDemo) {
    # One expectation, poisoned. Everything else in the run is unchanged, so
    # the output shows a single honest FAIL among real passes.
    $s.ToastTitle = '^Download Complete (this string is never in a toast)$'
}

Write-Host ''
Write-Host "scenario: $($s.Name)" -ForegroundColor Cyan
Write-Host "          $($s.Description)" -ForegroundColor DarkGray
if ($FailDemo) { Write-Host '          -FailDemo: the toast-title expectation is deliberately wrong' -ForegroundColor Yellow }
Write-Host ''

$ledger = New-Ledger -Name $s.Name
$replayUrl = "steam://snn/replay/"

# ------------------------------------------------------------- 0. preflight
# A plugin that never loaded cannot fail an assertion meaningfully, it can
# only time out; say so up front instead.

Add-Assertion $ledger 'runtime directory exists' (Test-Path -LiteralPath $script:RuntimeDir) $script:RuntimeDir
$steamDir = Get-PublishedSteamDir -RuntimeDir $script:RuntimeDir
Add-Assertion $ledger 'backend published steam-dir' ([bool]$steamDir) "steam-dir: $steamDir"
$log = Get-LogLines
# The LAST word on the hook, not any word: a load that logged 'hook installed'
# and then 'hook failed' on a later attach is not hooked.
$hookLine = @($log | Where-Object { $_ -cmatch $SnnLog.Hook }) | Select-Object -Last 1
Add-Assertion $ledger 'frontend hook attached' ([bool]$hookLine -and $hookLine -cmatch 'hook installed') `
    $(if ($hookLine) { $hookLine } else { 'no hook line in plugin.log' })
$urlLine = @($log | Where-Object { $_ -cmatch $SnnLog.UrlRegistered }) | Select-Object -Last 1
Add-Assertion $ledger 'steam:// click path registered' ([bool]$urlLine) $(if ($urlLine) { $urlLine } else { 'no steam-url: registered line' })

# Steam does not raise desktop toasts while a game is running -- the dev-fire
# line lands and nothing follows it. That is Steam's gate, not a plugin fault,
# so it warns here rather than failing, and names itself before the capture
# assertion times out.
$appId = 0
try { $appId = [int](Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name RunningAppID -ErrorAction Stop).RunningAppID } catch { }
Add-Assertion $ledger 'no game is running' ($appId -eq 0) "Steam RunningAppID=$appId" -Warn

# Click and screenshot geometry is physical pixels on a per-monitor-aware
# thread (lib/ui.ps1), and the card offset scales with the DPI read here; a
# DPI of 0 means the read failed and the geometry is a guess.
$dpi = Get-SystemDpi
Add-Assertion $ledger 'display DPI read (click geometry scales with it)' ($dpi -gt 0) "GetDpiForSystem=$dpi ($([int][math]::Round($dpi * 100 / 96))% scaling); card offset $FirstCardOffsetY px"

# The queue pre-check is tools/capture.ps1's question (Get-ToastQueueVerdict
# in tools/lib/snn.ps1); a stalled queue looks exactly like a delivery
# regression from every other oracle, so it is caught here, before a fire.
$queue = Get-ToastQueueVerdict -Lines $log
$evidence = if ($queue.OrphanFires) { "$($queue.Text); newest: $($queue.Newest)" } else { $queue.Text }
if ($queue.Stalled -and -not $IgnoreQueueStall) {
    Add-Assertion $ledger 'Steam toast queue is granting popups' $false $evidence
    Write-Host ''
    Write-Host 'Steam toast queue stalled (long test session), or this type is gated by Steam twice in a row.' -ForegroundColor Red
    Write-Host 'If the type is one Steam is allowed to raise: full Steam restart required.' -ForegroundColor Red
    Write-Host '(-IgnoreQueueStall fires anyway.)' -ForegroundColor DarkGray
    exit (Write-LedgerSummary $ledger)
}
Add-Assertion $ledger 'Steam toast queue is granting popups' ($queue.OrphanFires -eq 0) $evidence -Warn

# An open Notification Center swallows the banner: Windows sends the toast
# straight to the list rather than painting one. A panel left open by an
# earlier run would then fail this run's banner assertion for no reason, so
# it is closed here rather than diagnosed later.
$centreWasOpen = Test-NotificationCentreShowing
if ($centreWasOpen) { Close-NotificationCentre }
Add-Assertion $ledger 'Notification Center was closed before firing' (-not $centreWasOpen) `
    $(if ($centreWasOpen) { 'it was open (a banner would have been suppressed); closed it' } else { 'closed' }) -Warn

$mark = Get-LogMark
# Time, not row id: ids are not guaranteed to be handed out in arrival order
# across handlers, and the platform reuses them after a purge.
$dbMarkUtc = (Get-Date).ToUniversalTime().AddSeconds(-2)

# ------------------------------------------------------------- 1. dev door

$fire = Invoke-DevFire -Json $s.DevFire
Add-Assertion $ledger 'dev-fire consumed by the frontend' $fire.Consumed `
    "$($s.DevFire)  (consumed in $($fire.ElapsedMs)ms)"
if (-not $fire.Consumed) {
    Write-Host ''
    Write-Host 'The dev door is not being read. Steam down, plugin disabled, or devMode/devFire off.' -ForegroundColor Red
    exit (Write-LedgerSummary $ledger)
}

$devLine = Wait-LogLine -Mark $mark -Pattern $s.DevFireLog -TimeoutSec 10
Add-Assertion $ledger 'frontend logged the dev-fire call' ([bool]$devLine) $devLine

# ------------------------------------------------------ 2. capture in Steam

# Steam's own gating (a type the user has switched off) shows up exactly here:
# a dev-fire line with no toast line after it.
$toastLine = Wait-LogLine -Mark $mark -Pattern 'toast \S+ -> \{' -TimeoutSec 10
Add-Assertion $ledger 'plugin captured a Steam toast' ([bool]$toastLine) $toastLine
if (-not $toastLine) {
    Write-Host ''
    Write-Host 'Steam created no toast popup. Three known causes, in order of likelihood:' -ForegroundColor Red
    Write-Host '  * Steam''s toast queue has stalled -- after a long test session it stops creating' -ForegroundColor Red
    Write-Host '    popups and stays that way until the client restarts (README.md).' -ForegroundColor Red
    Write-Host '  * This notification type is switched off in Steam''s own settings, or a game is running.' -ForegroundColor Red
    Write-Host '  * Another process wrote .dev-fire over this run''s line before the frontend read it.' -ForegroundColor Red
    exit (Write-LedgerSummary $ledger)
}

$m = [regex]::Match($toastLine, 'toast (?<name>\S+) -> (?<json>\{.*?\})(?<tail>\s*\(suppressed[^)]*\))?$')
$toastName = $m.Groups['name'].Value
$toastRe = [regex]::Escape($toastName)
$payload = $m.Groups['json'].Value | ConvertFrom-Json
$suppressed = $m.Groups['tail'].Success

Add-Assertion $ledger 'toast was not suppressed by plugin settings' (-not $suppressed) `
    $(if ($suppressed) { $m.Groups['tail'].Value.Trim() } else { "notify settings allowed delivery of $toastName" })

$candLine = Wait-LogLine -Mark $mark -Pattern "replay: candidates $toastRe " -TimeoutSec 5
# 'stashed=none (ambiguous)' is also a `stashed=` line: the walk ran, found no
# handler it trusted, and the toast is deliberately unclickable. Only a
# prop@depth counts (frontend/replay.ts stashToastHandler).
$stashed = $candLine -and $candLine -match 'stashed=\w+@\d+'
Add-Assertion $ledger 'a click handler was stashed for the toast' ([bool]$stashed) `
    $(if ($candLine) { $candLine } else { "no 'replay: candidates' line for $toastName" })

$fromToast = Wait-LogLine -Mark $mark -Pattern "from-toast $toastRe " -TimeoutSec 5
Add-Assertion $ledger 'notification payload decoded' `
    ([bool]$fromToast -and $fromToast -match $s.FromToast) "$fromToast`nexpected: $($s.FromToast)"

Add-Assertion $ledger 'captured title matches' ([bool]($payload.title -match $s.Title)) `
    "title='$($payload.title)' expected /$($s.Title)/"
Add-Assertion $ledger 'captured body matches' ([bool]($payload.body -match $s.Body)) `
    "body='$($payload.body)' expected /$($s.Body)/"
Add-Assertion $ledger 'captured image matches' ([bool]($payload.image -match $s.Image)) `
    "image='$($payload.image)' expected /$($s.Image)/"
Add-Assertion $ledger 'route carries the replay token' `
    ([bool]($payload.route -eq "replay:$toastName")) "route='$($payload.route)'"

# ------------------------------------------------- the click helpers

function Test-Click {
    <#
      .SYNOPSIS Click a surface and read the whole click chain out of the log.

      -Recheck names a shell window that must still be painted at the moment
      of the click; its rectangle is re-read and the click is aimed at the
      fresh centre. A banner lives about five seconds, and everything between
      the delivery assertions and here takes time, so the rectangle captured
      earlier can name a banner that has already gone -- clicking that lands
      on whatever is behind it.
    #>
    param([string]$Surface, [int]$X, [int]$Y, [int]$Mark, [string]$Recheck)
    if ($Recheck) {
        $fresh = Get-ShellWindowRect -Title $Recheck
        if (-not $fresh -or $fresh.Height -lt $script:BannerMinHeight) {
            Add-Assertion $ledger "$Surface click reached Steam ($replayUrl)" $false `
                "banner expired before click ('$Recheck' height=$(if ($fresh) { $fresh.Height } else { 'gone' })); nothing was clicked"
            return
        }
        $X = $fresh.CentreX; $Y = $fresh.CentreY
    }
    Invoke-ClickAt -X $X -Y $Y
    $url = Wait-LogLine -Mark $Mark -Pattern "steam-url: replay:$toastRe" -TimeoutSec 10
    Add-Assertion $ledger "$Surface click reached Steam ($replayUrl)" ([bool]$url) `
        $(if ($url) { $url } else { "clicked at $X,$Y; no steam-url line for $toastName" })
    if (-not $url) { return }
    # The window, not only the URL: a click brings Steam forward on this
    # client (lib/ui.ps1, Wait-SteamForeground). WARN because the foreground
    # is Windows' to grant, and a refusal would be Windows', not the plugin's.
    $fg = Wait-SteamForeground -TimeoutSec 3
    Add-Assertion $ledger "$Surface click brought Steam's window to the foreground" ([bool]$fg) `
        $(if ($fg) { "foreground: $fg" } else { "foreground after 3 s: $(Get-ForegroundOwner)" }) -Warn
    $inv = Wait-LogLine -Mark $Mark -Pattern "replay: invoke $toastRe " -TimeoutSec 5
    Add-Assertion $ledger "$Surface click found the stashed handler" `
        ([bool]$inv -and $inv -notmatch 'no stash entry|expired|entry has no handler') $inv
    $ran = Wait-LogLine -Mark $Mark -Pattern "replay: invoke $toastRe -> " -TimeoutSec 5
    Add-Assertion $ledger "$Surface click replayed Steam's own handler" `
        ([bool]$ran -and $ran -match 'returned without throwing') $ran
}

function Test-NewestCardIsOurs {
    <#
      .SYNOPSIS Is the top card in the Notification Center this run's toast?

      The card is clicked by geometry, so before clicking it the database is
      asked what the newest notification on this machine actually is. It has
      to be ours, and its launch URL has to name the toast under test --
      anything else means another app (or an older toast of ours) is sitting
      where the click is aimed, and the click is skipped rather than fired
      blind at someone else's notification.
      .OUTPUTS [pscustomobject] Ok, Why
    #>
    param([Parameter(Mandatory)][string]$ToastName)
    $newest = @(Get-NewestNotificationRow) | Select-Object -First 1
    if (-not $newest) { return [pscustomobject]@{ Ok = $false; Why = 'the notification database has no rows' } }
    if ($newest.Aumid -ne $SnnAumid) {
        return [pscustomobject]@{ Ok = $false
            Why = "the newest notification is $($newest.Aumid)'s, not ours (arrived $($newest.ArrivedUtc.ToLocalTime().ToString('HH:mm:ss')))" }
    }
    $launch = (Get-ToastFacts -Xml $newest.Xml).Launch
    if ($launch -ne "$replayUrl$ToastName") {
        return [pscustomobject]@{ Ok = $false; Why = "the newest card is an older toast of ours: launch='$launch'" }
    }
    return [pscustomobject]@{ Ok = $true; Why = "newest notification is ours: launch='$launch'" }
}

# ------------------------------------------- 3. the banner, while it is there
# Before the database oracle, not after: a Windows banner is on screen for
# about five seconds, and copying the notification database (plus its WAL)
# takes longer than that. Reading the slow oracle first made the banner
# assertion fail on a delivery that was perfectly fine.

$banner = Wait-ToastBanner -TimeoutSec 8
if ($banner) {
    $shot = Save-Screenshot -Path (Join-Path $EvidenceDir "$($s.Name)-banner.png") `
        -Rect @(($banner.Left - 40), ($banner.Top - 40), ($banner.Width + 80), ($banner.Height + 60))
}
Add-Assertion $ledger 'banner painted on screen' ([bool]$banner) `
    $(if ($banner) { "New notification window at $($banner.Left),$($banner.Top) $($banner.Width)x$($banner.Height); $shot" }
      else { 'the "New notification" window never grew past zero height (Do Not Disturb? banners disabled for this app?)' })

# ------------------------------------------------- 4. what Windows recorded
# Before the click, not after: activating a toast removes it from the
# Notification Center *and* from the database, so a row read afterwards is
# gone through no fault of the delivery. One database snapshot per poll
# tick, filtered in SQL to rows after the mark.

$deadline = (Get-Date).AddSeconds(10)
$row = $null
do {
    $row = @(Get-ToastRows -Aumid $SnnAumid -Since $dbMarkUtc -Limit 1) | Select-Object -First 1
    if ($row) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)

Add-Assertion $ledger 'Windows recorded a toast for this AUMID' ([bool]$row) `
    $(if ($row) { "row id=$($row.Id) arrived=$($row.ArrivedUtc.ToLocalTime().ToString('HH:mm:ss')) handler=$($row.Aumid)" }
      else { "no notification row for $SnnAumid after $($dbMarkUtc.ToLocalTime().ToString('HH:mm:ss'))" })

if ($row) {
    $facts = Get-ToastFacts -Xml $row.Xml
    Add-Assertion $ledger 'toast title as delivered' ([bool]($facts.Title -match $s.ToastTitle)) `
        "title='$($facts.Title)' expected /$($s.ToastTitle)/"
    Add-Assertion $ledger 'toast body as delivered (UTF-8 intact)' ([bool]($facts.Body -match [regex]::Escape($s.ToastBody))) `
        "body='$($facts.Body)' expected to contain '$($s.ToastBody)'"
    Add-Assertion $ledger 'toast image resolved to a local file' `
        ([bool]($facts.ImageSrc -match $s.ToastImage)) "src='$($facts.ImageSrc)' expected /$($s.ToastImage)/"
    Add-Assertion $ledger 'image crop matches the source kind' `
        ([bool]($facts.ImageCrop -eq $s.ToastCrop)) "hint-crop='$($facts.ImageCrop)' expected '$($s.ToastCrop)'"
    Add-Assertion $ledger 'activation is protocol' ([bool]($facts.ActivationType -eq 'protocol')) `
        "activationType='$($facts.ActivationType)'"
    Add-Assertion $ledger 'launch URL routes back to this toast' `
        ([bool]($facts.Launch -eq "$replayUrl$toastName")) "launch='$($facts.Launch)'"
}

# --------------------------------------------------------------- 5. a click
if ($Click -in @('banner', 'both')) {
    if ($banner) {
        Test-Click -Surface 'banner' -X $banner.CentreX -Y $banner.CentreY -Mark $mark -Recheck $script:BannerTitle
    } else {
        Add-Assertion $ledger 'banner click' $false 'skipped: no banner was on screen to click'
    }
}

if ($Click -in @('center', 'both')) {
    # The banner has to be gone first, or the click lands on the banner and
    # proves nothing about the Notification Center copy. Polled to the moment
    # it parks, not slept in fixed steps.
    $gone = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $gone) {
        $r = Get-ShellWindowRect -Title $script:BannerTitle
        if (-not $r -or $r.Height -lt $script:BannerMinHeight) { break }
        Start-Sleep -Milliseconds 200
    }
    $centre = Open-NotificationCentre
    if ($centre) {
        $card = Get-NotificationCentreCardPoint -Rect $centre -FirstCardOffsetY $FirstCardOffsetY
        $shotC = Save-Screenshot -Path (Join-Path $EvidenceDir "$($s.Name)-action-center.png") `
            -Rect @($centre.Left, $centre.Top, $centre.Width, 600)
        Add-Assertion $ledger 'Notification Center opened' $true `
            "panel at $($centre.Left),$($centre.Top) $($centre.Width)x$($centre.Height); newest card at $($card.X),$($card.Y); $shotC"
        $own = Test-NewestCardIsOurs -ToastName $toastName
        if ($own.Ok) {
            Add-Assertion $ledger 'newest Notification Center card is this run''s toast' $true $own.Why
            $markC = Get-LogMark
            Test-Click -Surface 'action-center' -X $card.X -Y $card.Y -Mark $markC
        } else {
            Add-Assertion $ledger 'newest Notification Center card is this run''s toast' $false `
                "$($own.Why); click skipped rather than aimed at someone else's notification" -Warn
        }
        if (-not $KeepNotificationCentreOpen) { Close-NotificationCentre }
    } else {
        Add-Assertion $ledger 'Notification Center opened' $false 'Win+N did not open the panel'
    }
}

# ------------------------------------------ 6. the backend's own verdict
# The backend answers "ok" or the frontend leaves Steam's own toast open and
# says so; there is no success line to wait for, so the absence of that
# failure line is what proves the spawn was accepted. Polled, not slept: the
# line lands as soon as the notify promise settles, and a fixed wait is either
# too short on a slow spawn or wasted on every good run.
$leftOpen = Wait-LogLine -Mark $mark -TimeoutSec 3 `
    -Pattern "toast $toastRe left open|could not close $toastRe"
Add-Assertion $ledger 'backend accepted the notification (Steam toast closed)' (-not $leftOpen) `
    $(if ($leftOpen) { $leftOpen } else { "no 'left open' line for $toastName" })

# --------------------------------------------------------------- the ledger

$failed = Write-LedgerSummary $ledger
Write-Host ''
Write-Host "plugin log: $script:PluginLog" -ForegroundColor DarkGray
Write-Host "evidence:   $EvidenceDir" -ForegroundColor DarkGray
exit $failed
