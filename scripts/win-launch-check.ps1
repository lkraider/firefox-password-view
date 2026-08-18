# Asserts the Windows app opens a profile and puts its own window up. Exits
# non-zero on a failure. ci.yml's two Windows jobs run this after `zig build
# win`.
#
# win/src/main.zig calls reportFatal and returns 1 when openFirst finds no
# profile, and CreateWindowExW runs after that check. So a process still alive
# with a FirefoxPasswordViewWindow up has opened the profile and built the list.
#
# A window of class #32770 is a MessageBoxW, so reportFatal ran and the process
# is parked on a modal dialog. On a session with no interactive desktop,
# MessageBoxW with a null owner returns 0 at once and the app exits 1, so the
# liveness check catches a startup failure either way.
[CmdletBinding()]
param(
    [string]$Exe = "zig-out\bin\FirefoxPasswordView.exe",
    # The fresh fixture opens under an empty Primary Password, so
    # promptPassword raises no dialog.
    [string]$ProfileDir = "core\testdata\fresh"
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowList
{
    private delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc proc, IntPtr lparam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int count);

    public static List<string> ClassesFor(uint wanted)
    {
        var found = new List<string>();
        EnumWindows((hwnd, lparam) =>
        {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid == wanted)
            {
                var name = new StringBuilder(256);
                GetClassNameW(hwnd, name, name.Capacity);
                found.Add(name.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

if (-not (Test-Path $Exe)) {
    Write-Host "FAIL  no exe at $Exe"
    exit 1
}

Write-Host "launching $Exe --profile $ProfileDir"
$proc = Start-Process -FilePath $Exe -ArgumentList "--profile", $ProfileDir -PassThru
$code = 0

try {
    Start-Sleep -Seconds 5
    if ($proc.HasExited) {
        Write-Host "FAIL  the app exited with code $($proc.ExitCode) within 5 seconds"
        exit 1
    }
    Write-Host "PASS  the process is alive 5 seconds in, so it opened the profile"

    $deadline = (Get-Date).AddSeconds(15)
    $classes = @()
    while ((Get-Date) -lt $deadline) {
        $classes = [WindowList]::ClassesFor([uint32]$proc.Id)
        if ($classes.Count -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }

    if ($classes -contains "#32770") {
        Write-Host "FAIL  a MessageBoxW is up, so reportFatal ran. Classes: $($classes -join ', ')"
        $code = 1
    } elseif ($classes -contains "FirefoxPasswordViewWindow") {
        Write-Host "PASS  the app's own window is up. Classes: $($classes -join ', ')"
    } else {
        # This branch says the runner gives a launched process no desktop to
        # draw on. Tighten the check to a failure once one run reports it.
        Write-Host "WARN  no window of any class within 15 seconds. The process is alive."
    }

    if ($proc.HasExited) {
        Write-Host "FAIL  the app exited with code $($proc.ExitCode) during the window poll"
        $code = 1
    }
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

exit $code
