$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP "snn-notify-action-$([Guid]::NewGuid())"
$helper = Join-Path $testRoot 'notify-action.ps1'
$process = $null

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $sourceHelper = Join-Path $PSScriptRoot 'notify-action.ps1'
    $helperSource = Get-Content -LiteralPath $sourceHelper -Raw
    if ($helperSource -notmatch '(?s)SetWindowPos\(target, HWND_TOPMOST.*SetWindowPos\(target, HWND_NOTOPMOST') {
        throw 'FAIL one-shot focus does not restore a reversible z-order raise'
    }
    Write-Output 'PASS one-shot focus restores its z-order raise'
    if ($helperSource -match 'add_Activated|Wait\(120000\)') {
        throw 'FAIL notification delivery still retains an activation callback'
    }
    Write-Output 'PASS notification delivery retains no activation callback'
    if ($helperSource -notmatch '\[string\]\$FocusKind') {
        throw 'FAIL helper has no route-aware focus mode'
    }
    Write-Output 'PASS helper has route-aware focus mode'
    if ($helperSource -notmatch 'steam://snn/click/\$\(\$Matches\[1\]\)') {
        throw 'FAIL helper does not persist the durable click envelope in the activation URI'
    }
    Write-Output 'PASS helper persists the durable click envelope in the activation URI'
    Copy-Item -LiteralPath $sourceHelper -Destination $helper

    $steamDir = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam').SteamPath
    Set-Content -LiteralPath (Join-Path $testRoot 'steam-dir') -Value $steamDir -Encoding utf8

    $id = 'routed-lifetime'
    @{
        title = 'Steam Native Notify lifetime test'
        body = 'This notification may be ignored.'
        image = ''
        route = 'click:eyJ2IjoxfQ'
        ingame = ''
    } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $testRoot "$id.notify") -Encoding utf8

    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $helper,
        '-Id', $id
    )
    if (-not $process.WaitForExit(10000)) {
        throw 'FAIL routed delivery retained an activation process'
    }
    Write-Output 'PASS routed delivery exited after Show'
    $process = $null

    $id = 'unrouted-lifetime'
    @{
        title = 'Steam Native Notify lifetime test'
        body = 'This notification may be ignored.'
        image = ''
        route = ''
        ingame = ''
    } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $testRoot "$id.notify") -Encoding utf8

    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $helper,
        '-Id', $id
    )
    if (-not $process.WaitForExit(10000)) {
        throw 'FAIL unrouted helper retained an activation window'
    }

    Write-Output 'PASS unrouted helper exited after delivery'
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
