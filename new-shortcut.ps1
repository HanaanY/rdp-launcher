# Creates a Desktop shortcut for the launcher (no console window, Remote Desktop icon).
#   new-shortcut.ps1                     # opens the monitor picker
#   new-shortcut.ps1 -Preset "Home desk" # connects straight away with that preset
param([string]$Preset)

$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'rdp-launcher.ps1'
$name = if ($Preset) { "RDP - $Preset" } else { 'Remote Desktop (pick monitors)' }
$path = Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk"

$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" + $(if ($Preset) { " -Preset `"$Preset`"" })
$lnk.WorkingDirectory = Split-Path -Parent $script
$lnk.IconLocation = "$env:SystemRoot\System32\mstsc.exe,0"
$lnk.Save()
"Created $path"
