#!/usr/bin/env pwsh
# Talk to Millennium's external protocol from the shell.
#
# MEP is a unix socket any local process can speak: 4-byte little-endian length
# prefix, msgpack body, one response per request. It is how the click bridge
# reaches into the running plugin, and it is useful on its own for poking at a
# live Steam without a devtools session.
#
# Usage:
#   tools/mep.ps1 <method> [key=value ...]   params are strings unless they parse as JSON
#   tools/mep.ps1 --methods                  the ones this tool knows are useful
#
# Examples:
#   tools/mep.ps1 millennium.version
#   tools/mep.ps1 plugin.list
#   tools/mep.ps1 plugin.status name=me.tysmith.steam-native-notify
#   tools/mep.ps1 plugin.config.set name=me.tysmith.steam-native-notify key=devMode value=true
#   tools/mep.ps1 plugin.config.get_all name=me.tysmith.steam-native-notify
#
# Windows twin of tools/mep; same CLI, same JSON on stdout, same exit codes:
# 0 on success, 1 when the reply carries an error and 1 when the tool itself
# gives up (a bad key=value, a socket that is not there), matching the twin's
# SystemExit. Deliberate divergences:
#   - the socket is %TEMP%\millennium-mep.sock, not /tmp (Millennium:
#     src/include/mep/mep_server.h). Override it with -Socket.
#   - Python on Windows has no AF_UNIX, so this rides .NET's
#     UnixDomainSocketEndPoint and needs PowerShell 7 (pwsh), never the
#     built-in Windows PowerShell 5.1. That guard exits 1 like every other
#     failure; it has no twin.
#   - msgpack is hand-rolled below: the request/response subset only.
#   - pure ASCII, no PowerShell-7-only syntax, so Windows PowerShell 5.1 gets
#     the one-line refusal instead of a parse error (tools/lib/snn.ps1).

[CmdletBinding()]
param(
    # Position 0 plus ValueFromRemainingArguments: without the explicit
    # position PowerShell hands the first bare token to $Socket instead.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Argv,
    [string] $Socket = (Join-Path $env:TEMP 'millennium-mep.sock'),
    [double] $Timeout = 5.0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\snn.ps1')
Assert-Pwsh7 -Tool 'mep.ps1' -Because 'Windows PowerShell 5.1 has no UnixDomainSocketEndPoint.'
Set-Utf8Console

$UsefulMethods = @(
    'millennium.version', 'millennium.status',
    'plugin.list', 'plugin.get', 'plugin.status',
    'plugin.enable', 'plugin.disable', 'plugin.restart',
    'plugin.config.get', 'plugin.config.set',
    'plugin.config.delete', 'plugin.config.get_all'
)

# PowerShell's binder never sees --methods or --help as parameters, so every
# token arrives in $Argv and the dispatch is done by hand, as in the twin.
$argv = @($Argv | Where-Object { $null -ne $_ -and $_ -ne '' })
if ($argv.Count -lt 1 -or $argv[0] -in @('-h', '--help')) { Show-HeaderUsage -Path $PSCommandPath; exit 0 }
if ($argv[0] -eq '--methods') { $UsefulMethods | ForEach-Object { "  $_" }; exit 0 }
$Method = $argv[0]
$Params = @($argv | Select-Object -Skip 1)

# --- msgpack: the subset a request/response needs ---------------------------

function Write-BE {
    # msgpack is big-endian; .NET on x64 is not.
    param([System.IO.BinaryWriter] $W, [byte[]] $Bytes)
    [Array]::Reverse($Bytes); $W.Write($Bytes)
}

function Write-Len {
    # The length prefix every variable-size type shares: a fix-format byte
    # when the count fits, else the 8-, 16- or 32-bit opcode and a big-endian
    # count. -Op8 is 0 for the types that have no 8-bit form (map, array).
    param([System.IO.BinaryWriter] $W, [long] $Len, [byte] $FixBase, [int] $FixMax, [byte] $Op8, [byte] $Op16, [byte] $Op32)
    if ($Len -le $FixMax) { $W.Write([byte]($FixBase -bor $Len)) }
    elseif ($Op8 -and $Len -le 255) { $W.Write($Op8); $W.Write([byte]$Len) }
    elseif ($Len -le 65535) { $W.Write($Op16); Write-BE $W ([BitConverter]::GetBytes([uint16]$Len)) }
    else { $W.Write($Op32); Write-BE $W ([BitConverter]::GetBytes([uint32]$Len)) }
}

function Pack-MsgPack {
    param($Value, [System.IO.BinaryWriter] $W)
    if ($null -eq $Value) { $W.Write([byte]0xC0); return }
    if ($Value -is [bool]) { $W.Write([byte]($(if ($Value) { 0xC3 } else { 0xC2 }))); return }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32]) {
        $n = [long]$Value
        if ($n -ge 0 -and $n -le 127) { $W.Write([byte]$n); return }
        if ($n -lt 0 -and $n -ge -32) { $W.Write([byte](256 + $n)); return }
        $W.Write([byte]0xD3); Write-BE $W ([BitConverter]::GetBytes($n)); return
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $W.Write([byte]0xCB); Write-BE $W ([BitConverter]::GetBytes([double]$Value)); return
    }
    if ($Value -is [string]) {
        $b = [Text.Encoding]::UTF8.GetBytes($Value)
        Write-Len $W $b.Length 0xA0 31 0xD9 0xDA 0xDB
        $W.Write($b); return
    }
    # Dictionaries and lists before PSCustomObject: ConvertFrom-Json's
    # -AsHashtable output arrives wrapped in a PSObject, which
    # -is [PSCustomObject] also matches, and packing it by property would
    # emit its Keys/Count members with nil values.
    if ($Value -is [System.Collections.IDictionary]) {
        Write-Len $W $Value.Count 0x80 15 0 0xDE 0xDF
        foreach ($k in $Value.Keys) { Pack-MsgPack ([string]$k) $W; Pack-MsgPack $Value[$k] $W }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        Write-Len $W $items.Count 0x90 15 0 0xDC 0xDD
        foreach ($i in $items) { Pack-MsgPack $i $W }
        return
    }
    # A PSCustomObject is a map whose keys are its properties.
    if ($Value -is [PSCustomObject]) {
        $m = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $m[$p.Name] = $p.Value }
        Pack-MsgPack $m $W
        return
    }
    Pack-MsgPack ([string]$Value) $W
}

function Read-BE {
    param([System.IO.BinaryReader] $R, [int] $Count)
    $b = $R.ReadBytes($Count); [Array]::Reverse($b); return $b
}

function Unpack-MsgPack {
    param([System.IO.BinaryReader] $R)
    $t = $R.ReadByte()
    if ($t -le 0x7F) { return [int]$t }
    if ($t -ge 0xE0) { return [int]($t - 256) }
    if (($t -band 0xE0) -eq 0xA0) { return [Text.Encoding]::UTF8.GetString($R.ReadBytes($t -band 0x1F)) }
    if (($t -band 0xF0) -eq 0x90) { return ,(Unpack-Array $R ($t -band 0x0F)) }
    if (($t -band 0xF0) -eq 0x80) { return Unpack-Map $R ($t -band 0x0F) }
    switch ($t) {
        0xC0 { return $null }
        0xC2 { return $false }
        0xC3 { return $true }
        0xC4 { return $R.ReadBytes($R.ReadByte()) }
        0xC5 { return $R.ReadBytes([BitConverter]::ToUInt16((Read-BE $R 2), 0)) }
        0xC6 { return $R.ReadBytes([BitConverter]::ToUInt32((Read-BE $R 4), 0)) }
        0xCA { return [BitConverter]::ToSingle((Read-BE $R 4), 0) }
        0xCB { return [BitConverter]::ToDouble((Read-BE $R 8), 0) }
        0xCC { return [int]$R.ReadByte() }
        0xCD { return [int][BitConverter]::ToUInt16((Read-BE $R 2), 0) }
        0xCE { return [long][BitConverter]::ToUInt32((Read-BE $R 4), 0) }
        0xCF { return [BitConverter]::ToUInt64((Read-BE $R 8), 0) }
        0xD0 { return [int]$R.ReadSByte() }
        0xD1 { return [int][BitConverter]::ToInt16((Read-BE $R 2), 0) }
        0xD2 { return [BitConverter]::ToInt32((Read-BE $R 4), 0) }
        0xD3 { return [BitConverter]::ToInt64((Read-BE $R 8), 0) }
        0xD9 { return [Text.Encoding]::UTF8.GetString($R.ReadBytes($R.ReadByte())) }
        0xDA { return [Text.Encoding]::UTF8.GetString($R.ReadBytes([BitConverter]::ToUInt16((Read-BE $R 2), 0))) }
        0xDB { return [Text.Encoding]::UTF8.GetString($R.ReadBytes([BitConverter]::ToUInt32((Read-BE $R 4), 0))) }
        0xDC { return ,(Unpack-Array $R ([BitConverter]::ToUInt16((Read-BE $R 2), 0))) }
        0xDD { return ,(Unpack-Array $R ([BitConverter]::ToUInt32((Read-BE $R 4), 0))) }
        0xDE { return Unpack-Map $R ([BitConverter]::ToUInt16((Read-BE $R 2), 0)) }
        0xDF { return Unpack-Map $R ([BitConverter]::ToUInt32((Read-BE $R 4), 0)) }
        default { throw "msgpack: unsupported type byte 0x$('{0:X2}' -f $t)" }
    }
}

function Unpack-Array {
    param($R, [long] $N)
    $a = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $N; $i++) { [void]$a.Add((Unpack-MsgPack $R)) }
    # -NoEnumerate: `return @()` writes nothing to the pipeline, so an empty
    # msgpack array used to come back as $null and serialise as null instead
    # of []. The unary comma at each call site then unwraps this one object.
    Write-Output -NoEnumerate ([object[]]$a.ToArray())
}
function Unpack-Map { param($R, [long] $N); $m = [ordered]@{}; for ($i = 0; $i -lt $N; $i++) { $k = Unpack-MsgPack $R; $m[[string]$k] = Unpack-MsgPack $R }; return $m }

# --- request -----------------------------------------------------------------

function ConvertFrom-ParamToken {
    param([string] $Token)
    if ($Token -notmatch '=') { throw "parameters look like key=value, got: $Token" }
    $key, $raw = $Token -split '=', 2
    # ConvertFrom-Json returns nothing for '[]'; tools/mep sends an empty list.
    try { $v = $raw | ConvertFrom-Json -AsHashtable -Depth 32 } catch { return $key, $raw }
    if ($null -eq $v -and $raw.Trim() -eq '[]') { $v = @() }
    return $key, $v
}

function Invoke-Mep {
    param([string] $Method, [hashtable] $Params, [string] $Socket, [double] $Timeout)
    if (-not (Test-Path -LiteralPath $Socket)) { throw "$Socket is not there -- is Steam running with Millennium?" }
    $sock = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::Unix, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Unspecified)
    $sock.ReceiveTimeout = [int]($Timeout * 1000); $sock.SendTimeout = [int]($Timeout * 1000)
    try { $sock.Connect([System.Net.Sockets.UnixDomainSocketEndPoint]::new($Socket)) }
    catch { throw "$Socket refused the connection -- Millennium may be starting up. ($($_.Exception.Message))" }
    try {
        $req = [ordered]@{ id = 'mep-cli'; method = $Method }
        if ($Params -and $Params.Count) { $req['params'] = $Params }
        $ms = [System.IO.MemoryStream]::new(); $w = [System.IO.BinaryWriter]::new($ms)
        Pack-MsgPack $req $w; $w.Flush()
        $body = $ms.ToArray()
        $frame = [BitConverter]::GetBytes([uint32]$body.Length) + $body
        [void]$sock.Send($frame)

        $hdr = [byte[]]::new(4); $got = 0
        while ($got -lt 4) { $n = $sock.Receive($hdr, $got, 4 - $got, 'None'); if ($n -le 0) { throw 'short response header -- the connection dropped' }; $got += $n }
        $len = [BitConverter]::ToUInt32($hdr, 0)
        $buf = [byte[]]::new($len); $got = 0
        while ($got -lt $len) { $n = $sock.Receive($buf, $got, $len - $got, 'None'); if ($n -le 0) { throw 'connection closed mid-frame' }; $got += $n }
        $r = [System.IO.BinaryReader]::new([System.IO.MemoryStream]::new($buf))
        return Unpack-MsgPack $r
    } finally { $sock.Close() }
}

$p = @{}
try {
    foreach ($tok in $Params) { if ($tok) { $k, $v = ConvertFrom-ParamToken $tok; $p[$k] = $v } }
    $reply = Invoke-Mep -Method $Method -Params $p -Socket $Socket -Timeout $Timeout
} catch {
    # A raw PowerShell trace here would bury the one sentence that matters.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
ConvertTo-Json -InputObject $reply -Depth 32
# Same contract as tools/mep: a reply carrying an error exits non-zero, so
# scripts can branch without parsing the JSON.
if ($reply -is [System.Collections.IDictionary] -and $reply['error']) { exit 1 }
exit 0
