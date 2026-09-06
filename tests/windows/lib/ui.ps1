# The click surfaces: the on-screen banner and the Notification Center copy.
#
# Why not UI Automation for the content. On this Windows 11 build (26200) the
# toast banner is a top-level `Windows.UI.Core.CoreWindow` titled "New
# notification", owned by ShellExperienceHost -- but it is invisible to a
# normal client: EnumWindows does not return it, it is not a child of the UIA
# root element, and AutomationElement.FromHandle on its HWND yields an element
# with an Empty bounding rectangle and zero descendants (README.md has the
# probe output). So there is no Invoke pattern to call and no element rect to
# read. What the shell does expose is the window itself: FindWindow locates
# it, and DWM's extended frame bounds report where it is painted -- zero
# height while parked, the banner's rectangle while a banner is up.
#
# The click is therefore synthetic mouse input at that rectangle's centre,
# with the pointer restored afterwards. That is weaker than an Invoke -- it
# needs the pixels to actually be there and it moves the user's pointer for a
# moment -- but it exercises exactly what a user does, and the assertion that
# decides PASS/FAIL is still a log line, not a click that "looked" fine.

Set-StrictMode -Version Latest

if (-not ('Snn.Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace Snn {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static class Win {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT val, int size);
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
  }
}
'@
}

# Every coordinate this file handles is a physical pixel: DWM's extended
# frame bounds, the cursor, WindowFromPoint, the screenshot crop. A stock
# pwsh is DPI-unaware, so at any scaling other than 100% the system scales
# those same numbers on the way in and the click lands off the card (a 125%
# display put the panel's own centre off-screen). Making this thread
# per-monitor aware (V2) puts every API on the physical grid for the rest of
# the run; run.ps1 and harness.ps1 run on this thread too.
$script:DpiContextPrev = [Snn.Win]::SetThreadDpiAwarenessContext([IntPtr]-4)

function Get-SystemDpi {
    # Every coordinate below is a physical pixel (DWM frame bounds), while
    # SetCursorPos and CopyFromScreen see virtualized ones in a DPI-unaware
    # pwsh. At 96 DPI (100% scaling) the two spaces coincide; anywhere else
    # the click lands off the banner. run.ps1 reports this before firing.
    # Read through a per-monitor-aware thread context: for an unaware thread
    # GetDpiForSystem is documented to answer 96 whatever the display is set
    # to, which would make this check blind to the one case it exists for.
    try {
        $prev = [Snn.Win]::SetThreadDpiAwarenessContext([IntPtr]-4)   # PER_MONITOR_AWARE_V2
        try { return [int][Snn.Win]::GetDpiForSystem() }
        finally { [Snn.Win]::SetThreadDpiAwarenessContext($prev) | Out-Null }
    } catch { return 0 }
}

$script:BannerTitle = 'New notification'
$script:CentreTitle = 'Notification Center'
# The two geometry tunables, in pixels at 96 DPI (100% scaling); Scale-Px
# turns them into the display's physical pixels at run time.
# A banner is "up" once the DWM bounds of the parked window grow past this.
$script:BannerMinHeight = 40
# Where the newest card's title/body block sits below the panel's top edge:
# clears the "Notifications" header and the app-group row. The one number to
# retune if a Windows build moves the list; run.ps1 -FirstCardOffsetY
# overrides it per run (in physical pixels, unscaled). Named apart from that
# parameter on purpose: run.ps1 dot-sources this file into its own scope,
# where a same-named assignment would overwrite the value the user passed.
$script:DefaultFirstCardOffsetY = 165

function Scale-Px {
    # A 96-DPI measurement as physical pixels on this display (165 -> 206 at
    # 125%). Measured: at 125% the unscaled 165 still activated the card but
    # sat on its top edge; the scaled value lands where 165 does at 100%.
    param([Parameter(Mandatory)][int]$At96)
    $dpi = Get-SystemDpi
    if ($dpi -le 0) { $dpi = 96 }
    return [int][math]::Round($At96 * $dpi / 96)
}

function Get-ForegroundOwner {
    <#  .SYNOPSIS "<process> | <title>" of the foreground window right now. #>
    $h = [Snn.Win]::GetForegroundWindow()
    $procId = [uint32]0
    [void][Snn.Win]::GetWindowThreadProcessId($h, [ref]$procId)
    $name = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '?' }
    $sb = [Text.StringBuilder]::new(256)
    [void][Snn.Win]::GetWindowText($h, $sb, 256)
    return "$name | $($sb.ToString())"
}

function Wait-SteamForeground {
    <#
      .SYNOPSIS The moment Steam's main window holds the foreground, or $null.

      Measured on this client: a toast click hands the foreground to the
      forwarding steam.exe and then to the client's "Steam" window (owned by
      steamwebhelper) within about 200 ms, and restores it from minimized.
    #>
    param([double]$TimeoutSec = 3)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $owner = Get-ForegroundOwner
        if ($owner -cmatch '^(steamwebhelper|steam) \| Steam$') { return $owner }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-ShellWindowRect {
    <#
      .SYNOPSIS Where a shell CoreWindow is painted right now, or $null.

      DWM's extended frame bounds, not GetWindowRect: the banner's window rect
      stays pinned to the taskbar edge with zero height whether or not a
      banner is up, while the DWM bounds grow to the banner when one paints.
    #>
    param([Parameter(Mandatory)][string]$Title)
    $h = [Snn.Win]::FindWindow('Windows.UI.Core.CoreWindow', $Title)
    if ($h -eq [IntPtr]::Zero) { return $null }
    $r = New-Object Snn.RECT
    if ([Snn.Win]::DwmGetWindowAttribute($h, [Snn.Win]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$r, 16) -ne 0) { return $null }
    [pscustomobject]@{
        Handle = $h
        Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom
        Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top
        CentreX = [int](($r.Left + $r.Right) / 2); CentreY = [int](($r.Top + $r.Bottom) / 2)
    }
}

function Wait-ToastBanner {
    <#
      .SYNOPSIS Wait for a banner to paint; returns its rectangle or $null.

      A banner is up when the "New notification" window has a non-zero DWM
      height. Windows keeps banners on screen about five seconds, so a caller
      that wants to click one has that long from this returning.
    #>
    param([double]$TimeoutSec = 12, [int]$MinHeight = (Scale-Px $script:BannerMinHeight))
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $r = Get-ShellWindowRect -Title $script:BannerTitle
        if ($r -and $r.Height -ge $MinHeight) { return $r }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-ClickAt {
    <#
      .SYNOPSIS One left click at a screen point, pointer put back afterwards.
    #>
    param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [int]$SettleMs = 120)
    $saved = New-Object Snn.POINT
    [void][Snn.Win]::GetCursorPos([ref]$saved)
    [void][Snn.Win]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds $SettleMs
    [Snn.Win]::mouse_event([Snn.Win]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [Snn.Win]::mouse_event([Snn.Win]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $SettleMs
    [void][Snn.Win]::SetCursorPos($saved.X, $saved.Y)
}

function Test-PointOwnedBy {
    <#
      .SYNOPSIS Is the topmost window at this point the named shell window?

      The open/closed state of the Notification Center is not readable from
      the window: it is never destroyed and DWM reports it cloaked either way.
      Hit-testing a point inside the panel is: while it is closed something
      else answers there.
    #>
    param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [Parameter(Mandatory)][string]$Title)
    $p = New-Object Snn.POINT; $p.X = $X; $p.Y = $Y
    $hit = [Snn.Win]::WindowFromPoint($p)
    $want = [Snn.Win]::FindWindow('Windows.UI.Core.CoreWindow', $Title)
    return ($hit -ne [IntPtr]::Zero -and $hit -eq $want)
}

function Send-WinKey {
    <#  .SYNOPSIS Tap Win + <letter>. #>
    param([Parameter(Mandatory)][char]$Letter)
    $vk = [byte][char]([string]$Letter).ToUpper()
    [Snn.Win]::keybd_event(0x5B, 0, 0, [IntPtr]::Zero)
    [Snn.Win]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
    [Snn.Win]::keybd_event($vk, 0, [Snn.Win]::KEYEVENTF_KEYUP, [IntPtr]::Zero)
    [Snn.Win]::keybd_event(0x5B, 0, [Snn.Win]::KEYEVENTF_KEYUP, [IntPtr]::Zero)
}

function Test-NotificationCentreOpen {
    param($Rect)
    if (-not $Rect) { return $false }
    return (Test-PointOwnedBy -X $Rect.CentreX -Y ($Rect.Top + 200) -Title $script:CentreTitle)
}

function Test-NotificationCentreShowing {
    <#  .SYNOPSIS Is the panel on screen right now? #>
    return (Test-NotificationCentreOpen (Get-ShellWindowRect -Title $script:CentreTitle))
}

function Open-NotificationCentre {
    <#
      .SYNOPSIS Open the Notification Center (Win+N) and confirm it is open.
      .OUTPUTS  Its rectangle, or $null if it did not open.
    #>
    param([double]$TimeoutSec = 5)
    $rect = Get-ShellWindowRect -Title $script:CentreTitle
    if (-not $rect) { return $null }
    # Win+N toggles: sending it to a panel that is already open closes it.
    if (-not (Test-NotificationCentreOpen $rect)) { Send-WinKey -Letter 'n' }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (Test-NotificationCentreOpen $rect) { return $rect }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Close-NotificationCentre {
    $rect = Get-ShellWindowRect -Title $script:CentreTitle
    if (-not $rect) { return }
    if (Test-NotificationCentreOpen $rect) {
        Send-WinKey -Letter 'n'
        Start-Sleep -Milliseconds 600
    }
}

function Get-NotificationCentreCardPoint {
    <#
      .SYNOPSIS Where the newest notification card sits in the open panel.

      The panel's content is as opaque to UI Automation as the banner is, so
      the card is addressed by geometry: newest first, at the top of the list.
      Clicking the app-group row above the card only collapses the group
      (a 90px offset did exactly that: no activation, an honest FAIL); the
      default (Scale-Px $script:DefaultFirstCardOffsetY) lands on the title/body block, which
      is what activates. A wrong number shows up as a failed click assertion,
      never a false pass.
    #>
    param([Parameter(Mandatory)]$Rect, [int]$FirstCardOffsetY = (Scale-Px $script:DefaultFirstCardOffsetY))
    [pscustomobject]@{ X = $Rect.CentreX; Y = $Rect.Top + $FirstCardOffsetY }
}
