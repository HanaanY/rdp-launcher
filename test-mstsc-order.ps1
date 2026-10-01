# Watches for monitor changes and checks whether mstsc's monitor IDs can be predicted
# from Windows' own display order (so the launcher could skip the `mstsc /l` dialog).
# Run it, plug/unplug/disable monitors, Ctrl+C (or wait for -Minutes) to stop.
param([double]$Minutes = 15)

$ErrorActionPreference = 'Stop'
$Log = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'test-mstsc-order.log'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class D {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE { public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct MONITORINFOEX { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string szDevice; }
  public delegate bool MonProc(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint f);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonProc cb, IntPtr d);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX mi);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
  public static List<string> MonitorOrder() {
    SetThreadDpiAwarenessContext(new IntPtr(-4));   // per-monitor v2 => physical pixels
    var r = new List<string>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr hdc, ref RECT rc, IntPtr d) => {
      var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(mi); GetMonitorInfo(h, ref mi);
      r.Add(string.Format("{0},{1}", mi.rcMonitor.L, mi.rcMonitor.T)); return true; }, IntPtr.Zero);
    return r;
  }
}
"@

function Get-DeviceOrder {
    # Theory A: order of attached outputs from EnumDisplayDevices (\\.\DISPLAY1, 2, ...)
    $out = @()
    for ($a = 0; ; $a++) {
        $ad = New-Object D+DISPLAY_DEVICE; $ad.cb = [Runtime.InteropServices.Marshal]::SizeOf($ad)
        if (-not [D]::EnumDisplayDevices([NullString]::Value, $a, [ref]$ad, 0)) { break }
        if (($ad.StateFlags -band 1) -eq 0) { continue }
        $dm = New-Object D+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
        if ([D]::EnumDisplaySettings($ad.DeviceName, -1, [ref]$dm)) {
            $out += [pscustomobject]@{ Pos = "$($dm.dmPositionX),$($dm.dmPositionY)"; Dev = $ad.DeviceName; Size = "$($dm.dmPelsWidth)x$($dm.dmPelsHeight)" }
        }
    }
    $out
}

function Get-MstscOrder {
    $p = Start-Process mstsc.exe -ArgumentList '/l' -PassThru
    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
        $text = $null
        for ($i = 0; $i -lt 60 -and -not $text; $i++) {
            Start-Sleep -Milliseconds 100
            $win = $root.FindFirst('Children', $cond)
            if ($win) { $text = ($win.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition) | % { $_.Current.Name } | ? { $_ -match '^\s*\d+:' }) -join "`n" }
        }
    } finally { if (-not $p.HasExited) { $p | Stop-Process -Force } }
    [regex]::Matches($text, '(\d+):\s*\d+\s*x\s*\d+;\s*\((-?\d+),\s*(-?\d+)') | % { "$($_.Groups[2].Value),$($_.Groups[3].Value)" }
}

function Write-Log($s) { $line = "[$(Get-Date -Format HH:mm:ss)] $s"; Write-Host $line; Add-Content $Log $line }

Write-Log "=== watching for $Minutes min ==="
$end = (Get-Date).AddMinutes($Minutes)
$last = ''; $tests = 0; $failsA = 0; $failsB = 0
while ((Get-Date) -lt $end) {
    $dev = @(Get-DeviceOrder)
    $sig = ($dev | % { "$($_.Dev)@$($_.Pos)" }) -join ' '
    if ($sig -ne $last) {
        Start-Sleep -Seconds 3   # let Windows finish rearranging
        $dev = @(Get-DeviceOrder); $sig = ($dev | % { "$($_.Dev)@$($_.Pos)" }) -join ' '
        $mstsc = @(Get-MstscOrder)
        $a = @($dev | % Pos); $b = @([D]::MonitorOrder())
        $okA = ($a -join ' ') -eq ($mstsc -join ' '); $okB = ($b -join ' ') -eq ($mstsc -join ' ')
        $tests++; if (-not $okA) { $failsA++ }; if (-not $okB) { $failsB++ }
        Write-Log ("{0} monitor(s): {1}" -f $dev.Count, (($dev | % { "$($_.Dev -replace '\\\\\.\\','') $($_.Size)" }) -join ', '))
        Write-Log "  mstsc /l          : $($mstsc -join ' | ')"
        Write-Log ("  A display order   : {0}  {1}" -f ($a -join ' | '), $(if ($okA) { 'MATCH' } else { 'MISMATCH' }))
        Write-Log ("  B monitor enum    : {0}  {1}" -f ($b -join ' | '), $(if ($okB) { 'MATCH' } else { 'MISMATCH' }))
        $last = $sig
    }
    Start-Sleep -Seconds 2
}
Write-Log "=== done: $tests layouts tested; A mismatches: $failsA; B mismatches: $failsB ==="
