# RDP Launcher

Pick which of your monitors Remote Desktop uses, by **which screen it is**, not by a number
that changes every time you plug something in.

## The problem

Windows Remote Desktop (`mstsc`) can span a subset of your monitors via the
`selectedmonitors:s:2,1,0` line in an `.rdp` file. Those numbers are the IDs shown by
`mstsc /l`, and they reshuffle whenever monitors are plugged in, unplugged, or a dock is
reconnected, so a saved profile quietly starts using the wrong screens.

## What this does

- Identifies each monitor by its EDID model and serial number (e.g. `DELL U2417H`), and
  recognises the laptop's built-in screen.
- Saves **presets** as a list of physical monitors, e.g. "laptop + portable screen".
- At connect time it works out the current `mstsc` IDs and launches Remote Desktop with a
  generated `.rdp` file.
- Small window: tick monitors or pick a preset, choose which screen gets the remote taskbar,
  click Connect. It updates by itself when monitors are plugged in or unplugged.

Built-in options: **All monitors** and **Laptop screen only**.

## Setup

1. In Remote Desktop, set up your connection the way you like it (address, redirected
   drives, etc.), then **Show Options → Save As** and save it as `template.rdp` in this folder.
   Its monitor settings don't matter; the launcher sets those.
2. Run `new-shortcut.ps1` from this folder. It's a helper script that puts a
   **Remote Desktop (pick monitors)** shortcut on your Desktop. The shortcut runs
   `rdp-launcher.ps1` with the console window hidden and uses the Remote Desktop icon.

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\new-shortcut.ps1
   ```

3. Double-click the new Desktop shortcut, tick the screens you want, **Save as preset…**,
   then **Connect**.

Optionally, give a preset its own one-click Desktop shortcut. It connects straight away,
and opens the picker instead if one of the preset's monitors isn't connected:

```powershell
powershell -ExecutionPolicy Bypass -File .\new-shortcut.ps1 -Preset "Home desk"
```

## Command line

```powershell
.\rdp-launcher.ps1                     # picker window
.\rdp-launcher.ps1 -Preset "Home desk" # connect directly
.\rdp-launcher.ps1 -List               # show monitors and their current mstsc IDs
.\rdp-launcher.ps1 -List -UseMstsc     # same, but read IDs from the `mstsc /l` dialog
```

## How the IDs are worked out

Microsoft doesn't document how `mstsc` numbers monitors. Empirically it numbers them in
Windows' own display order (`EnumDisplayDevices`), and the launcher relies on that, so it's
instant and doesn't need to open the `mstsc /l` dialog.

`test-mstsc-order.ps1` checks this on your machine: leave it running, plug and unplug
monitors or your dock, and it logs whether the prediction matched `mstsc /l` for each layout.
If it ever doesn't match, add `-UseMstsc` to your shortcut. The launcher then reads the
dialog instead, via UI Automation, so it flashes briefly.

## Requirements

Windows 10/11 with the built-in Windows PowerShell 5.1. No admin rights, no modules.

## Files

| File | |
|---|---|
| `rdp-launcher.ps1` | the launcher |
| `new-shortcut.ps1` | creates Desktop shortcuts |
| `test-mstsc-order.ps1` | verifies the monitor-numbering assumption |
| `template.rdp` | *yours, git-ignored*: your saved connection |
| `presets.json` | *yours, git-ignored*: created when you save a preset |
