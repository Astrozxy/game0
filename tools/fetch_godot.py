"""
下载并解压 Godot 引擎（走 Python 的 OpenSSL，绕开 Windows Schannel 凭证问题）。

用法：
    python tools/fetch_godot.py
    python tools/fetch_godot.py --version 4.7.2-stable

为什么不用 curl / Invoke-WebRequest：
    沙箱进程的访问令牌受限，Schannel 无法取得 TLS 凭证，
    报 SEC_E_NO_CREDENTIALS。Python 的 ssl 模块用 OpenSSL，不受此限制。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools", "godot")
UA = {"User-Agent": "emberfall-setup/1.0"}


def latest_version() -> str:
    req = urllib.request.Request(
        "https://api.github.com/repos/godotengine/godot/releases/latest",
        headers={**UA, "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["tag_name"]


def download(url: str, dest: str, retries: int = 3) -> None:
    tmp = dest + ".part"
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                total = int(r.headers.get("Content-Length", 0))
                done = 0
                start = time.time()
                with open(tmp, "wb") as f:
                    while True:
                        chunk = r.read(1024 * 256)
                        if not chunk:
                            break
                        f.write(chunk)
                        done += len(chunk)
                        if total:
                            pct = done * 100 / total
                            spd = done / max(0.001, time.time() - start) / 1024 / 1024
                            sys.stdout.write(f"\r  下载中 {pct:5.1f}%  {done/1024/1024:6.1f}/{total/1024/1024:.1f} MB  {spd:5.1f} MB/s")
                            sys.stdout.flush()
            sys.stdout.write("\n")
            os.replace(tmp, dest)
            return
        except Exception as e:
            sys.stdout.write(f"\n  第 {attempt} 次失败：{type(e).__name__}: {e}\n")
            if os.path.exists(tmp):
                os.remove(tmp)
            if attempt == retries:
                raise
            time.sleep(2 * attempt)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="")
    args = ap.parse_args()

    os.makedirs(TOOLS, exist_ok=True)

    version = args.version or latest_version()
    print(f"Godot 版本：{version}")

    zip_name = f"Godot_v{version}_win64.exe.zip"
    url = f"https://github.com/godotengine/godot/releases/download/{version}/{zip_name}"
    zip_path = os.path.join(TOOLS, zip_name)

    if os.path.exists(zip_path):
        print(f"已存在，跳过下载：{zip_path}")
    else:
        print(f"下载：{url}")
        download(url, zip_path)
        print(f"完成：{zip_path} ({os.path.getsize(zip_path)/1024/1024:.1f} MB)")

    print("解压……")
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        z.extractall(TOOLS)
    exes = [n for n in names if n.lower().endswith(".exe")]
    print(f"解压完成，得到：{exes}")

    for n in exes:
        p = os.path.join(TOOLS, n)
        print(f"  {p}  ({os.path.getsize(p)/1024/1024:.1f} MB)")
    print("\n下一步：运行 `python tools/check_godot.py` 验证版本。")


if __name__ == "__main__":
    main()
