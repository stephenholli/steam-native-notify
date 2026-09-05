# Windows Live Toast Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Foreground Steam when a routed Windows toast is clicked from its live banner.

**Architecture:** Keep steam:// as the routing transport. Hold routed toast
objects in the existing hidden PowerShell sender and attach an in-memory .NET
event sink that calls WScript.Shell.AppActivate for Steam's visible
steamwebhelper process.

**Tech Stack:** Windows PowerShell 5.1, WinRT toast APIs, in-memory C#, WSH
WScript.Shell, existing Lua and TypeScript bridge

**Spec:** docs/superpowers/specs/2026-09-05-windows-live-toast-focus.md

## Global Constraints

- Keep steam://snn/replay/<toast> as the only Windows click route
- Do not register a COM activator or ship a binary
- Treat focus as best-effort; delivery and routing must survive every failure
- Limit the sender lifetime to activation, dismissal, failure, or 120 seconds
- Leave Notification Center foregrounding out of scope
- Do not change non-Windows behavior

---

### Task 1: Windows helper lifetime and focus callback

**Files:**
- Create: tools/test-windows-notify-action.ps1
- Modify: tools/notify-action.ps1

**Interfaces:**
- Consumes: a routed <id>.notify payload and the existing AUMID
- Produces: unchanged protocol XML plus a live Activated focus callback

- [ ] **Step 1: Write the failing lifetime test**

Create a PowerShell test that copies the real helper to a temporary runtime,
writes a routed payload, starts the helper hidden, and fails if the process
exits within 750 milliseconds.

    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
        '-Id', $id
    )
    Start-Sleep -Milliseconds 750
    $process.Refresh()
    if ($process.HasExited) {
        throw 'FAIL routed helper exited before its activation window'
    }
    Stop-Process -Id $process.Id -Force
    Write-Output 'PASS routed helper remained alive'

- [ ] **Step 2: Verify the test fails**

Run in the active Windows desktop session:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\ty\test-windows-notify-action.ps1

Expected: FAIL routed helper exited before its activation window.

- [ ] **Step 3: Implement the event sink**

Add an in-memory C# sink to tools/notify-action.ps1 that:

- attaches to the reflected WinRT Activated, Dismissed, and Failed events
- enumerates visible top-level windows for steamwebhelper with title Steam
- calls WScript.Shell.AppActivate with that process ID
- signals a wait handle after any terminal toast event
- catches and logs all focus failures

Attach the sink only when Route is a valid replay route. Preserve the
protocol launch attribute and wait no longer than 120 seconds.

The sink exposes this exact PowerShell-facing contract:

    public static class SnnToastFocus {
        public static string Result { get; private set; }
        public static void Reset();
        public static void OnActivated(object sender, object arguments);
        public static void OnDismissed(object sender, object arguments);
        public static void OnFailed(object sender, object arguments);
        public static bool Wait(int milliseconds);
    }

Bind each reflected WinRT event to its matching static method:

    $eventTokens = @()
    foreach ($binding in @(
        @('Activated', 'OnActivated'),
        @('Dismissed', 'OnDismissed'),
        @('Failed', 'OnFailed')
    )) {
        $event = $toast.GetType().GetEvent($binding[0])
        $method = [SnnToastFocus].GetMethod($binding[1])
        $handler = [Delegate]::CreateDelegate($event.EventHandlerType, $method)
        $token = $toast.GetType().GetMethod("add_$($binding[0])").Invoke($toast, @($handler))
        $eventTokens += ,@($binding[0], $handler, $token)
    }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid).Show($toast)
    $null = [SnnToastFocus]::Wait(120000)

On activation, enumerate top-level windows with EnumWindows, choose the visible
window whose process is steamwebhelper and title is Steam, then invoke
WScript.Shell.AppActivate through reflection with that process ID. Store
activated, target-missing, focus-failed, dismissed, failed, or timeout in
SnnToastFocus.Result; no callback may throw.

- [ ] **Step 4: Verify the lifetime test passes**

Run the same Windows command. Expected: PASS routed helper remained alive.

- [ ] **Step 5: Run the offline validation gate**

    bun run typecheck
    bun run build
    bun run test

### Task 2: Document and install the behavior

**Files:**
- Modify: backend/main.lua
- Modify: docs/platforms.md
- Modify: docs/architecture.md

**Interfaces:**
- Consumes: the helper behavior from Task 1
- Produces: accurate process-lifetime and Windows click-limit documentation

- [ ] **Step 1: Update lifecycle comments and platform documentation**

Document that routed Windows helpers remain alive for the live activation
window, live banners foreground Steam, and Notification Center clicks remain
navigation-only.

- [ ] **Step 2: Re-run the offline validation gate**

    bun run typecheck
    bun run build
    bun run test

- [ ] **Step 3: Install and restart Windows Steam**

Copy the built .star into the VM, restart Steam fully, and confirm the running
helper matches the build.

- [ ] **Step 4: Verify a live achievement click**

Fire TestAchievement 570, click the live native banner, and confirm:

- Steam reaches the foreground
- steam-url: replay:<toast> appears
- replay: invoke <toast> returns without throwing

- [ ] **Step 5: Verify the documented history limitation**

Click a routed toast from Notification Center and confirm navigation still
runs while Notification Center retains foreground.
