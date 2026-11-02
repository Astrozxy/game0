"""
EMBERFALL · 战斗推进（无头模拟，不含渲染）

这一层只负责"算"。渲染层拿到 Battle 的状态去画，不反过来影响它。
因此它可以在命令行里跑一万场。

规则对应：
- 激光严格直线：命中点 = 弹道线与舱室球体求交，取最近的那个。
- 射界：武器只能打自己 θ 覆盖范围内的目标，所以"船怎么转"是战术问题。
- 命中三档：远/中/近，影响命中率与伤害衰减。
- 随机：命中掷骰、毁伤程度、殉爆范围。
- 损管：每艘船有预算，战斗中缓慢修复。
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from model import (
    Ship, Compartment, CompType, CompState, COMP_NAMES,
    normalize, sub, add, mul, dot, length, angle_between, cross,
    make_ship, HULL_RADIUS, slot_world_offset, Slot,
)


# ---------------------------------------------------------------------------
# 武器与距离
# ---------------------------------------------------------------------------

# 激光参数（第一版基线）
LASER_MAX_RANGE = 35.0     # 最远射程
LASER_MID_RANGE = 22.0     # 中距上限
LASER_CLOSE_RANGE = 12.0   # 近距上限
LASER_COOLDOWN = 1.2       # 秒
LASER_BASE_DAMAGE = 26.0   # 近距离满伤

# 射界：每个武器舱覆盖的角度半宽（度）。180 = 半球，360 = 全向。
WEAPON_ARC_HALF_DEG = 100.0


def range_band(distance: float) -> str:
    if distance <= LASER_CLOSE_RANGE:
        return "close"
    if distance <= LASER_MID_RANGE:
        return "mid"
    return "far"


def band_accuracy(band: str) -> float:
    return {"close": 0.92, "mid": 0.72, "far": 0.40}[band]


def band_damage(distance: float) -> float:
    """距离越远，能量越散。"""
    if distance <= LASER_CLOSE_RANGE:
        return 1.0
    if distance <= LASER_MID_RANGE:
        return 0.78
    return 0.45


# ---------------------------------------------------------------------------
# 事件日志
# ---------------------------------------------------------------------------

@dataclass
class BattleEvent:
    t: float
    kind: str          # fire / hit / kill / crit / dc / end
    text: str
    team: str = ""
    ship_uid: int = -1
    target_uid: int = -1
    value: float = 0.0


# ---------------------------------------------------------------------------
# 战斗
# ---------------------------------------------------------------------------

@dataclass
class Doctrine:
    """舰队战斗手册：只规定允许的交战边界，具体开火归舰长。"""
    fire_band: str = "mid"        # 允许开火的最远档位：close / mid / far
    focus_fire: bool = True       # 是否集火当前最脆弱的目标
    hold_range: bool = True       # 是否保持射程，不主动贴脸

    def allows(self, distance: float) -> bool:
        order = {"close": 0, "mid": 1, "far": 2}
        return order[range_band(distance)] <= order[self.fire_band]


@dataclass
class Battle:
    ships: list[Ship]
    duration: float = 180.0
    rng: random.Random = field(default_factory=lambda: random.Random(12345))

    t: float = 0.0
    events: list[BattleEvent] = field(default_factory=list)
    over: bool = False
    winner: str = ""

    # 每艘船的武器冷却：key = (ship_uid, comp_index)
    _cooldowns: dict[tuple[int, int], float] = field(default_factory=dict)

    doctrl: Doctrine = field(default_factory=Doctrine)

    # --- 初始化 ---

    def __post_init__(self) -> None:
        self._uids = {s.uid: s for s in self.ships}
        # 首轮开火错开：否则所有船会在同一帧齐射，录像里像放烟花。
        for s in self.ships:
            for c in s.weapons:
                self._cooldowns[(s.uid, c.index)] = self.rng.uniform(0.0, LASER_COOLDOWN)

    def log(self, kind: str, text: str,
            team: str = "", ship_uid: int = -1,
            target_uid: int = -1, value: float = 0.0) -> None:
        self.events.append(BattleEvent(
            t=round(self.t, 2), kind=kind, text=text, team=team,
            ship_uid=ship_uid, target_uid=target_uid, value=value,
        ))

    # --- 查询 ---

    def enemies_of(self, ship: Ship) -> list[Ship]:
        return [s for s in self.ships if s.team != ship.team and s.alive]

    def allies_of(self, ship: Ship) -> list[Ship]:
        return [s for s in self.ships if s.team == ship.team and s.alive]

    def team_alive(self, team: str) -> int:
        return sum(1 for s in self.ships if s.team == team and s.alive)

    # --- 主循环 ---

    def step(self, dt: float) -> None:
        if self.over:
            return
        self.t += dt

        # 1) 损管
        for s in self.ships:
            if s.alive:
                s.dc_tick(dt)

        # 2) 转向与移动
        for s in self.ships:
            if not s.alive:
                continue
            target = self.pick_target(s)
            if target is not None:
                self.turn_toward(s, target, dt)
            self.move_ship(s, dt)

        # 3) 开火
        for s in self.ships:
            if not s.alive:
                continue
            self.ship_fire(s, dt)

        # 4) 冷却
        for key in list(self._cooldowns):
            self._cooldowns[key] -= dt
            if self._cooldowns[key] <= 0.0:
                del self._cooldowns[key]

        # 5) 结束判定
        for team in ("player", "enemy"):
            if self.team_alive(team) == 0:
                other = "enemy" if team == "player" else "player"
                self.over = True
                self.winner = other
                self.log("end", f"{'我方' if other == 'player' else '敌方'}获胜", team=other)
                return
        if self.t >= self.duration:
            self.over = True
            p = self.team_alive("player")
            e = self.team_alive("enemy")
            self.winner = "player" if p > e else ("enemy" if e > p else "draw")
            self.log("end", f"时间到，判定：{self.winner}")

    # --- 目标选择 ---

    def pick_target(self, ship: Ship) -> Ship | None:
        enemies = self.enemies_of(ship)
        if not enemies:
            return None

        def score(e: Ship) -> float:
            d = length(sub(e.pos, ship.pos))
            if self.doctrl.focus_fire:
                # 集火：优先打残的
                return d * (0.4 + e.hull_integrity())
            return d

        return min(enemies, key=score)

    # --- 转向 ---

    def turn_toward(self, ship: Ship, target: Ship, dt: float) -> None:
        desired = normalize(sub(target.pos, ship.pos))
        cur = normalize(ship.heading)
        # 简单限速转向：每帧最多转 X 弧度
        max_turn = math.radians(25.0) * dt
        ang = angle_between(cur, desired)
        if ang <= max_turn or ang < 1e-6:
            ship.heading = desired
        else:
            axis = cross(cur, desired)
            if length(axis) < 1e-9:
                return
            axis = normalize(axis)
            # 罗德里格斯旋转
            ship.heading = rotate_around(cur, axis, max_turn)

    # --- 移动 ---

    def move_ship(self, ship: Ship, dt: float) -> None:
        enemies = self.enemies_of(ship)
        if not enemies:
            return
        nearest = min(enemies, key=lambda e: length(sub(e.pos, ship.pos)))
        d = length(sub(nearest.pos, ship.pos))

        # 期望的保持距离：中距中央附近
        desired_gap = 18.0 if self.doctrl.hold_range else 10.0
        if d > desired_gap + 2.0:
            direction = normalize(sub(nearest.pos, ship.pos))
            speed = ship.speed
            ship.vel = mul(direction, speed)
        elif d < desired_gap - 2.0:
            direction = normalize(sub(ship.pos, nearest.pos))
            ship.vel = mul(direction, ship.speed * 0.6)
        else:
            ship.vel = mul(ship.vel, 0.85)

        ship.pos = add(ship.pos, mul(ship.vel, dt))

    # --- 开火 ---

    def ship_fire(self, ship: Ship, dt: float) -> None:
        weapons = ship.weapons
        if not weapons:
            return
        enemies = self.enemies_of(ship)
        if not enemies:
            return

        # 舰长先定"这一轮打谁"，再让每门炮尝试打它。
        # 这就是"集火"：不是每门炮各自挑目标，否则火力会被摊薄，谁都打不死。
        primary = self.pick_target(ship)

        for comp in weapons:
            key = (ship.uid, comp.index)
            if key in self._cooldowns:
                continue

            target = None
            if primary is not None and self.weapon_can_hit(ship, comp, primary):
                target = primary
            else:
                # 主目标不在射界内，退而求其次
                target = self.pick_weapon_target(ship, comp, enemies)

            if target is None:
                continue

            self._cooldowns[key] = LASER_COOLDOWN
            self.fire_laser(ship, comp, target)

    def weapon_can_hit(self, ship: Ship, comp: Compartment, target: Ship) -> bool:
        """这门炮能不能打到这个目标：射程 + 手册 + 射界。"""
        d = length(sub(target.pos, ship.pos))
        if d > LASER_MAX_RANGE:
            return False
        if not self.doctrl.allows(d):
            return False
        mounting = slot_world_offset(Slot(comp.index, comp.theta_deg, comp.h), HULL_RADIUS)
        mount_dir = normalize(local_dir_to_world(ship.heading, mounting))
        to_target = normalize(sub(target.pos, ship.pos))
        return math.degrees(angle_between(mount_dir, to_target)) <= WEAPON_ARC_HALF_DEG

    def pick_weapon_target(self, ship: Ship, comp: Compartment,
                           enemies: list[Ship]) -> Ship | None:
        """退路：主目标打不到时，找射界内最近的敌人。"""
        valid = [e for e in enemies if self.weapon_can_hit(ship, comp, e)]
        if not valid:
            return None
        return min(valid, key=lambda e: length(sub(e.pos, ship.pos)))

    def fire_laser(self, ship: Ship, comp: Compartment, target: Ship) -> None:
        d = length(sub(target.pos, ship.pos))
        band = range_band(d)

        accuracy = band_accuracy(band) * ship.accuracy
        accuracy = max(0.05, min(0.98, accuracy))

        if self.rng.random() > accuracy:
            self.log("fire", f"{ship.name} 的{COMP_NAMES[comp.kind]}开火，未命中", ship.team, ship.uid, target.uid)
            return

        dmg = LASER_BASE_DAMAGE * band_damage(d) * (0.85 + 0.3 * self.rng.random())
        dmg *= (1.0 - target.damage_reduction)

        hit_comp = self.resolve_hit_compartment(ship, target, comp)
        if hit_comp is None:
            return

        before = hit_comp.state
        dealt = hit_comp.take_damage(dmg)

        self.log("hit",
                 f"{ship.name} 命中 {target.name} 的{COMP_NAMES[hit_comp.kind]} "
                 f"({dealt:.0f})",
                 ship.team, ship.uid, target.uid, dealt)

        # 状态转变播报
        if hit_comp.state is CompState.OFFLINE and before is not CompState.OFFLINE:
            self.log("crit", f"{target.name} 的{COMP_NAMES[hit_comp.kind]}停转",
                     target.team, target.uid)
            if hit_comp.kind is CompType.MAGAZINE:
                self.explode_magazine(target, hit_comp)

        if not target.alive:
            self.log("kill", f"{target.name} 失去战斗力", target.team, target.uid)

    # --- 命中判定：直线与舱室求交 ---

    def resolve_hit_compartment(self, shooter: Ship, target: Ship,
                                weapon: Compartment) -> Compartment | None:
        """激光是一条直线：从射手到目标，取最先被击中的舱室。

        第一版简化：把每个舱室当成球体，求弹道线到球心的最近距离，
        距离小于半径即视为命中；取沿弹道参数 t 最小的那个。
        """
        origin = shooter.pos
        direction = normalize(sub(target.pos, origin))
        best = None
        best_t = 1e18

        for c in target.compartments:
            if not c.alive:
                continue
            center = target.comp_world_pos(c)
            rel = sub(center, origin)
            t_proj = dot(rel, direction)
            if t_proj < 0:
                continue
            closest = add(origin, mul(direction, t_proj))
            dist = length(sub(center, closest))
            if dist <= c.radius:
                if t_proj < best_t:
                    best_t = t_proj
                    best = c

        if best is not None:
            return best

        # 没扫到任何舱室（比如擦过边缘）：按"离弹道最近"的那个算擦伤
        candidates = [c for c in target.compartments if c.alive]
        if not candidates:
            return None
        return min(
            candidates,
            key=lambda c: length(sub(target.comp_world_pos(c),
                                     add(origin, mul(direction, dot(sub(target.comp_world_pos(c), origin), direction))))),
        )

    # --- 殉爆 ---

    def explode_magazine(self, ship: Ship, mag: Compartment) -> None:
        """弹药库殉爆：伤害相邻舱室。相邻 = 柱面上距离近。"""
        base = 45.0
        self.log("crit", f"{ship.name} 的弹药库殉爆！", ship.team, ship.uid, value=base)
        for c in ship.compartments:
            if c is mag or not c.alive:
                continue
            d_theta = abs(((c.theta_deg - mag.theta_deg + 180) % 360) - 180)
            d_h = abs(c.h - mag.h)
            adjacency = max(0.0, 1.0 - (d_theta / 180.0) * 0.7 - d_h * 0.3)
            if adjacency <= 0.05:
                continue
            dmg = base * adjacency
            c.take_damage(dmg)
            if c.state is CompState.OFFLINE:
                self.log("crit", f"殉爆波及 {COMP_NAMES[c.kind]}，停转", ship.team, ship.uid)

    # --- 汇总 ---

    def summary(self) -> dict:
        out = {}
        for team in ("player", "enemy"):
            ships = [s for s in self.ships if s.team == team]
            survived = [s for s in ships if s.alive]
            destroyed_comps = {}
            for s in ships:
                for c in s.compartments:
                    if c.state is CompState.OFFLINE:
                        destroyed_comps[COMP_NAMES[c.kind]] = destroyed_comps.get(COMP_NAMES[c.kind], 0) + 1
            out[team] = {
                "ships": len(ships),
                "survived": len(survived),
                "lost": len(ships) - len(survived),
                "destroyed_comps": destroyed_comps,
                "avg_hull": sum(s.hull_integrity() for s in survived) / max(1, len(survived)),
            }
        out["time"] = round(self.t, 1)
        out["winner"] = self.winner
        return out


# ---------------------------------------------------------------------------
# 几何辅助
# ---------------------------------------------------------------------------

def local_dir_to_world(heading, local) -> tuple[float, float, float]:
    f = normalize(heading)
    up_hint = (0.0, 0.0, 1.0)
    if abs(dot(f, up_hint)) > 0.99:
        up_hint = (0.0, 1.0, 0.0)
    right = normalize(cross(f, up_hint))
    up = normalize(cross(right, f))
    return (
        right[0] * local[0] + up[0] * local[1] + f[0] * local[2],
        right[1] * local[0] + up[1] * local[1] + f[1] * local[2],
        right[2] * local[0] + up[2] * local[1] + f[2] * local[2],
    )


def rotate_around(v, axis, ang: float):
    """罗德里格斯旋转公式。"""
    c = math.cos(ang)
    s = math.sin(ang)
    ax = axis
    return (
        v[0] * c + (ax[1] * v[2] - ax[2] * v[1]) * s + ax[0] * dot(ax, v) * (1 - c),
        v[1] * c + (ax[2] * v[0] - ax[0] * v[2]) * s + ax[1] * dot(ax, v) * (1 - c),
        v[2] * c + (ax[0] * v[1] - ax[1] * v[0]) * s + ax[2] * dot(ax, v) * (1 - c),
    )


# ---------------------------------------------------------------------------
# 场景构造
# ---------------------------------------------------------------------------

def make_battle(n_per_side: int = 20, seed: int = 12345,
                player_loadout=None, enemy_loadout=None) -> Battle:
    ships: list[Ship] = []
    uid = 0
    # 两军沿 x 轴对称展开，初始相距 60
    for i in range(n_per_side):
        offset = (i - (n_per_side - 1) / 2.0) * 3.0
        ships.append(make_ship(
            uid, f"P-{i + 1:02d}", "player",
            (-30.0, offset, (i % 3 - 1) * 0.6),
            player_loadout,
        ))
        uid += 1
    for i in range(n_per_side):
        offset = (i - (n_per_side - 1) / 2.0) * 3.0
        ships.append(make_ship(
            uid, f"E-{i + 1:02d}", "enemy",
            (30.0, offset, (i % 3 - 1) * 0.6),
            enemy_loadout,
        ))
        uid += 1
    return Battle(ships=ships, rng=random.Random(seed))
