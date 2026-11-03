param(
    [string]$OutName = "frames20",
    [string[]]$ExtraArgs = @(),
    [int]$Frames = 4,
    [int]$WaitSec = 12
)
$ErrorActionPreference = 'Continue'
$root = (Get-Location).Path
$frameDir = Join-Path $root ("emberfall\out\" + $OutName)
if (Test-Path $frameDir) { Remove-Item $frameDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $frameDir | Out-Null
Get-Process -Name "Godot*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

$godot = Join-Path $root "emberfall\tools\godot\Godot_v4.7.2-stable_win64.exe"
$env:APPDATA = Join-Path $root ".godot_appdata"
$env:LOCALAPPDATA = Join-Path $root ".godot_localappdata"
$launchArgs = @("--path", (Join-Path $root "emberfall\game"))
if ($ExtraArgs.Count -gt 0) { $launchArgs += "--"; $launchArgs += $ExtraArgs }
Start-Process -FilePath $godot -ArgumentList $launchArgs
Start-Sleep -Seconds $WaitSec

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CapShot {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$p = Get-Process -Name "Godot_v4.7.2-stable_win64" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$r = New-Object CapShot+RECT
[CapShot]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
for ($f = 0; $f -lt $Frames; $f++) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [CapShot]::PrintWindow($p.MainWindowHandle, $hdc, 2) | Out-Null
  $g.ReleaseHdc($hdc); $g.Dispose()
  $bmp.Save((Join-Path $frameDir ("frame_{0:D3}.png" -f $f)), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Start-Sleep -Milliseconds 900
}
Get-Process -Name "Godot*" -ErrorAction SilentlyContinue | Stop-Process -Force
"captured $OutName ($($w)x$($h))"
