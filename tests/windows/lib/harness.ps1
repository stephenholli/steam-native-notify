# Harness plumbing: the dev door with its consumption wait, the log oracle,
# screenshots, and the PASS/FAIL ledger every scenario writes into. Paths,
# identity and the log-prefix contract come from tools/lib/snn.ps1.
#
# Nothing here talks to Steam directly. The plugin's dev door (a JSON line in
# .dev-fire, consumed by frontend/devfire.ts within ~3s) is the only input,
# and plugin.log plus the Windows notification database are the only outputs
# read back -- so a run needs no window focus and no human watching.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\..\tools\lib\snn.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:RuntimeDir = Get-SnnRuntimeDir
# The log oracle can be pointed at a file, which is how the pre-checks that
# read the log (the queue-stall detector) are exercised without a running Steam.
# Only the log moves: a fire still goes through the real dev door, so a run
# with this set can inspect but never invent a delivery.
$script:PluginLog = if ($env:SNN_PLUGIN_LOG) { $env:SNN_PLUGIN_LOG } else { Join-Path $script:RuntimeDir 'plugin.log' }
$script:DevFire = Join-Path $script:RuntimeDir '.dev-fire'

# ---------------------------------------------------------------- the log

# Read-PluginLog (tools/lib/snn.ps1) re-reads the whole file; a Wait-LogLine
# poll asks every 250 ms for seconds at a time, so the read is skipped while
# the file's length has not moved.
$script:LogLength = -1
$script:LogLines = @()
function Get-LogLines {
    $len = if (Test-Path -LiteralPath $script:PluginLog) { (Get-Item -LiteralPath $script:PluginLog).Length } else { 0 }
    if ($len -ne $script:LogLength) {
        $script:LogLines = Read-PluginLog -Path $script:PluginLog   # always an array
        $script:LogLength = $len
    }
    return ,$script:LogLines
}

function Get-LogMark {
    <#  .SYNOPSIS How many lines are in the log now; the tail marker for a run. #>
    return (Get-LogLines).Count
}

function Get-LogSince {
    param([Parameter(Mandatory)][int]$Mark)
    $all = Get-LogLines
    # The backend truncates plugin.log at each load. A shorter log than the
    # mark means that happened mid-run, and the whole log is the new tail.
    if ($all.Count -lt $Mark) { return $all }
    if ($all.Count -eq $Mark) { return @() }
    return $all[$Mark..($all.Count - 1)]
}

function Wait-LogLine {
    <#
      .SYNOPSIS Wait for a log line matching -Pattern to appear after -Mark.
      .OUTPUTS  The matching line, or $null on timeout.
    #>
    param([Parameter(Mandatory)][int]$Mark, [Parameter(Mandatory)][string]$Pattern,
          [double]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $hit = Get-LogSince -Mark $Mark | Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

# ----------------------------------------------------------- the dev door

function Invoke-DevFire {
    <#
      .SYNOPSIS Write one dev-door command and wait for the frontend to eat it.

      The file disappearing is the frontend's acknowledgement: backend/main.lua
      hands the line over and deletes it, so a file still on disk after the
      timeout means no frontend is polling (Steam down, plugin disabled, or
      devMode/devFire off in the plugin's settings).
    #>
    param([Parameter(Mandatory)][string]$Json, [double]$TimeoutSec = 15)
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
        throw "no plugin runtime directory at $script:RuntimeDir -- has the backend ever loaded?"
    }
    Write-DevFire -Json $Json -RuntimeDir $script:RuntimeDir
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Path -LiteralPath $script:DevFire) -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Milliseconds 200
    }
    $consumed = -not (Test-Path -LiteralPath $script:DevFire)
    if (-not $consumed) {
        # Leaving it behind would fire this run's command at whoever loads the
        # frontend next, minutes or hours later, as a surprise.
        Remove-Item -LiteralPath $script:DevFire -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Consumed  = $consumed
        ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}

# ------------------------------------------------------------------ evidence

function Save-Screenshot {
    <#
      .SYNOPSIS PNG of the primary display, or of one rectangle of it.
      .OUTPUTS  The path written.
    #>
    param([Parameter(Mandatory)][string]$Path, [int[]]$Rect)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = 0; $y = 0; $w = $bounds.Width; $h = $bounds.Height
    if ($Rect -and $Rect.Count -eq 4) {
        # Clamped: a banner near the screen edge would otherwise crop out of bounds.
        $x = [Math]::Max(0, [Math]::Min($Rect[0], $bounds.Width - 1))
        $y = [Math]::Max(0, [Math]::Min($Rect[1], $bounds.Height - 1))
        $w = [Math]::Max(1, [Math]::Min($Rect[2], $bounds.Width - $x))
        $h = [Math]::Max(1, [Math]::Min($Rect[3], $bounds.Height - $y))
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Copied straight into a bitmap of the target size: no full-screen
    # capture and clone for a corner crop.
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    return $Path
}

# ------------------------------------------------------------------- ledger

function New-Ledger {
    param([string]$Name)
    [pscustomobject]@{
        Name    = $Name
        Results = New-Object System.Collections.Generic.List[object]
        Started = Get-Date
    }
}

function Add-Assertion {
    <#
      .SYNOPSIS Record one PASS/FAIL/WARN with the evidence that decided it.

      Evidence is the point: a bare PASS is an assertion about the harness,
      not about the plugin, so every row carries the log line, XML slot or
      measurement it read.
    #>
    param([Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][bool]$Ok, [string]$Evidence = '', [switch]$Warn)
    $status = if ($Ok) { 'PASS' } elseif ($Warn) { 'WARN' } else { 'FAIL' }
    $Ledger.Results.Add([pscustomobject]@{ Name = $Name; Status = $status; Evidence = $Evidence })
    $colour = switch ($status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ("  {0,-4} {1}" -f $status, $Name) -ForegroundColor $colour
    if ($Evidence) {
        foreach ($line in ($Evidence -split "`n")) { Write-Host "         $line" -ForegroundColor DarkGray }
    }
}

function Write-LedgerSummary {
    <#  .OUTPUTS The number of FAILs, which is the run's exit code. #>
    param([Parameter(Mandatory)]$Ledger)
    $by = @{ PASS = 0; FAIL = 0; WARN = 0 }
    foreach ($r in $Ledger.Results) { $by[$r.Status]++ }
    $secs = [int]((Get-Date) - $Ledger.Started).TotalSeconds
    Write-Host ''
    Write-Host ("{0}: {1} passed, {2} failed, {3} warned in {4}s" -f $Ledger.Name, $by.PASS, $by.FAIL, $by.WARN, $secs) `
        -ForegroundColor $(if ($by.FAIL) { 'Red' } else { 'Green' })
    foreach ($r in $Ledger.Results) { if ($r.Status -eq 'FAIL') { Write-Host "  FAILED: $($r.Name)" -ForegroundColor Red } }
    return $by.FAIL
}
