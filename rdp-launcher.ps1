<#
  RDP Launcher - pick which *physical* monitors Remote Desktop should use.

  mstsc's "selectedmonitors" IDs (what `mstsc /l` shows) change whenever monitors are
  plugged/unplugged/rearranged. This script stores presets by monitor identity
  (EDID model + serial) and works out the current mstsc IDs at connect time.

  Usage:
    rdp-launcher.ps1                    # GUI: tick monitors / choose preset, Connect
    rdp-launcher.ps1 -Preset "Home desk"   # connect straight away if all its monitors are present
    rdp-launcher.ps1 -List              # print current monitors + mstsc IDs
    add -UseMstsc to any of the above to read IDs from the `mstsc /l` dialog instead of
    predicting them (fallback if the remote session ever uses the wrong screens)
#>
param(
    [string]$Preset,
    [switch]$List,
    [switch]$UseMstsc
)

$ErrorActionPreference = 'Stop'
$Here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $Here 'template.rdp'
$PresetsPath  = Join-Path $Here 'presets.json'
$OutRdp       = Join-Path $env:TEMP 'rdp-launcher.rdp'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes, Microsoft.VisualBasic

if (-not $List -and -not (Test-Path $TemplatePath)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "No template.rdp found next to the script.`n`n" +
        "In Remote Desktop, set up your connection, then Show Options > Save As and save it as:`n`n" +
        "$TemplatePath`n`n" +
        "Its monitor settings don't matter - the launcher fills those in.",
        'RDP Launcher - setup needed', 'OK', 'Information')
    return
}

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class DisplayApi {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
}
"@

# ---------------------------------------------------------------- monitor discovery

function Get-MstscMonitors {
    # Opens `mstsc /l` and reads its dialog via UI Automation (no clipboard/SendKeys).
    $p = Start-Process mstsc.exe -ArgumentList '/l' -PassThru
    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
        $text = $null
        for ($i = 0; $i -lt 60 -and -not $text; $i++) {
            Start-Sleep -Milliseconds 100
            $win = $root.FindFirst('Children', $cond)
            if ($win) {
                $text = ($win.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition) |
                    ForEach-Object { $_.Current.Name } | Where-Object { $_ -match '^\s*\d+:' }) -join "`n"
            }
        }
    } finally {
        if (-not $p.HasExited) { $p | Stop-Process -Force }
    }
    if (-not $text) { throw "Couldn't read monitor list from 'mstsc /l'." }
    [regex]::Matches($text, '(\d+):\s*(\d+)\s*x\s*(\d+);\s*\((-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\)') | ForEach-Object {
        $g = $_.Groups
        [pscustomobject]@{ Id = [int]$g[1].Value; Width = [int]$g[2].Value; Height = [int]$g[3].Value
                           X = [int]$g[4].Value; Y = [int]$g[5].Value }
    }
}

function Get-PhysicalMonitors {
    # Windows display outputs with physical-pixel position + EDID identity.
    $wmiIds  = @{}; $wmiTech = @{}
    try {
        Get-CimInstance -Namespace root\wmi WmiMonitorID | ForEach-Object {
            $key = ($_.InstanceName -replace '_\d+$', '').ToUpper()
            $wmiIds[$key] = [pscustomobject]@{
                Name   = (-join ($_.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ })).Trim()
                Serial = (-join ($_.SerialNumberID   | Where-Object { $_ } | ForEach-Object { [char]$_ })).Trim()
            }
        }
        Get-CimInstance -Namespace root\wmi WmiMonitorConnectionParams | ForEach-Object {
            $wmiTech[($_.InstanceName -replace '_\d+$', '').ToUpper()] = [uint32]$_.VideoOutputTechnology
        }
    } catch { }

    $result = @()
    for ($a = 0; ; $a++) {
        $ad = New-Object DisplayApi+DISPLAY_DEVICE; $ad.cb = [Runtime.InteropServices.Marshal]::SizeOf($ad)
        if (-not [DisplayApi]::EnumDisplayDevices([NullString]::Value, $a, [ref]$ad, 0)) { break }
        if (($ad.StateFlags -band 1) -eq 0) { continue }   # not attached to desktop
        if (($ad.StateFlags -band 8) -ne 0) { continue }   # mirroring driver, not a real screen
        $dm = New-Object DisplayApi+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [DisplayApi]::EnumDisplaySettings($ad.DeviceName, -1, [ref]$dm)) { continue }
        $md = New-Object DisplayApi+DISPLAY_DEVICE; $md.cb = [Runtime.InteropServices.Marshal]::SizeOf($md)
        [void][DisplayApi]::EnumDisplayDevices($ad.DeviceName, 0, [ref]$md, 1)  # EDD_GET_DEVICE_INTERFACE_NAME

        # \\?\DISPLAY#DEL40E7#5&260b9ff&0&UID262#{guid}  ->  DISPLAY\DEL40E7\5&260B9FF&0&UID262
        $inst = ''; $code = ''
        if ($md.DeviceID -match '^\\\\\?\\(.+?)#\{') { $inst = ($Matches[1] -replace '#', '\').ToUpper() }
        if ($inst -match '^DISPLAY\\([^\\]+)') { $code = $Matches[1] }
        $info = $wmiIds[$inst]
        $internal = $wmiTech[$inst] -eq [uint32]2147483648   # D3DKMDT_VOT_INTERNAL
        $name = if ($internal) { 'Laptop screen' } elseif ($info -and $info.Name) { $info.Name } else { $code }
        $serial = if ($info) { $info.Serial } else { '' }

        $result += [pscustomobject]@{
            Key = "$code|$serial"; Name = $name; Code = $code; Internal = $internal
            Index = $a   # position in the full output list, inactive outputs included
            X = $dm.dmPositionX; Y = $dm.dmPositionY; Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight
            Primary = ($ad.StateFlags -band 4) -ne 0
        }
    }
    $result
}

function Get-DisplaySignature {
    # Cheap fingerprint of the current layout, used to notice plug/unplug/rearrange.
    $s = for ($a = 0; ; $a++) {
        $ad = New-Object DisplayApi+DISPLAY_DEVICE; $ad.cb = [Runtime.InteropServices.Marshal]::SizeOf($ad)
        if (-not [DisplayApi]::EnumDisplayDevices([NullString]::Value, $a, [ref]$ad, 0)) { break }
        if (($ad.StateFlags -band 1) -eq 0) { continue }
        $dm = New-Object DisplayApi+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
        [void][DisplayApi]::EnumDisplaySettings($ad.DeviceName, -1, [ref]$dm)
        "$($ad.DeviceName)@$($dm.dmPositionX),$($dm.dmPositionY),$($dm.dmPelsWidth)x$($dm.dmPelsHeight),$($ad.StateFlags)"
    }
    $s -join ';'
}

function Get-Monitors {
    $phys  = @(Get-PhysicalMonitors)
    if ($UseMstsc) {
        # Fallback: ask mstsc itself (pops up the `mstsc /l` dialog briefly).
        $mstsc = @(Get-MstscMonitors)
    } else {
        # mstsc's ID is the output's position in EnumDisplayDevices' full list, counting
        # inactive outputs too. A wireless (Miracast) TV listed after four unused GPU outputs
        # is ID 5, not 1. Verified with test-mstsc-order.ps1, including dock replugs.
        $mstsc = @($phys | ForEach-Object { [pscustomobject]@{ Id = $_.Index; X = $_.X; Y = $_.Y; Width = $_.Width; Height = $_.Height } })
    }
    $primary = $phys | Where-Object Primary | Select-Object -First 1
    foreach ($m in $mstsc) {
        $p = $phys | Where-Object { $_.X -eq $m.X -and $_.Y -eq $m.Y } | Select-Object -First 1
        if (-not $p) { $p = [pscustomobject]@{ Key = "unknown@$($m.X),$($m.Y)"; Name = 'Unknown display'; Primary = $false; Internal = $false } }
        $where = ''
        if ($primary -and -not $p.Primary) {
            $dx = ($m.X + $m.Width / 2) - ($primary.X + $primary.Width / 2)
            $dy = ($m.Y + $m.Height / 2) - ($primary.Y + $primary.Height / 2)
            $where = if ([math]::Abs($dx) -ge [math]::Abs($dy)) { if ($dx -lt 0) { 'left' } else { 'right' } } else { if ($dy -lt 0) { 'above' } else { 'below' } }
        }
        [pscustomobject]@{
            Id = $m.Id; Key = $p.Key; Name = $p.Name; Primary = $p.Primary; Internal = $p.Internal
            Width = $m.Width; Height = $m.Height; Where = $where
            Label = ('{0}  -  {1}x{2}{3}' -f $p.Name, $m.Width, $m.Height,
                     $(if ($p.Primary) { ', main Windows display' } elseif ($where) { ", $where" } else { '' }))
        }
    }
}

# ---------------------------------------------------------------- presets

function Get-Presets {
    $list = [System.Collections.ArrayList]@()
    if (Test-Path $PresetsPath) {
        $raw = Get-Content $PresetsPath -Raw | ConvertFrom-Json
        foreach ($p in @($raw)) {
            [void]$list.Add([pscustomobject]@{ Name = $p.Name; Monitors = @($p.Monitors | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Name = $_.Name } }) })
        }
    }
    , $list
}

function Save-Presets($list) {
    ConvertTo-Json -InputObject @($list) -Depth 5 | Set-Content $PresetsPath -Encoding UTF8
}

function Resolve-Preset($preset, $monitors) {
    # Returns mstsc IDs (in preset order) plus any monitors that aren't connected.
    $ids = @(); $missing = @()
    foreach ($pm in $preset.Monitors) {
        $m = $monitors | Where-Object Key -eq $pm.Key | Select-Object -First 1
        if ($m) { $ids += $m.Id } else { $missing += $pm.Name }
    }
    [pscustomobject]@{ Ids = $ids; Missing = $missing }
}

# ---------------------------------------------------------------- connect

function Start-Rdp([int[]]$ids) {
    if (-not $ids.Count) { throw 'No monitors selected.' }
    # Any saved .rdp works as a template: drop its monitor lines and set our own.
    $lines = @(Get-Content $TemplatePath | Where-Object { $_ -notmatch '^(selectedmonitors|use multimon):' })
    $lines += 'use multimon:i:1', "selectedmonitors:s:$($ids -join ',')"
    Set-Content -Path $OutRdp -Value $lines -Encoding Unicode
    Start-Process mstsc.exe -ArgumentList "`"$OutRdp`""
}

# ---------------------------------------------------------------- entry points

$monitors = @(Get-Monitors)

if ($List) {
    $monitors | Format-Table Id, Name, Width, Height, Where, Primary, Key -AutoSize
    return
}

if ($Preset) {
    $p = (Get-Presets) | Where-Object Name -eq $Preset | Select-Object -First 1
    if ($p) {
        $r = Resolve-Preset $p $monitors
        if (-not $r.Missing.Count) { Start-Rdp $r.Ids; return }
    }
    # missing monitors / unknown preset -> fall through to GUI with it preselected
}

# ---------------------------------------------------------------- GUI

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Remote Desktop - choose monitors'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoSize = $true; $form.AutoSizeMode = 'GrowAndShrink'
$form.Padding = New-Object System.Windows.Forms.Padding(10)

# Everything sits in an auto-sizing table so it scales with the text (display scaling).
$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.AutoSize = $true; $tbl.AutoSizeMode = 'GrowAndShrink'; $tbl.ColumnCount = 2
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$form.Controls.Add($tbl)

function Add-Row($left, $right) {
    # one control spanning both columns, or a label + control pair
    $row = $tbl.RowCount; $tbl.RowCount++
    [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    $tbl.Controls.Add($left, 0, $row)
    if ($right) { $tbl.Controls.Add($right, 1, $row) } else { $tbl.SetColumnSpan($left, 2) }
}
function New-Label($text) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $true
    $l.Anchor = 'Left'; $l.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3); $l
}
function New-Button($text) {
    $b = New-Object System.Windows.Forms.Button; $b.Text = $text; $b.AutoSize = $true
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 2); $b
}
function New-Combo {
    $c = New-Object System.Windows.Forms.ComboBox; $c.DropDownStyle = 'DropDownList'; $c.Dock = 'Fill'; $c
}

$cboPreset = New-Combo
Add-Row (New-Label 'Preset:') $cboPreset

Add-Row (New-Label 'Monitors to use (currently connected):')
$lst = New-Object System.Windows.Forms.CheckedListBox; $lst.CheckOnClick = $true; $lst.Dock = 'Fill'
function Set-ListWidth {
    $longest = ($monitors | ForEach-Object { [System.Windows.Forms.TextRenderer]::MeasureText($_.Label, $form.Font).Width } | Measure-Object -Maximum).Maximum
    $lst.MinimumSize = New-Object System.Drawing.Size(([math]::Max($longest + 60, $form.Font.Height * 28)), ($form.Font.Height * 7))
}
Set-ListWidth
Add-Row $lst

$cboMain = New-Combo
Add-Row (New-Label 'Main screen in remote session:') $cboMain

$lblWarn = New-Label ''; $lblWarn.ForeColor = [System.Drawing.Color]::DarkRed
$lblWarn.MaximumSize = New-Object System.Drawing.Size($lst.MinimumSize.Width, 0)   # wrap instead of widening the window
Add-Row $lblWarn

$btnSave    = New-Button 'Save as preset...'
$btnDelete  = New-Button 'Delete preset'
$btnConnect = New-Button 'Connect'; $btnConnect.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
$btns = New-Object System.Windows.Forms.FlowLayoutPanel; $btns.AutoSize = $true; $btns.Dock = 'Fill'; $btns.WrapContents = $false
$btns.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$btns.Controls.AddRange(@($btnSave, $btnDelete))
$right = New-Object System.Windows.Forms.FlowLayoutPanel; $right.AutoSize = $true; $right.Anchor = 'Right'; $right.Controls.Add($btnConnect)
$btnRow = New-Object System.Windows.Forms.TableLayoutPanel; $btnRow.AutoSize = $true; $btnRow.Dock = 'Fill'; $btnRow.ColumnCount = 2
[void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$btnRow.Controls.Add($btns, 0, 0); $btnRow.Controls.Add($right, 1, 0)
Add-Row $btnRow
$form.AcceptButton = $btnConnect

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($cboMain, 'Gets the taskbar / start menu in the remote session')

$script:presets = Get-Presets
$script:loading = $false

function Fill-Monitors {
    $lst.Items.Clear()
    foreach ($m in $monitors) { [void]$lst.Items.Add($m.Label) }
}

function Get-Checked { @($lst.CheckedIndices | ForEach-Object { $monitors[$_] }) }

function Fill-Main($preferKey) {
    $sel = @(Get-Checked)
    $cboMain.Items.Clear()
    foreach ($m in $sel) { [void]$cboMain.Items.Add($m.Label) }
    if (-not $sel.Count) { return }
    $idx = 0
    $pick = if ($preferKey) { $preferKey } else { ($sel | Where-Object Primary | Select-Object -First 1).Key }
    for ($i = 0; $i -lt $sel.Count; $i++) { if ($sel[$i].Key -eq $pick) { $idx = $i } }
    $cboMain.SelectedIndex = $idx
}

function Fill-Presets($selectName) {
    $script:loading = $true
    $cboPreset.Items.Clear()
    [void]$cboPreset.Items.Add('(custom)')
    [void]$cboPreset.Items.Add('All monitors')
    [void]$cboPreset.Items.Add('Laptop screen only')
    foreach ($p in $script:presets) { [void]$cboPreset.Items.Add($p.Name) }
    $i = $cboPreset.Items.IndexOf($selectName)
    $cboPreset.SelectedIndex = [math]::Max(0, $i)
    $script:loading = $false
    Apply-Preset
}

function Apply-Preset {
    if ($script:loading) { return }
    $name = [string]$cboPreset.SelectedItem
    $lblWarn.Text = ''
    $btnDelete.Enabled = $cboPreset.SelectedIndex -ge 3
    if ($name -eq '(custom)') { return }
    $script:loading = $true
    for ($i = 0; $i -lt $monitors.Count; $i++) { $lst.SetItemChecked($i, $false) }
    $mainKey = $null
    switch ($name) {
        'All monitors'       { for ($i = 0; $i -lt $monitors.Count; $i++) { $lst.SetItemChecked($i, $true) } }
        'Laptop screen only' { for ($i = 0; $i -lt $monitors.Count; $i++) { if ($monitors[$i].Internal) { $lst.SetItemChecked($i, $true) } } }
        default {
            $p = $script:presets | Where-Object Name -eq $name | Select-Object -First 1
            $missing = @()
            foreach ($pm in $p.Monitors) {
                $i = [array]::FindIndex([object[]]$monitors, [Predicate[object]] { param($m) $m.Key -eq $pm.Key })
                if ($i -ge 0) { $lst.SetItemChecked($i, $true) } else { $missing += $pm.Name }
            }
            if ($p.Monitors.Count) { $mainKey = $p.Monitors[0].Key }
            if ($missing.Count) { $lblWarn.Text = "Not connected right now: $($missing -join ', ')" }
        }
    }
    $script:loading = $false
    Fill-Main $mainKey
}

function Get-OrderedSelection {
    # main screen first, then the rest in mstsc order
    $sel = @(Get-Checked)
    if (-not $sel.Count) { return @() }
    $main = $sel[[math]::Max(0, $cboMain.SelectedIndex)]
    @($main) + @($sel | Where-Object { $_.Key -ne $main.Key })
}

$cboPreset.add_SelectedIndexChanged({ Apply-Preset })
$lst.add_ItemCheck({
    if ($script:loading) { return }
    # ItemCheck fires before the state changes; refresh afterwards
    $form.BeginInvoke([Action] { Fill-Main $null; $script:loading = $true; $cboPreset.SelectedIndex = 0; $script:loading = $false; $btnDelete.Enabled = $false; $lblWarn.Text = '' }) | Out-Null
})

$btnSave.add_Click({
    $sel = @(Get-OrderedSelection)
    if (-not $sel.Count) { $lblWarn.Text = 'Tick at least one monitor first.'; return }
    $default = ($sel | ForEach-Object { $_.Name }) -join ' + '
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Preset name:', 'Save preset', $default)
    if (-not $name.Trim()) { return }
    $name = $name.Trim()
    $existing = $script:presets | Where-Object Name -eq $name | Select-Object -First 1
    if ($existing) { [void]$script:presets.Remove($existing) }
    [void]$script:presets.Add([pscustomobject]@{ Name = $name; Monitors = @($sel | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Name = $_.Name } }) })
    Save-Presets $script:presets
    Fill-Presets $name
})

$btnDelete.add_Click({
    $name = [string]$cboPreset.SelectedItem
    $p = $script:presets | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $p) { return }
    if ([System.Windows.Forms.MessageBox]::Show("Delete preset '$name'?", 'Delete preset', 'YesNo') -ne 'Yes') { return }
    [void]$script:presets.Remove($p)
    Save-Presets $script:presets
    Fill-Presets '(custom)'
})

function Update-Monitors {
    # Re-detect monitors, keeping the current preset / ticks where those screens still exist.
    $keepPreset = [string]$cboPreset.SelectedItem
    $keepKeys = @(Get-OrderedSelection | ForEach-Object { $_.Key })
    $script:appliedSig = Get-DisplaySignature
    $script:monitors = @(Get-Monitors)
    Set-ListWidth
    Fill-Monitors
    if ($keepPreset -ne '(custom)') { Fill-Presets $keepPreset; return }
    $script:loading = $true
    for ($i = 0; $i -lt $monitors.Count; $i++) { $lst.SetItemChecked($i, $keepKeys -contains $monitors[$i].Key) }
    $script:loading = $false
    Fill-Main $(if ($keepKeys.Count) { $keepKeys[0] })
}

# Watch for plug/unplug/rearrange: poll the cheap layout fingerprint and refresh once it
# has stopped changing for a moment (a dock replug fires several changes in a row).
$script:appliedSig = Get-DisplaySignature
$script:seenSig = $script:appliedSig; $script:seenAt = Get-Date
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 500
$timer.add_Tick({
    $sig = Get-DisplaySignature
    if ($sig -ne $script:seenSig) { $script:seenSig = $sig; $script:seenAt = Get-Date; return }
    if ($sig -ne $script:appliedSig -and ((Get-Date) - $script:seenAt).TotalMilliseconds -ge 1500) { Update-Monitors }
})
$form.add_FormClosed({ $timer.Stop() })

$btnConnect.add_Click({
    if ((Get-DisplaySignature) -ne $script:appliedSig) {
        # layout changed in the last second or two - don't connect with stale IDs
        Update-Monitors
        $lblWarn.Text = 'Monitors just changed - check the ticks and click Connect again.'
        return
    }
    $sel = @(Get-OrderedSelection)
    if (-not $sel.Count) { $lblWarn.Text = 'Tick at least one monitor.'; return }
    Start-Rdp ([int[]]($sel | ForEach-Object { $_.Id }))
    $form.Close()
})

Fill-Monitors
Fill-Presets $(if ($Preset) { $Preset } else { 'All monitors' })
$timer.Start()
[void]$form.ShowDialog()
