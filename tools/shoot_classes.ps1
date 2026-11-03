$ErrorActionPreference = 'Continue'
$root = (Get-Location).Path
$godot = Join-Path $root "emberfall\tools\godot\Godot_v4.7.2-stable_win64.exe"
$env:APPDATA = Join-Path $root ".godot_appdata"
$env:LOCALAPPDATA = Join-Path $root ".godot_localappdata"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CapFleet {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Shoot([string]$name, [string[]]$extra) {
    Get-Process -Name "Godot*" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $launch = @("--path", (Join-Path $root "emberfall\game"))
    if ($extra.Count -gt 0) { $launch += "--"; $launch += $extra }
    Start-Process -FilePath $godot -ArgumentList $launch
    Start-Sleep -Seconds 10
    $proc = Get-Process -Name "Godot_v4.7.2-stable_win64" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($null -eq $proc) { "no window for $name"; return }
    $r = New-Object CapFleet+RECT
    [CapFleet]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $dir = Join-Path $root ("emberfall\out\fleet_" + $name)
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    for ($i = 0; $i -lt 3; $i++) {
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        [CapFleet]::PrintWindow($proc.MainWindowHandle, $hdc, 2) | Out-Null
        $g.ReleaseHdc($hdc); $g.Dispose()
        $bmp.Save((Join-Path $dir ("frame_{0:D3}.png" -f $i)), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Start-Sleep -Milliseconds 900
    }
    "shot $name"
}

Shoot "cruiser" @("--hull=0")
Shoot "battleship" @("--hull=1")
Shoot "carrier" @("--hull=2")
Shoot "mix" @("--hull=0", "--mix")
Get-Process -Name "Godot*" -ErrorAction SilentlyContinue | Stop-Process -Force
