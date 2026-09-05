$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP "snn-notify-action-$([Guid]::NewGuid())"
$helper = Join-Path $testRoot 'notify-action.ps1'
$process = $null

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'notify-action.ps1') -Destination $helper

    $steamDir = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam').SteamPath
    Set-Content -LiteralPath (Join-Path $testRoot 'steam-dir') -Value $steamDir -Encoding utf8

    $id = 'routed-lifetime'
    @{
        title = 'Steam Native Notify lifetime test'
        body = 'This notification may be ignored.'
        image = ''
        route = 'replay:lifetime-test'
        ingame = ''
    } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $testRoot "$id.notify") -Encoding utf8

    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $helper,
        '-Id', $id
    )
    Start-Sleep -Milliseconds 750
    $process.Refresh()
    if ($process.HasExited) {
        throw 'FAIL routed helper exited before its activation window'
    }

    Write-Output 'PASS routed helper remained alive'
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
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
