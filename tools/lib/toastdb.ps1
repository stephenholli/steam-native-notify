# The toast oracle: what Windows itself recorded, read out of the notification
# platform's own database. Dot-sourced by tools/capture.ps1 (the newest toast
# in section 3) and by the live harness (tests/windows/run.ps1).
#
# Every toast the platform accepts is stored in
# %LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db -- the row
# carries the exact XML that tools/notify-action.ps1 handed to
# ToastNotificationManager, so asserting on it proves delivery reached
# Windows, not merely that the helper exited 0.
#
# Two things this file works around:
#   * The live DB is held open by WpnUserService. It is copied first, and the
#     -wal and -shm files must travel with it or the newest rows (the toast
#     just fired) are missing from the copy.
#   * There is no SQLite provider in a stock PowerShell. Windows ships
#     winsqlite3.dll in System32 for its own components; this binds the entry
#     points a read needs, so there is no pip/nuget dependency.
#
# Pure ASCII, no PowerShell-7-only syntax (tools/lib/snn.ps1 says why).

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'snn.ps1')

if (-not ('Snn.Sqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Snn {
  public static class Sqlite {
    [DllImport("winsqlite3.dll", CharSet = CharSet.Unicode)]
    public static extern int sqlite3_open16(string filename, out IntPtr db);
    [DllImport("winsqlite3.dll", CharSet = CharSet.Unicode)]
    public static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int nByte, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll")] public static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll")] public static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll")] public static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll")] public static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("winsqlite3.dll")] public static extern IntPtr sqlite3_column_text16(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll")] public static extern IntPtr sqlite3_column_blob(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll")] public static extern int sqlite3_column_bytes(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr sqlite3_errmsg16(IntPtr db);

    // Text where the value is text, raw bytes where it is a BLOB. The
    // Payload column is a BLOB whose bytes the notification platform writes
    // as UTF-16LE; letting SQLite coerce it through column_text16 fails
    // outright (the leading NUL is not a legal XML name character), so the
    // bytes are decoded here, sniffing UTF-16 vs UTF-8 from the second byte.
    public static string ColumnText(IntPtr stmt, int col) {
      IntPtr p = sqlite3_column_text16(stmt, col);
      return p == IntPtr.Zero ? null : Marshal.PtrToStringUni(p);
    }
    public static string ColumnTextBlob(IntPtr stmt, int col) {
      IntPtr p = sqlite3_column_blob(stmt, col);
      int n = sqlite3_column_bytes(stmt, col);
      if (p == IntPtr.Zero || n <= 0) { return null; }
      byte[] buf = new byte[n];
      Marshal.Copy(p, buf, 0, n);
      if (n >= 2 && buf[0] == 0xFF && buf[1] == 0xFE) {
        return System.Text.Encoding.Unicode.GetString(buf, 2, n - 2);
      }
      if (n >= 2 && buf[1] == 0x00) { return System.Text.Encoding.Unicode.GetString(buf); }
      return System.Text.Encoding.UTF8.GetString(buf);
    }
  }
}
'@
}

function Copy-WpnDatabase {
    <#
      .SYNOPSIS Snapshot the live notification DB (with its WAL) into a temp copy.
      .OUTPUTS  The copy's path; pass it as -DbPath to read the same snapshot again.
    #>
    # The copy lives in %TEMP%, not in the repo: it is a snapshot of the
    # user's whole notification history, every app included, and nothing in
    # the repo should collect that.
    param([string]$Destination = (Join-Path $env:TEMP 'snn-wpn-copy.db'))
    $src = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications\wpndatabase.db'
    if (-not (Test-Path -LiteralPath $src)) { throw "no notification database at $src" }
    foreach ($ext in @('', '-wal', '-shm')) {
        $from = "$src$ext"; $to = "$Destination$ext"
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination $to -Force
        } elseif (Test-Path -LiteralPath $to) {
            # A stale WAL from a previous run would be replayed over fresh
            # data and resurrect rows that are no longer there.
            Remove-Item -LiteralPath $to -Force
        }
    }
    return $Destination
}

function Invoke-SqliteQuery {
    # Rows come back as c0..cN in select order (column names are not exposed
    # by this binding); -BlobColumns names the indexes to read as raw bytes.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sql,
          [int[]]$BlobColumns = @())
    $db = [IntPtr]::Zero; $stmt = [IntPtr]::Zero
    if ([Snn.Sqlite]::sqlite3_open16($Path, [ref]$db) -ne 0) { throw "cannot open $Path" }
    try {
        if ([Snn.Sqlite]::sqlite3_prepare16_v2($db, $Sql, -1, [ref]$stmt, [IntPtr]::Zero) -ne 0) {
            throw "sqlite prepare failed: $([System.Runtime.InteropServices.Marshal]::PtrToStringUni([Snn.Sqlite]::sqlite3_errmsg16($db)))"
        }
        $count = [Snn.Sqlite]::sqlite3_column_count($stmt)
        $rows = New-Object System.Collections.Generic.List[object]
        while ([Snn.Sqlite]::sqlite3_step($stmt) -eq 100) {
            $row = @{}
            for ($i = 0; $i -lt $count; $i++) {
                $row["c$i"] = if ($BlobColumns -contains $i) { [Snn.Sqlite]::ColumnTextBlob($stmt, $i) }
                              else { [Snn.Sqlite]::ColumnText($stmt, $i) }
            }
            $rows.Add([pscustomobject]$row)
        }
        return $rows
    } finally {
        if ($stmt -ne [IntPtr]::Zero) { [void][Snn.Sqlite]::sqlite3_finalize($stmt) }
        if ($db -ne [IntPtr]::Zero) { [void][Snn.Sqlite]::sqlite3_close($db) }
    }
}

function Get-NotificationRows {
    # The one projection both public readers share: Id, Aumid, ArrivedUtc, Xml.
    # Toasts only: the table also holds tile and badge updates and this
    # AUMID's own payload-less toastCondensed rows, none of which is a card.
    param([string]$Where = '', [string]$OrderBy = 'n.ArrivalTime desc, n.Id desc', [int]$Limit = 10, [string]$DbPath)
    if (-not $DbPath) { $DbPath = Copy-WpnDatabase }
    $sql = "select n.Id, h.PrimaryId, n.ArrivalTime, n.Payload from Notification n join NotificationHandler h on n.HandlerId = h.RecordId where n.Type = 'toast'"
    if ($Where) { $sql += " and ($Where)" }
    $sql += " order by $OrderBy limit $Limit"
    Invoke-SqliteQuery -Path $DbPath -Sql $sql -BlobColumns @(3) | ForEach-Object {
        [pscustomobject]@{
            Id         = [int64]$_.c0
            Aumid      = $_.c1
            # ArrivalTime is a Windows FILETIME: 100ns ticks since 1601-01-01 UTC.
            ArrivedUtc = [datetime]::FromFileTimeUtc([int64]$_.c2)
            Xml        = $_.c3
        }
    }
}

function Get-ToastRows {
    <#
      .SYNOPSIS Rows this AUMID delivered, newest first; -Since keeps only
                rows that arrived after a UTC mark (filtered in SQL).
      .OUTPUTS  Id, Aumid, ArrivedUtc, Xml
    #>
    param([string]$Aumid = $SnnAumid, [int]$Limit = 10, [datetime]$Since, [string]$DbPath)
    $where = "h.PrimaryId = '$($Aumid -replace "'", "''")'"
    if ($PSBoundParameters.ContainsKey('Since')) { $where += " and n.ArrivalTime > $($Since.ToFileTimeUtc())" }
    Get-NotificationRows -Where $where -Limit $Limit -DbPath $DbPath
}

function Get-NewestNotificationRow {
    <#
      .SYNOPSIS The newest row in the database, whatever app delivered it:
                what the Notification Center shows at the top of its list.
    #>
    param([string]$DbPath)
    Get-NotificationRows -Limit 1 -DbPath $DbPath
}

function Get-ToastFacts {
    <#
      .SYNOPSIS Pull the assertable slots out of one toast's XML.

      The shape is the one tools/notify-action.ps1 builds: two <text> nodes
      (title then body), an optional appLogoOverride <image>, and the launch
      attribute that carries steam://snn/replay/<toast-name>.
    #>
    param([Parameter(Mandatory)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $toast = $doc.DocumentElement
    $texts = @($toast.SelectNodes('visual/binding/text') | ForEach-Object { $_.InnerText })
    $image = $toast.SelectSingleNode('visual/binding/image')
    [pscustomobject]@{
        Title          = if ($texts.Count -ge 1) { $texts[0] } else { $null }
        Body           = if ($texts.Count -ge 2) { $texts[1] } else { $null }
        ImageSrc       = if ($image) { $image.GetAttribute('src') } else { '' }
        ImageCrop      = if ($image) { $image.GetAttribute('hint-crop') } else { '' }
        Launch         = $toast.GetAttribute('launch')
        ActivationType = $toast.GetAttribute('activationType')
        Xml            = $Xml
    }
}
