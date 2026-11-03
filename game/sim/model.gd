class_name Model
extends RefCounted
## EMBERFALL · 数据模型
##
## 规则对应：
## - 舰船是圆柱体，动力仓在中轴，舱室绕轴分布，坐标为 (theta, h)。
## - 战斗是三维的，舰船有三维位置与朝向。
## - 舱室有独立生命值，受损降效，归零停转。
## - 损管有预算，战斗中缓慢修复。

enum CompType {
	WEAPON,        # 激光：中近程、全能、稳定
	WEAPON_LONG,   # 长程炮：远射程、单发高、近距离打不了
	WEAPON_CLOSE,  # 近防炮：极近距离、射速快
	MAGAZINE, CREW, ENGINE, SHIELD, SENSOR,
}
enum CompState { ONLINE, DAMAGED, OFFLINE }
enum CapType { AGGRESSIVE, STEADY, CAUTIOUS }

const HULL_RADIUS := 1.45
const SLOT_COUNT := 10

# 每种舱室的固有属性。第一版基线。
# HP_SCALE 是全局血量系数：调这一个数就能整体加快/放慢战斗节奏。
const HP_SCALE := 0.72

static func comp_max_hp(kind: int) -> float:
	var base := 50.0
	match kind:
		CompType.WEAPON:       base = 60.0
		CompType.WEAPON_LONG:  base = 70.0
		CompType.WEAPON_CLOSE: base = 50.0
		CompType.MAGAZINE:     base = 45.0
		CompType.CREW:         base = 40.0
		CompType.ENGINE:       base = 70.0
		CompType.SHIELD:       base = 55.0
		CompType.SENSOR:       base = 35.0
	return base * HP_SCALE

static func comp_armor(kind: int) -> float:
	match kind:
		CompType.WEAPON:       return 2.0
		CompType.WEAPON_LONG:  return 3.0
		CompType.WEAPON_CLOSE: return 1.0
		CompType.MAGAZINE: return 1.0
		CompType.CREW:     return 1.0
		CompType.ENGINE:   return 2.0
		CompType.SHIELD:   return 3.0
		CompType.SENSOR:   return 1.0
	return 1.0

static func comp_radius(kind: int) -> float:
	match kind:
		CompType.WEAPON:       return 0.55
		CompType.WEAPON_LONG:  return 0.65
		CompType.WEAPON_CLOSE: return 0.45
		CompType.MAGAZINE: return 0.50
		CompType.CREW:     return 0.45
		CompType.ENGINE:   return 0.60
		CompType.SHIELD:   return 0.55
		CompType.SENSOR:   return 0.40
	return 0.5

static func comp_crew(kind: int) -> int:
	match kind:
		CompType.WEAPON:       return 6
		CompType.WEAPON_LONG:  return 5
		CompType.WEAPON_CLOSE: return 4
		CompType.MAGAZINE: return 4
		CompType.CREW:     return 10
		CompType.ENGINE:   return 5
		CompType.SHIELD:   return 4
		CompType.SENSOR:   return 3
	return 4

static func comp_name(kind: int) -> String:
	match kind:
		CompType.WEAPON:       return "激光炮"
		CompType.WEAPON_LONG:  return "长程炮"
		CompType.WEAPON_CLOSE: return "近防炮"
		CompType.MAGAZINE: return "弹药库"
		CompType.CREW:     return "人员宿舍"
		CompType.ENGINE:   return "引擎"
		CompType.SHIELD:   return "护盾发生器"
		CompType.SENSOR:   return "传感器"
	return "舱室"

static func is_weapon(kind: int) -> bool:
	return kind == CompType.WEAPON or kind == CompType.WEAPON_LONG or kind == CompType.WEAPON_CLOSE

# ---------------------------------------------------------------- 舰长
#
# 玩家不能指定舰长。舰长的性格决定他"在手册允许的范围内"怎么打：
# 激进 = 贴得更近（命中高、挨打也多）；谨慎 = 拉得更远（安全但打得慢）。
# 玩家能做的是编写手册（允许的交战边界）和指定舰队指挥官。

static func cap_name(kind: int) -> String:
	match kind:
		CapType.AGGRESSIVE: return "激进"
		CapType.STEADY:     return "稳健"
		CapType.CAUTIOUS:   return "谨慎"
	return "未知"


class Captain:
	var captain_name: String
	var personality: int

	func _init(p_name: String, p_personality: int) -> void:
		captain_name = p_name
		personality = p_personality

	func gap_mult() -> float:
		match personality:
			Model.CapType.AGGRESSIVE: return 0.72
			Model.CapType.CAUTIOUS:   return 1.28
			_:                        return 1.0

	func accuracy_mod() -> float:
		match personality:
			Model.CapType.AGGRESSIVE: return 0.95
			Model.CapType.CAUTIOUS:   return 1.06
			_:                        return 1.0

	func label() -> String:
		return "%s（%s）" % [captain_name, Model.cap_name(personality)]


const CAPTAIN_NAMES: Array = [
	"林澈", "周野", "沈渡", "顾行", "陆遥", "许铮",
	"程砾", "韩烬", "苏牧", "叶迟", "郑临", "白砚",
	"秦砚", "谢陵", "裴舟", "温序", "阮明", "霍川",
	"岑野", "闻笛", "商陆", "祁寒", "薛岸", "罗启",
]

static func make_captain(rng: RandomNumberGenerator) -> Captain:
	var n: String = CAPTAIN_NAMES[rng.randi_range(0, CAPTAIN_NAMES.size() - 1)]
	var p: int = [CapType.AGGRESSIVE, CapType.STEADY, CapType.CAUTIOUS][rng.randi_range(0, 2)]
	return Captain.new(n, p)

static func comp_color(kind: int) -> Color:
	match kind:
		CompType.WEAPON:       return Color(0.95, 0.35, 0.30)
		CompType.WEAPON_LONG:  return Color(0.80, 0.25, 0.55)
		CompType.WEAPON_CLOSE: return Color(0.98, 0.60, 0.15)
		CompType.MAGAZINE: return Color(0.95, 0.75, 0.25)
		CompType.CREW:     return Color(0.45, 0.80, 0.55)
		CompType.ENGINE:   return Color(0.35, 0.65, 0.95)
		CompType.SHIELD:   return Color(0.65, 0.50, 0.95)
		CompType.SENSOR:   return Color(0.55, 0.85, 0.90)
	return Color.WHITE

# 舰体硬点：坐标是舰体局部坐标（+Z 舰首，+Y 上，+X 右），dir 是外法线。
# 几何先定，舱位跟着舰体走——这是"军舰设计"而不是"圆环上摆格子"。
const HARDPOINTS: Array = [
	[Vector3(0.0, 0.30, 3.55), Vector3(0, 0.15, 1)],    # 0 舰首主炮位
	[Vector3(0.0, 0.80, 1.60), Vector3(0, 1, 0.15)],    # 1 背部炮塔 A
	[Vector3(0.0, 0.80, -0.20), Vector3(0, 1, -0.10)],  # 2 背部炮塔 B
	[Vector3(-1.30, 0.10, 0.90), Vector3(-1, 0, 0)],    # 3 左舷炮组
	[Vector3(1.30, 0.10, 0.90), Vector3(1, 0, 0)],      # 4 右舷炮组
	[Vector3(0.0, -0.70, 2.10), Vector3(0, -1, 0.20)],  # 5 腹部炮塔
	[Vector3(0.0, 1.15, -1.50), Vector3(0, 1, 0)],      # 6 舰桥 / 传感器
	[Vector3(-0.70, 0.0, -3.70), Vector3(0, 0, -1)],    # 7 左引擎组
	[Vector3(0.70, 0.0, -3.70), Vector3(0, 0, -1)],     # 8 右引擎组
	[Vector3(0.0, 0.20, -2.40), Vector3(0, 1, 0)],      # 9 弹药库
]

static func hardpoint_pos(i: int) -> Vector3:
	return HARDPOINTS[i][0]

static func hardpoint_dir(i: int) -> Vector3:
	return HARDPOINTS[i][1]

static func hardpoint_name(i: int) -> String:
	match i:
		0: return "舰首炮"
		1: return "背塔A"
		2: return "背塔B"
		3: return "左舷"
		4: return "右舷"
		5: return "腹部"
		6: return "舰桥"
		7: return "引擎L"
		8: return "引擎R"
		9: return "弹药库"
	return "舱位"

# 默认装配：舰首长程炮、背腹三座激光、两侧近防、舰桥传感器、双引擎、弹药库。
static func default_loadout() -> Array:
	return [
		CompType.WEAPON_LONG, CompType.WEAPON, CompType.WEAPON,
		CompType.WEAPON_CLOSE, CompType.WEAPON_CLOSE, CompType.SHIELD,
		CompType.SENSOR, CompType.ENGINE, CompType.ENGINE, CompType.MAGAZINE,
	]


class Compartment:
	var index: int
	var kind: int
	var local_pos: Vector3      # 舰体局部坐标
	var dir: Vector3            # 外法线（炮口朝向 / 装甲面朝向）
	var theta_deg: float        # 兼容旧代码：由 local_pos 推出的方位角
	var h: float                # 兼容旧代码：沿轴位置
	var radius: float
	var hp: float
	var armor: float
	var state: int = Model.CompState.ONLINE

	# 船员：每个舱室有自己的编制。玩家不能操作他们，只能看他们干活和死。
	var crew: int = 0
	var crew_max: int = 0
	var breached: bool = false      # 是否已失压（被击穿，人会飞出去）

	func _init(p_index: int, p_kind: int, p_pos: Vector3, p_dir: Vector3) -> void:
		index = p_index
		kind = p_kind
		local_pos = p_pos
		dir = p_dir.normalized()
		theta_deg = rad_to_deg(atan2(p_pos.y, p_pos.x))
		h = p_pos.z
		radius = Model.comp_radius(p_kind)
		hp = Model.comp_max_hp(p_kind)
		armor = Model.comp_armor(p_kind)
		crew_max = Model.comp_crew(p_kind)
		crew = crew_max

	func crew_ratio() -> float:
		return float(crew) / maxf(1.0, float(crew_max))

	func kill_crew(n: int) -> int:
		var dead: int = mini(n, crew)
		crew -= dead
		return dead

	func max_hp() -> float:
		return Model.comp_max_hp(kind)

	func alive() -> bool:
		return state != Model.CompState.OFFLINE

	func hp_ratio() -> float:
		return clampf(hp / maxf(1.0, max_hp()), 0.0, 1.0)

	func efficiency() -> float:
		if state == Model.CompState.OFFLINE:
			return 0.0
		if state == Model.CompState.DAMAGED:
			return 0.70
		return 1.0

	func take_damage(amount: float) -> float:
		if not alive() or amount <= 0.0:
			return 0.0
		var effective: float = maxf(0.0, amount - armor)
		if effective <= 0.0:
			return 0.0
		hp -= effective

		# 船员伤亡（确定性，方便回放）：伤害越重，死得越多。
		if crew > 0:
			var cas: int = int(effective / 10.0)
			if cas < 1 and effective > 3.0:
				cas = 1
			kill_crew(cas)

		if hp <= 0.0:
			hp = 0.0
			state = Model.CompState.OFFLINE
			breached = true
			crew = 0
		elif hp_ratio() < 0.40:
			state = Model.CompState.DAMAGED
		return effective

	func local_offset() -> Vector3:
		return local_pos


class ShipModel:
	var uid: int
	var ship_name: String
	var team: String
	var pos := Vector3.ZERO
	var heading := Vector3(0, 0, 1)
	var compartments: Array = []
	var dc_budget := 120.0
	var dc_rate := 1.6
	var captain = null      # Model.Captain：玩家不能指定

	# 武器能量池：开火要耗能，回充需要时间。
	# 这让"什么时候开火"变成真正的取舍：远距乱打会把能量浪费在低命中上。
	var energy := 100.0
	var energy_max := 100.0
	var energy_regen := 11.0

	func regen_energy(dt: float) -> void:
		energy = minf(energy_max, energy + energy_regen * dt)

	func can_fire(cost: float) -> bool:
		return energy >= cost

	func spend_energy(cost: float) -> void:
		energy = maxf(0.0, energy - cost)

	func _init(p_uid: int, p_name: String, p_team: String, p_pos: Vector3,
			loadout: Array = []) -> void:
		uid = p_uid
		ship_name = p_name
		team = p_team
		pos = p_pos
		var kinds: Array = loadout if loadout.size() == Model.SLOT_COUNT else Model.default_loadout()
		for i in Model.SLOT_COUNT:
			compartments.append(Compartment.new(
				i, kinds[i], Model.hardpoint_pos(i), Model.hardpoint_dir(i)))

	func alive() -> bool:
		for c in compartments:
			if c.alive():
				return true
		return false

	func _sum_eff(kind: int) -> float:
		var s := 0.0
		for c in compartments:
			if c.kind == kind:
				s += c.efficiency()
		return s

	func _count(kind: int) -> float:
		var n := 0.0
		for c in compartments:
			if c.kind == kind:
				n += 1.0
		return maxf(1.0, n)

	func speed() -> float:
		var base := 1.6
		var engines := _sum_eff(Model.CompType.ENGINE)
		if engines <= 0.0:
			return base * 0.15
		return base * (0.25 + 0.75 * engines / _count(Model.CompType.ENGINE))

	func crew_alive() -> int:
		var n := 0
		for c in compartments:
			n += c.crew
		return n

	func crew_capacity() -> int:
		var n := 0
		for c in compartments:
			n += c.crew_max
		return n

	func crew_ratio() -> float:
		return float(crew_alive()) / maxf(1.0, float(crew_capacity()))

	func accuracy() -> float:
		var sensors := _sum_eff(Model.CompType.SENSOR)
		var crew_eff := _sum_eff(Model.CompType.CREW)
		var base := 0.55 + 0.30 * (sensors / _count(Model.CompType.SENSOR)) \
			+ 0.15 * (crew_eff / _count(Model.CompType.CREW))
		# 人死了就打不准
		return base * (0.55 + 0.45 * crew_ratio())

	func damage_reduction() -> float:
		var shields := _sum_eff(Model.CompType.SHIELD)
		return minf(0.6, 0.6 * shields / _count(Model.CompType.SHIELD))

	func repair_rate() -> float:
		var crew_eff := _sum_eff(Model.CompType.CREW)
		return dc_rate * (0.4 + 0.6 * crew_eff / _count(Model.CompType.CREW)) \
			* (0.3 + 0.7 * crew_ratio())

	func weapons() -> Array:
		var out: Array = []
		for c in compartments:
			if Model.is_weapon(c.kind) and c.alive():
				out.append(c)
		return out

	func total_hp() -> float:
		var s := 0.0
		for c in compartments:
			s += c.hp
		return s

	func total_max_hp() -> float:
		var s := 0.0
		for c in compartments:
			s += c.max_hp()
		return s

	func hull_integrity() -> float:
		return total_hp() / maxf(1.0, total_max_hp())

	var _cached_basis := Basis.IDENTITY
	var _cached_heading := Vector3(9e9, 9e9, 9e9)

	func basis() -> Basis:
		if _cached_heading == heading:
			return _cached_basis
		var f := heading.normalized()
		var up_hint := Vector3.UP
		if absf(f.dot(up_hint)) > 0.99:
			up_hint = Vector3.BACK
		# 右手系：X = Y × Z。用 f × up 会得到左手系（行列式 -1），
		# 等于把舰体镜像，会导致两军不对称。
		var right := up_hint.cross(f).normalized()
		var up := f.cross(right).normalized()
		_cached_basis = Basis(right, up, f)
		_cached_heading = heading
		return _cached_basis

	func local_to_world(local: Vector3) -> Vector3:
		return pos + basis() * local

	func comp_world_pos(comp: Compartment) -> Vector3:
		return local_to_world(comp.local_offset())

	func dc_tick(dt: float) -> void:
		if dc_budget <= 0.0:
			return
		var target: Compartment = null
		var best_rank := 99
		var best_ratio := 2.0
		for c in compartments:
			if c.hp >= c.max_hp():
				continue
			var rank := 0 if c.state == Model.CompState.OFFLINE else 1
			var r: float = c.hp_ratio()
			if rank < best_rank or (rank == best_rank and r < best_ratio):
				best_rank = rank
				best_ratio = r
				target = c
		if target == null:
			return
		var amount: float = minf(minf(repair_rate() * dt, dc_budget), target.max_hp() - target.hp)
		if amount <= 0.0:
			return
		target.hp += amount
		dc_budget -= amount
		if target.hp >= target.max_hp():
			target.hp = target.max_hp()
			target.state = Model.CompState.ONLINE
		elif target.state == Model.CompState.OFFLINE and target.hp_ratio() >= 0.35:
			target.state = Model.CompState.DAMAGED
