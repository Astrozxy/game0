# 启动 EMBERFALL
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root "tools\godot\Godot_v4.7.2-stable_win64.exe"
$game = Join-Path $root "game"

if (-not (Test-Path $exe)) {
    Write-Host "找不到 Godot 引擎：$exe" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# Godot 默认往用户目录写东西；这里指到工程目录，避免权限问题
$env:APPDATA = Join-Path $root ".godot_appdata"
$env:LOCALAPPDATA = Join-Path $root ".godot_localappdata"
New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null

Start-Process -FilePath $exe -ArgumentList @("--path", $game)
