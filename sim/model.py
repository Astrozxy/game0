"""
EMBERFALL · 战斗核心：数据模型与几何

设计依据（已锁定的规则）：
- 舰船是圆柱体，动力仓在中轴，舱室绕轴分布，坐标为 (theta, h)。
- 战斗是三维的：舰船有三维位置与朝向。
- 激光是严格直线：命中判定 = 弹道线与舱室求交。
- 舱室有独立生命值；受损会降效，归零则停转。
- 损管有预算，战斗中可缓慢修复。

本文件只放"是什么"，不放"怎么打"。战斗推进在 battle.py。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


# ---------------------------------------------------------------------------
# 舱室
# ---------------------------------------------------------------------------

class CompType(str, Enum):
    WEAPON = "weapon"      # 武器舱：提供火力，被毁则该武器失效
    MAGAZINE = "magazine"  # 弹药库：被毁会殉爆，连带伤害相邻舱室
    CREW = "crew"          # 人员宿舍：被毁则全船效率下降
    ENGINE = "engine"      # 引擎：被毁则航速下降
    SHIELD = "shield"      # 护盾发生器：被毁则防御下降
    SENSOR = "sensor"      # 传感器：被毁则命中率下降


# 每种舱室的固有属性。数值是第一版基线，后续用无头模拟调。
COMP_STATS: dict[CompType, dict] = {
    CompType.WEAPON:   {"hp": 60,  "armor": 2,  "radius": 0.55, "mass": 1.0},
    CompType.MAGAZINE: {"hp": 45,  "armor": 1,  "radius": 0.50, "mass": 0.8},
    CompType.CREW:     {"hp": 40,  "armor": 1,  "radius": 0.45, "mass": 0.6},
    CompType.ENGINE:   {"hp": 70,  "armor": 2,  "radius": 0.60, "mass": 1.2},
    CompType.SHIELD:   {"hp": 55,  "armor": 3,  "radius": 0.55, "mass": 1.0},
    CompType.SENSOR:   {"hp": 35,  "armor": 1,  "radius": 0.40, "mass": 0.5},
}

# 中文名，用于战报
COMP_NAMES: dict[CompType, str] = {
    CompType.WEAPON: "武器舱",
    CompType.MAGAZINE: "弹药库",
    CompType.CREW: "人员宿舍",
    CompType.ENGINE: "引擎",
    CompType.SHIELD: "护盾发生器",
    CompType.SENSOR: "传感器",
}


class CompState(str, Enum):
    ONLINE = "online"    # 在线
    DAMAGED = "damaged"  # 受损：效率下降，有停转风险
    OFFLINE = "offline"  # 停转：完全失效


@dataclass
class Compartment:
    """舰船上的一个舱室。位置用柱坐标描述（绕轴角度 + 沿轴高度）。"""
    index: int
    kind: CompType
    theta_deg: float      # 绕中轴的角度，0–360
    h: float              # 沿中轴的高度（相对动力仓中心）
    radius: float         # 数据半径，用于命中判定与体积

    hp: float = 0.0
    armor: float = 0.0
    state: CompState = CompState.ONLINE

    # 损管相关
    repair_progress: float = 0.0

    def __post_init__(self) -> None:
        if self.hp <= 0.0:
            self.hp = float(COMP_STATS[self.kind]["hp"])
        if self.armor <= 0.0:
            self.armor = float(COMP_STATS[self.kind]["armor"])

    @property
    def max_hp(self) -> float:
        return float(COMP_STATS[self.kind]["hp"])

    @property
    def alive(self) -> bool:
        return self.state is not CompState.OFFLINE

    @property
    def hp_ratio(self) -> float:
        return max(0.0, min(1.0, self.hp / self.max_hp))

    def efficiency(self) -> float:
        """该舱室的输出效率。受损打七折，停转为零。"""
        if self.state is CompState.OFFLINE:
            return 0.0
        if self.state is CompState.DAMAGED:
            return 0.70
        return 1.0

    def take_damage(self, amount: float) -> float:
        """扣血。返回实际造成的伤害。"""
        if not self.alive or amount <= 0.0:
            return 0.0
        effective = max(0.0, amount - self.armor)
        if effective <= 0.0:
            return 0.0
        self.hp -= effective
        if self.hp <= 0.0:
            self.hp = 0.0
            self.state = CompState.OFFLINE
        elif self.hp_ratio < 0.40:
            self.state = CompState.DAMAGED
        return effective


# ---------------------------------------------------------------------------
# 船体槽位（固定槽位方案）
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Slot:
    """一个固定槽位。玩家只能决定往这个槽里放什么舱室类型。"""
    index: int
    theta_deg: float
    h: float


# 第一版船体：围绕中轴的两圈，每圈 5 个槽，共 10 个。
# 这是"10 个主武器舱"那个设定的直接落地：10 个槽，你分配功能。
HULL_SLOTS: tuple[Slot, ...] = tuple(
    Slot(index=i, theta_deg=(i * 72.0) % 360.0, h=(+1.0 if i < 5 else -1.0))
    for i in range(10)
)

HULL_RADIUS = 1.15  # 舱室到中轴的距离


def slot_world_offset(slot: Slot, radius: float = HULL_RADIUS) -> tuple[float, float, float]:
    """把柱坐标槽位换算成舰体局部坐标（x, y, z）。

    约定：z 是中轴（前后方向），x/y 是横截面。
    这样 theta 就是绕前向的滚转角，h 是沿前向的位置。
    """
    rad = math.radians(slot.theta_deg)
    return (radius * math.cos(rad), radius * math.sin(rad), slot.h)


# ---------------------------------------------------------------------------
# 舰船
# ---------------------------------------------------------------------------

@dataclass
class Ship:
    uid: int
    name: str
    team: str                       # "player" / "enemy"
    pos: tuple[float, float, float] = (0.0, 0.0, 0.0)
    vel: tuple[float, float, float] = (0.0, 0.0, 0.0)
    heading: tuple[float, float, float] = (0.0, 0.0, 1.0)

    compartments: list[Compartment] = field(default_factory=list)

    # 损管预算：一场战斗总共能修多少点结构
    dc_budget: float = 120.0
    dc_rate: float = 1.6            # 每秒修复点数（受人员宿舍影响）

    def __post_init__(self) -> None:
        if not self.compartments:
            self.compartments = default_loadout()

    # --- 派生属性。全部由"还活着的舱室"算出来，不缓存，避免状态不同步 ---

    def _sum_eff(self, kind: CompType) -> float:
        return sum(c.efficiency() for c in self.compartments if c.kind is kind)

    @property
    def alive(self) -> bool:
        return any(c.alive for c in self.compartments)

    @property
    def speed(self) -> float:
        """基础航速，受引擎影响。"""
        base = 1.6
        engines = self._sum_eff(CompType.ENGINE)
        if engines <= 0.0:
            return base * 0.15           # 引擎全毁，几乎动不了
        return base * (0.25 + 0.75 * engines / max(1.0, self._engine_slots()))

    def _engine_slots(self) -> float:
        return max(1.0, float(sum(1 for c in self.compartments if c.kind is CompType.ENGINE)))

    @property
    def accuracy(self) -> float:
        """命中率系数，受传感器与人员影响。"""
        sensors = self._sum_eff(CompType.SENSOR)
        crew = self._sum_eff(CompType.CREW)
        sensor_n = max(1.0, float(sum(1 for c in self.compartments if c.kind is CompType.SENSOR)))
        crew_n = max(1.0, float(sum(1 for c in self.compartments if c.kind is CompType.CREW)))
        return 0.55 + 0.30 * (sensors / sensor_n) + 0.15 * (crew / crew_n)

    @property
    def damage_reduction(self) -> float:
        """护盾提供的减伤比例（0–0.6）。"""
        shields = self._sum_eff(CompType.SHIELD)
        n = max(1.0, float(sum(1 for c in self.compartments if c.kind is CompType.SHIELD)))
        return min(0.6, 0.6 * shields / n)

    @property
    def repair_rate(self) -> float:
        crew = self._sum_eff(CompType.CREW)
        n = max(1.0, float(sum(1 for c in self.compartments if c.kind is CompType.CREW)))
        return self.dc_rate * (0.4 + 0.6 * crew / n)

    @property
    def weapons(self) -> list[Compartment]:
        return [c for c in self.compartments
                if c.kind is CompType.WEAPON and c.alive]

    @property
    def total_max_hp(self) -> float:
        return sum(c.max_hp for c in self.compartments)

    @property
    def total_hp(self) -> float:
        return sum(c.hp for c in self.compartments)

    def hull_integrity(self) -> float:
        return self.total_hp / max(1.0, self.total_max_hp)

    def comp_world_pos(self, comp: Compartment) -> tuple[float, float, float]:
        """舱室在战场坐标系中的位置。"""
        lx, ly, lz = slot_world_offset(
            Slot(comp.index, comp.theta_deg, comp.h),
            HULL_RADIUS,
        )
        return local_to_world(self.pos, self.heading, (lx, ly, lz))

    def dc_tick(self, dt: float) -> None:
        """损管：自动修最需要修的舱室，消耗预算。"""
        if self.dc_budget <= 0.0:
            return

        # 优先修"停转"的，其次修"受损"的，同级里选修血最少的比例
        candidates = [c for c in self.compartments if c.alive or c.hp < c.max_hp]
        if not candidates:
            return

        def priority(c: Compartment) -> tuple[int, float]:
            rank = 0 if c.state is CompState.OFFLINE else 1
            return (rank, c.hp_ratio)

        target = min(candidates, key=priority)
        if target.hp >= target.max_hp:
            return

        amount = min(self.repair_rate * dt, self.dc_budget, target.max_hp - target.hp)
        if amount <= 0.0:
            return
        target.hp += amount
        self.dc_budget -= amount

        if target.hp >= target.max_hp:
            target.hp = target.max_hp
            target.state = CompState.ONLINE
        elif target.state is CompState.OFFLINE and target.hp_ratio >= 0.35:
            # 修到一定程度就恢复部分功能，但仍是"受损"
            target.state = CompState.DAMAGED
        elif target.state is CompState.ONLINE and target.hp_ratio < 0.40:
            target.state = CompState.DAMAGED


# ---------------------------------------------------------------------------
# 向量与几何工具
# ---------------------------------------------------------------------------

def normalize(v: tuple[float, float, float]) -> tuple[float, float, float]:
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if n < 1e-9:
        return (0.0, 0.0, 1.0)
    return (v[0] / n, v[1] / n, v[2] / n)


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def mul(a, s: float):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def length(a) -> float:
    return math.sqrt(dot(a, a))


def angle_between(a, b) -> float:
    """返回弧度，0–pi。"""
    la, lb = length(a), length(b)
    if la < 1e-9 or lb < 1e-9:
        return 0.0
    c = max(-1.0, min(1.0, dot(a, b) / (la * lb)))
    return math.acos(c)


def local_to_world(origin, heading, local) -> tuple[float, float, float]:
    """把舰体局部坐标旋转到世界坐标。

    简化：只用 heading 建立一个正交基。第一版不处理翻滚（roll），
    因为激光是绕轴的，roll 不影响命中判定，只影响画面表现。
    """
    f = normalize(heading)
    up_hint = (0.0, 0.0, 1.0)
    if abs(dot(f, up_hint)) > 0.99:
        up_hint = (0.0, 1.0, 0.0)
    right = normalize(cross(f, up_hint))
    up = normalize(cross(right, f))

    # local 约定：(x 右, y 上, z 前)
    wx = right[0] * local[0] + up[0] * local[1] + f[0] * local[2]
    wy = right[1] * local[0] + up[1] * local[1] + f[1] * local[2]
    wz = right[2] * local[0] + up[2] * local[1] + f[2] * local[2]
    return (origin[0] + wx, origin[1] + wy, origin[2] + wz)


def cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


# ---------------------------------------------------------------------------
# 默认装配
# ---------------------------------------------------------------------------

# 第一版默认布局：2 门主武器 + 2 弹药库 + 3 引擎 + 2 护盾 + 1 传感器
# 故意不做成"最优"——它是给人改的起点。
DEFAULT_LOADOUT: tuple[CompType, ...] = (
    CompType.WEAPON,    # 0
    CompType.WEAPON,    # 1
    CompType.MAGAZINE,  # 2
    CompType.MAGAZINE,  # 3
    CompType.ENGINE,    # 4
    CompType.ENGINE,    # 5
    CompType.ENGINE,    # 6
    CompType.SHIELD,    # 7
    CompType.SHIELD,    # 8
    CompType.SENSOR,    # 9
)


def default_loadout() -> list[Compartment]:
    return [
        Compartment(
            index=i,
            kind=DEFAULT_LOADOUT[i],
            theta_deg=HULL_SLOTS[i].theta_deg,
            h=HULL_SLOTS[i].h,
            radius=float(COMP_STATS[DEFAULT_LOADOUT[i]]["radius"]),
        )
        for i in range(len(HULL_SLOTS))
    ]


def make_ship(uid: int, name: str, team: str, pos, loadout=None) -> Ship:
    comps = []
    kinds = loadout or DEFAULT_LOADOUT
    for i, slot in enumerate(HULL_SLOTS):
        kind = kinds[i]
        comps.append(Compartment(
            index=i,
            kind=kind,
            theta_deg=slot.theta_deg,
            h=slot.h,
            radius=float(COMP_STATS[kind]["radius"]),
        ))
    return Ship(uid=uid, name=name, team=team, pos=pos, compartments=comps)
