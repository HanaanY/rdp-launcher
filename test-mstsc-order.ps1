# Watches for monitor changes and checks that mstsc's monitor IDs (what `mstsc /l` shows)
# can be predicted without opening that dialog. The launcher's rule: a monitor's ID is its
# position in EnumDisplayDevices' full output list, inactive outputs included.
# Run it, plug/unplug/disable monitors (and wireless displays), Ctrl+C or wait for -Minutes.
param([double]$Minutes = 15)

$ErrorActionPreference = 'Stop'
$Log = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'test-mstsc-order.log'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type @"
using System; using System.Runtime.InteropServices;
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
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint f);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
}
"@

function Get-Predicted {
    # attached outputs as "ID@x,y", ID = index in the full list (inactive outputs counted)
    for ($a = 0; ; $a++) {
        $ad = New-Object D+DISPLAY_DEVICE; $ad.cb = [Runtime.InteropServices.Marshal]::SizeOf($ad)
        if (-not [D]::EnumDisplayDevices([NullString]::Value, $a, [ref]$ad, 0)) { break }
        if (($ad.StateFlags -band 1) -eq 0) { continue }
        $dm = New-Object D+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
        if ([D]::EnumDisplaySettings($ad.DeviceName, -1, [ref]$dm)) {
            [pscustomobject]@{ Id = "$a@$($dm.dmPositionX),$($dm.dmPositionY)"; Dev = $ad.DeviceName
                               Size = "$($dm.dmPelsWidth)x$($dm.dmPelsHeight)"; What = $ad.DeviceString }
        }
    }
}

function Get-MstscIds {
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
    [regex]::Matches($text, '(\d+):\s*\d+\s*x\s*\d+;\s*\((-?\d+),\s*(-?\d+)') | % { "$($_.Groups[1].Value)@$($_.Groups[2].Value),$($_.Groups[3].Value)" }
}

function Write-Log($s) { $line = "[$(Get-Date -Format HH:mm:ss)] $s"; Write-Host $line; Add-Content $Log $line }

Write-Log "=== watching for $Minutes min ==="
$end = (Get-Date).AddMinutes($Minutes)
$last = ''; $tests = 0; $fails = 0
while ((Get-Date) -lt $end) {
    $sig = (@(Get-Predicted) | % { "$($_.Dev)=$($_.Id)" }) -join ' '
    if ($sig -ne $last) {
        Start-Sleep -Seconds 3   # let Windows finish rearranging
        $pred = @(Get-Predicted); $sig = ($pred | % { "$($_.Dev)=$($_.Id)" }) -join ' '
        $mstsc = @(Get-MstscIds | Sort-Object)
        $guess = @($pred | % Id | Sort-Object)
        $ok = ($guess -join ' ') -eq ($mstsc -join ' ')
        $tests++; if (-not $ok) { $fails++ }
        Write-Log ("{0} monitor(s): {1}" -f $pred.Count, (($pred | % { "$($_.Dev -replace '\\\\\.\\','') $($_.Size) ($($_.What))" }) -join ', '))
        Write-Log "  mstsc /l  : $($mstsc -join ' | ')"
        Write-Log ("  predicted : {0}  {1}" -f ($guess -join ' | '), $(if ($ok) { 'MATCH' } else { 'MISMATCH' }))
        $last = $sig
    }
    Start-Sleep -Seconds 2
}
Write-Log "=== done: $tests layouts tested; mismatches: $fails ==="
