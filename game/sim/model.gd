class_name Model
extends RefCounted
## EMBERFALL · 数据模型
##
## 规则对应：
## - 舰船是圆柱体，动力仓在中轴，舱室绕轴分布，坐标为 (theta, h)。
## - 战斗是三维的，舰船有三维位置与朝向。
## - 舱室有独立生命值，受损降效，归零停转。
## - 损管有预算，战斗中缓慢修复。

enum CompType { WEAPON, MAGAZINE, CREW, ENGINE, SHIELD, SENSOR }
enum CompState { ONLINE, DAMAGED, OFFLINE }
enum CapType { AGGRESSIVE, STEADY, CAUTIOUS }

const HULL_RADIUS := 1.15
const SLOT_COUNT := 10

# 每种舱室的固有属性。第一版基线。
static func comp_max_hp(kind: int) -> float:
	match kind:
		CompType.WEAPON:   return 60.0
		CompType.MAGAZINE: return 45.0
		CompType.CREW:     return 40.0
		CompType.ENGINE:   return 70.0
		CompType.SHIELD:   return 55.0
		CompType.SENSOR:   return 35.0
	return 50.0

static func comp_armor(kind: int) -> float:
	match kind:
		CompType.WEAPON:   return 2.0
		CompType.MAGAZINE: return 1.0
		CompType.CREW:     return 1.0
		CompType.ENGINE:   return 2.0
		CompType.SHIELD:   return 3.0
		CompType.SENSOR:   return 1.0
	return 1.0

static func comp_radius(kind: int) -> float:
	match kind:
		CompType.WEAPON:   return 0.55
		CompType.MAGAZINE: return 0.50
		CompType.CREW:     return 0.45
		CompType.ENGINE:   return 0.60
		CompType.SHIELD:   return 0.55
		CompType.SENSOR:   return 0.40
	return 0.5

static func comp_crew(kind: int) -> int:
	match kind:
		CompType.WEAPON:   return 6
		CompType.MAGAZINE: return 4
		CompType.CREW:     return 10
		CompType.ENGINE:   return 5
		CompType.SHIELD:   return 4
		CompType.SENSOR:   return 3
	return 4

static func comp_name(kind: int) -> String:
	match kind:
		CompType.WEAPON:   return "武器舱"
		CompType.MAGAZINE: return "弹药库"
		CompType.CREW:     return "人员宿舍"
		CompType.ENGINE:   return "引擎"
		CompType.SHIELD:   return "护盾发生器"
		CompType.SENSOR:   return "传感器"
	return "舱室"

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
		CompType.WEAPON:   return Color(0.95, 0.35, 0.30)
		CompType.MAGAZINE: return Color(0.95, 0.75, 0.25)
		CompType.CREW:     return Color(0.45, 0.80, 0.55)
		CompType.ENGINE:   return Color(0.35, 0.65, 0.95)
		CompType.SHIELD:   return Color(0.65, 0.50, 0.95)
		CompType.SENSOR:   return Color(0.55, 0.85, 0.90)
	return Color.WHITE

# 槽位几何：两圈，每圈 5 个，绕中轴均布。
static func slot_theta(i: int) -> float:
	return fmod(float(i) * 72.0, 360.0)

static func slot_h(i: int) -> float:
	return 1.0 if i < 5 else -1.0

# 默认装配：2 武器 + 2 弹药 + 3 引擎 + 2 护盾 + 1 传感器
static func default_loadout() -> Array:
	return [
		CompType.WEAPON, CompType.WEAPON, CompType.MAGAZINE, CompType.MAGAZINE,
		CompType.ENGINE, CompType.ENGINE, CompType.ENGINE,
		CompType.SHIELD, CompType.SHIELD, CompType.SENSOR,
	]


class Compartment:
	var index: int
	var kind: int
	var theta_deg: float
	var h: float
	var radius: float
	var hp: float
	var armor: float
	var state: int = Model.CompState.ONLINE

	# 船员：每个舱室有自己的编制。玩家不能操作他们，只能看他们干活和死。
	var crew: int = 0
	var crew_max: int = 0
	var breached: bool = false      # 是否已失压（被击穿，人会飞出去）

	func _init(p_index: int, p_kind: int) -> void:
		index = p_index
		kind = p_kind
		theta_deg = Model.slot_theta(p_index)
		h = Model.slot_h(p_index)
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
		var rad := deg_to_rad(theta_deg)
		return Vector3(Model.HULL_RADIUS * cos(rad), Model.HULL_RADIUS * sin(rad), h)


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

	func _init(p_uid: int, p_name: String, p_team: String, p_pos: Vector3,
			loadout: Array = []) -> void:
		uid = p_uid
		ship_name = p_name
		team = p_team
		pos = p_pos
		var kinds: Array = loadout if loadout.size() == Model.SLOT_COUNT else Model.default_loadout()
		for i in Model.SLOT_COUNT:
			compartments.append(Compartment.new(i, kinds[i]))

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
			if c.kind == Model.CompType.WEAPON and c.alive():
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
