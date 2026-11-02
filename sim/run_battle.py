"""
EMBERFALL · 无头战斗运行器

用法：
    python run_battle.py              # 跑一场，打印战报
    python run_battle.py --batch 200  # 跑 200 场，输出统计
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys

from battle import Battle, make_battle, Doctrine, range_band
from model import COMP_NAMES, CompState


def run_one(seed: int, n_per_side: int = 20) -> Battle:
    b = make_battle(n_per_side=n_per_side, seed=seed)
    dt = 0.1
    while not b.over:
        b.step(dt)
    return b


def print_report(b: Battle) -> None:
    s = b.summary()
    print("=" * 68)
    print(f"战斗结束：t={s['time']}s   胜者={s['winner']}")
    print("-" * 68)
    for team, label in (("player", "我方"), ("enemy", "敌方")):
        d = s[team]
        print(f"{label}: 存活 {d['survived']}/{d['ships']}  "
              f"平均船体 {d['avg_hull'] * 100:.0f}%")
        if d["destroyed_comps"]:
            parts = "，".join(f"{k}×{v}" for k, v in sorted(d["destroyed_comps"].items()))
            print(f"      损失舱室: {parts}")
    print("-" * 68)
    print("关键事件（前 40 条）：")
    for e in b.events[:40]:
        print(f"  [{e.t:7.2f}] {e.text}")
    if len(b.events) > 40:
        print(f"  ...（共 {len(b.events)} 条事件）")


def run_batch(n: int, n_per_side: int) -> None:
    wins = {"player": 0, "enemy": 0, "draw": 0}
    times = []
    player_lost = []
    enemy_lost = []

    for seed in range(n):
        b = run_one(seed, n_per_side)
        s = b.summary()
        wins[s["winner"]] += 1
        times.append(s["time"])
        player_lost.append(s["player"]["lost"])
        enemy_lost.append(s["enemy"]["lost"])

    print(f"跑了 {n} 场（每方 {n_per_side} 艘）")
    print(f"胜率：我方 {wins['player'] / n:.1%}  敌方 {wins['enemy'] / n:.1%}  "
          f"平局 {wins['draw'] / n:.1%}")
    print(f"平均时长：{statistics.mean(times):.1f}s  "
          f"最短 {min(times):.1f}s  最长 {max(times):.1f}s")
    print(f"平均损失：我方 {statistics.mean(player_lost):.1f} 艘  "
          f"敌方 {statistics.mean(enemy_lost):.1f} 艘")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, default=0)
    ap.add_argument("--ships", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    if args.batch:
        run_batch(args.batch, args.ships)
    else:
        b = run_one(args.seed, args.ships)
        print_report(b)


if __name__ == "__main__":
    main()
