class_name BattleSim
extends RefCounted
## EMBERFALL · 战斗推进（纯逻辑，不含渲染）
##
## - 激光严格直线：命中 = 弹道线与舱室球体求交，取最近。
## - 射界：武器只能打自己 θ 覆盖范围内的目标，所以"船怎么转"是战术问题。
## - 距离三档：远/中/近，影响命中与伤害。
## - 随机：命中掷骰、毁伤程度、殉爆范围。
## - 损管：每船有预算，战斗中缓慢修复。

const LASER_MAX_RANGE := 35.0
const LASER_MID_RANGE := 22.0
const LASER_CLOSE_RANGE := 12.0
const LASER_COOLDOWN := 1.2
const LASER_BASE_DAMAGE := 26.0
const LASER_COST := 17.0          # 每次开火消耗的能量
const WEAPON_ARC_HALF_DEG := 100.0
const BEAM_LIFE := 0.12

# ---- 三种武器的差异 ----
# 激光：全能，中近程
# 长程炮：射程远，但近距离打不了（最小射程）
# 近防炮：射速快，但只够得着很近
static func w_max_range(kind: int) -> float:
	match kind:
		Model.CompType.WEAPON_LONG:  return 55.0
		Model.CompType.WEAPON_CLOSE: return 14.0
		_:                           return 35.0

static func w_min_range(kind: int) -> float:
	match kind:
		# 长程炮在 14 以内打不了。中距手册的站位约 17.6，刚好还能开火；
		# 近距手册会把它废掉——这是"大炮不适合贴脸"的设计意图。
		Model.CompType.WEAPON_LONG: return 14.0
		_:                          return 0.0

static func w_damage(kind: int) -> float:
	match kind:
		Model.CompType.WEAPON_LONG:  return 92.0
		Model.CompType.WEAPON_CLOSE: return 20.0
		_:                           return 40.0

static func w_cooldown(kind: int) -> float:
	match kind:
		Model.CompType.WEAPON_LONG:  return 3.0
		Model.CompType.WEAPON_CLOSE: return 0.5
		_:                           return 1.2

static func w_accuracy(kind: int, band: String) -> float:
	match kind:
		Model.CompType.WEAPON_LONG:
			if band == "far": return 0.80
			if band == "mid": return 0.58
			return 0.0
		Model.CompType.WEAPON_CLOSE:
			return 0.95 if band == "close" else 0.0
		_:
			if band == "close": return 0.92
			if band == "mid": return 0.72
			return 0.40

static func w_damage_falloff(kind: int, d: float) -> float:
	match kind:
		Model.CompType.WEAPON_LONG:
			return 1.0 if d > LASER_MID_RANGE else 0.85
		Model.CompType.WEAPON_CLOSE:
			return 1.0 if d <= LASER_CLOSE_RANGE else 0.5
		_:
			if d <= LASER_CLOSE_RANGE: return 1.0
			if d <= LASER_MID_RANGE: return 0.78
			return 0.45

var ships: Array = []
var duration := 180.0
var rng := RandomNumberGenerator.new()

var t := 0.0
var events: Array = []      # {t, kind, text, team, uid, target_uid, value}
var beams: Array = []       # {a: Vector3, b: Vector3, life: float, team: String}
var over := false
var winner := ""

# 战斗手册：双方各一本。玩家在配船时定自己的，敌方由 AI 预设。
# band: close / mid / far（想在哪打，决定站位）；focus: 是否集火残血。
# 注意：手册不剥夺开火权，只影响站位。否则射程优势会变成单方面挨打。
var doctrine := {
	"player": {"band": "mid", "focus": false},
	"enemy": {"band": "mid", "focus": false},
}

var _cooldowns: Dictionary = {}   # "uid:index" -> 剩余秒
var _rngs: Dictionary = {}        # uid -> RandomNumberGenerator（每舰独立随机流）
var _assignments: Dictionary = {} # uid -> 本步分配的目标（避免重复打同一个）

# 失压抛人事件：给表现层用，只负责"哪里、多少人"，逻辑层不关心怎么画。
var ejections: Array = []

# 诊断计数器：排查两军不对称用
var stat_shots := {"player": 0, "enemy": 0}
var stat_hits := {"player": 0, "enemy": 0}
var stat_damage := {"player": 0.0, "enemy": 0.0}

# 逐舰统计
var ship_shots := {}      # uid -> int
var ship_dmg_dealt := {}  # uid -> float
var ship_dmg_taken := {}  # uid -> float
var ship_kills := {}      # uid -> int

# 僵持检测：最近一次造成伤害的时刻
var last_damage_t := 0.0

# 按武器类型统计开火次数（调平衡用）
var shots_by_kind := {}

# 归因：每方"损失来自哪类舱室"
var dmg_by_comp := {"player": {}, "enemy": {}}

func _init(p_ships: Array, p_seed: int = 12345) -> void:
	ships = p_ships
	rng.seed = p_seed
	# 预热：连续整数种子在某些 RNG 上，开头若干随机数相关性偏强。
	# 初始冷却又是按"玩家先、敌人后"顺序赋值的，伪相关会直接变成阵营偏差。
	# 先丢弃一批随机数，切断种子值与首批赋值之间的关系。
	for _i in 32:
		rng.randf()

	for s in ships:
		# 每艘船一条独立随机流：否则"谁先取数"会随数组顺序变化，
		# 在多舰混战里会把顺序变成系统性优势。
		var r := RandomNumberGenerator.new()
		r.seed = hash("%d:%d" % [p_seed, s.uid])
		_rngs[s.uid] = r
		for c in s.weapons():
			_cooldowns["%d:%d" % [s.uid, c.index]] = r.randf_range(0.0, LASER_COOLDOWN)

# ---------------------------------------------------------------- 查询

func enemies_of(ship) -> Array:
	var out: Array = []
	for s in ships:
		if s.team != ship.team and s.alive():
			out.append(s)
	return out

func team_alive(team: String) -> int:
	var n := 0
	for s in ships:
		if s.team == team and s.alive():
			n += 1
	return n

func log_event(kind: String, text: String, team := "", uid := -1,
		target_uid := -1, value := 0.0) -> void:
	events.append({
		"t": snappedf(t, 0.01), "kind": kind, "text": text,
		"team": team, "uid": uid, "target_uid": target_uid, "value": value,
	})

# ---------------------------------------------------------------- 主循环

func step(dt: float) -> void:
	if over:
		return
	t += dt

	for s in ships:
		if s.alive():
			s.dc_tick(dt)

	# 打乱行动顺序：否则数组靠前的阵营每一帧都先开火，会形成系统性优势。
	var order: Array = []
	for i in ships.size():
		order.append(i)
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp

	# 目标分配：先统一分配，再让所有舰按同一份分配去移动和开火。
	# 否则"移动追一个目标、开火打另一个目标"会让阵型散掉。
	_assignments = {}
	for team in ["player", "enemy"]:
		var a := assign_targets(team)
		for k in a.keys():
			_assignments[k] = a[k]

	for idx in order:
		var s = ships[idx]
		if not s.alive():
			continue
		# 移动永远朝最近的敌人：集火只影响"打谁"，不该让整队挤向同一个点。
		var mv = nearest_enemy(s)
		if mv != null:
			turn_toward(s, mv, dt)
		move_ship(s, dt, mv)

	for idx in order:
		var s = ships[idx]
		if s.alive():
			ship_fire(s)

	# 冷却
	for key in _cooldowns.keys():
		_cooldowns[key] -= dt
		if _cooldowns[key] <= 0.0:
			_cooldowns.erase(key)

	# 光束寿命
	for i in range(beams.size() - 1, -1, -1):
		beams[i]["life"] -= dt
		if beams[i]["life"] <= 0.0:
			beams.remove_at(i)

	# 结束判定必须同时看两方：否则"同归于尽"会被判成敌方获胜，
	# 在多舰混战里这会形成系统性偏差。
	var p_alive := team_alive("player")
	var e_alive := team_alive("enemy")
	if p_alive == 0 or e_alive == 0:
		over = true
		if p_alive == 0 and e_alive == 0:
			winner = "draw"
			log_event("end", "两败俱伤")
		elif p_alive == 0:
			winner = "enemy"
			log_event("end", "敌方获胜", "enemy")
		else:
			winner = "player"
			log_event("end", "我方获胜", "player")
		return
	# 僵持：长时间没有有效交火（多半是残存舰互相够不着），按剩余结构判定。
	if t > 40.0 and t - last_damage_t > 20.0:
		over = true
		winner = _decide_by_hull()
		log_event("end", "长时间无交火，按剩余结构判定：%s" % winner)
		return
	if t >= duration:
		over = true
		winner = _decide_by_hull()
		log_event("end", "时间到，判定：%s" % winner)

## 先比存活舰数，再比剩余结构；都接近才算平局。
func _decide_by_hull() -> String:
	var p_alive := team_alive("player")
	var e_alive := team_alive("enemy")
	if p_alive != e_alive:
		return "player" if p_alive > e_alive else "enemy"
	var ph := 0.0
	var eh := 0.0
	for s in ships:
		if not s.alive():
			continue
		if s.team == "player":
			ph += s.hull_integrity()
		else:
			eh += s.hull_integrity()
	if absf(ph - eh) < 0.08:
		return "draw"
	return "player" if ph > eh else "enemy"

# ---------------------------------------------------------------- 目标

## 本步的目标分配：同一轮里避免多舰重复攻击同一个目标（伤害溢出）。
## 集火手册（focus=true）则故意不避让——那是玩家的选择，代价是浪费。
func assign_targets(team: String) -> Dictionary:
	var allied: Array = []
	for s in ships:
		if s.team == team and s.alive():
			allied.append(s)

	var crowd := {}   # 已被分配的目标 -> 数量
	var out := {}     # ship.uid -> target
	var focus_on: bool = doctrine[team]["focus"]

	for s in allied:
		var enemies := enemies_of(s)
		if enemies.is_empty():
			continue
		var best = null
		var best_score := INF
		for e in enemies:
			var d: float = (e.pos - s.pos).length()
			var score: float
			if focus_on:
				# 集火：优先打最虚弱的
				score = d * (0.4 + e.hull_integrity())
			else:
				# 分布式：已经在挨打的目标，优先级递减
				var n: int = crowd.get(e.uid, 0)
				score = d * (0.5 + e.hull_integrity()) * (1.0 + 0.9 * n)
			# 打不到的目标大幅降权，避免全队追着一个够不着的目标跑
			if not can_engage(s, e):
				score *= 4.0
			if score < best_score:
				best_score = score
				best = e
		if best != null:
			out[s.uid] = best
			crowd[best.uid] = crowd.get(best.uid, 0) + 1
	return out

## 这艘船有没有任何一件武器能打到该目标（射程 + 最小射程 + 射界）。
func can_engage(ship, target) -> bool:
	for c in ship.weapons():
		if weapon_can_hit(ship, c, target):
			return true
	return false

func pick_target(ship):
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return null
	var best_score := INF
	var tied: Array = []
	for e in enemies:
		var d: float = (e.pos - ship.pos).length()
		var focus_on: bool = doctrine[ship.team]["focus"]
		var score: float = d * (0.4 + e.hull_integrity()) if focus_on else d
		if score < best_score - 0.001:
			best_score = score
			tied = [e]
		elif absf(score - best_score) <= 0.001:
			tied.append(e)
	if tied.size() == 1:
		return tied[0]
	# 同分时随机：否则"数组里靠前的目标"会变成隐形偏好，
	# 在多舰混战里形成系统性偏差。
	var r: RandomNumberGenerator = _rngs[ship.uid]
	return tied[r.randi_range(0, tied.size() - 1)]

## 最近的敌人（只管移动，不管开火）。
func nearest_enemy(ship):
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return null
	var best = enemies[0]
	var best_d := INF
	for e in enemies:
		var d: float = (e.pos - ship.pos).length()
		if d < best_d:
			best_d = d
			best = e
	return best

func turn_toward(ship, target, dt: float) -> void:
	var desired: Vector3 = (target.pos - ship.pos).normalized()
	var cur: Vector3 = ship.heading.normalized()
	var max_turn := deg_to_rad(25.0) * dt
	var ang := cur.angle_to(desired)
	if ang <= max_turn or ang < 1e-6:
		ship.heading = desired
	else:
		var axis := cur.cross(desired)
		if axis.length() < 1e-6:
			return
		ship.heading = cur.rotated(axis.normalized(), max_turn)

func move_ship(ship, dt: float, assigned = null) -> void:
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return
	# 优先朝"被分配的目标"移动；没有分配时退回最近的敌人。
	var target = assigned
	if target == null or not target.alive():
		target = enemies[0]
		var best := INF
		for e in enemies:
			var dd: float = (e.pos - ship.pos).length()
			if dd < best:
				best = dd
				target = e
	var d: float = (target.pos - ship.pos).length()
	# 想站在"手册允许范围的 80%"处，舰长按性格上下浮动。
	var desired_gap := doctrine_max_range(ship.team) * 0.8
	if ship.captain != null:
		desired_gap *= ship.captain.gap_mult()
	desired_gap = clampf(desired_gap, 6.0, 50.0)
	# 只前进或驻守，不后退。
	# 若允许后退，长程舰可以一直风筝，同速下永远追不上，平衡会塌。
	if d > desired_gap + 2.0:
		var dir: Vector3 = (target.pos - ship.pos).normalized()
		ship.pos += dir * ship.speed() * dt

func doctrine_max_range(team: String) -> float:
	match doctrine[team]["band"]:
		"close": return LASER_CLOSE_RANGE
		"far":   return 55.0
		_:       return LASER_MID_RANGE

# ---------------------------------------------------------------- 开火

func range_band(d: float) -> String:
	if d <= LASER_CLOSE_RANGE:
		return "close"
	if d <= LASER_MID_RANGE:
		return "mid"
	return "far"

func band_accuracy(band: String) -> float:
	match band:
		"close": return 0.92
		"mid":   return 0.72
		"far":   return 0.40
	return 0.5

func band_damage(d: float) -> float:
	if d <= LASER_CLOSE_RANGE:
		return 1.0
	if d <= LASER_MID_RANGE:
		return 0.78
	return 0.45

func doctrine_allows(d: float, team: String) -> bool:
	var order := {"close": 0, "mid": 1, "far": 2}
	return order[range_band(d)] <= order[doctrine[team]["band"]]

func ship_fire(ship) -> void:
	var weapons: Array = ship.weapons()
	if weapons.is_empty():
		return
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return

	var primary = _assignments.get(ship.uid, null)
	if primary == null:
		primary = pick_target(ship)

	for comp in weapons:
		var key := "%d:%d" % [ship.uid, comp.index]
		if _cooldowns.has(key):
			continue
		var target = null
		if primary != null and weapon_can_hit(ship, comp, primary):
			target = primary
		else:
			target = pick_weapon_target(ship, comp, enemies)
		if target == null:
			continue
		_cooldowns[key] = w_cooldown(comp.kind)
		fire_laser(ship, comp, target)

func weapon_can_hit(ship, comp, target) -> bool:
	var d: float = (target.pos - ship.pos).length()
	# 每种武器有自己的射程与最小射程：
	# 长程炮在 14 以内打不了，近防炮在 14 以外够不着。
	# 注意：手册不限制开火——手册只决定"想站多远"，不能剥夺还击能力，
	# 否则射程优势会变成单方面挨打，平衡直接崩掉。
	if d > w_max_range(comp.kind):
		return false
	if d < w_min_range(comp.kind):
		return false
	var mount_dir: Vector3 = (ship.basis() * comp.dir).normalized()
	var to_target: Vector3 = (target.pos - ship.pos).normalized()
	return rad_to_deg(mount_dir.angle_to(to_target)) <= WEAPON_ARC_HALF_DEG

func pick_weapon_target(ship, comp, enemies: Array):
	var best = null
	var best_d := INF
	for e in enemies:
		if not weapon_can_hit(ship, comp, e):
			continue
		var d: float = (e.pos - ship.pos).length()
		if d < best_d:
			best_d = d
			best = e
	return best

func fire_laser(ship, comp, target) -> void:
	stat_shots[ship.team] += 1
	ship_shots[ship.uid] = ship_shots.get(ship.uid, 0) + 1
	var kind_name: String = Model.comp_name(comp.kind)
	shots_by_kind[kind_name] = shots_by_kind.get(kind_name, 0) + 1
	var d: float = (target.pos - ship.pos).length()
	var band := range_band(d)
	# 每个武器舱按自己的类型算命中与伤害
	var acc: float = w_accuracy(comp.kind, band) * ship.accuracy()
	if ship.captain != null:
		acc *= ship.captain.accuracy_mod()
	acc = clampf(acc, 0.03, 0.98)
	var from: Vector3 = ship.comp_world_pos(comp)

	var r: RandomNumberGenerator = _rngs[ship.uid]

	if r.randf() > acc:
		# 打空：光束擦过目标旁边
		var miss_pt: Vector3 = target.pos + Vector3(
			r.randf_range(-2.0, 2.0), r.randf_range(-2.0, 2.0), r.randf_range(-2.0, 2.0))
		beams.append({"a": from, "b": miss_pt, "life": BEAM_LIFE, "team": ship.team, "hit": false})
		return

	var dmg: float = w_damage(comp.kind) * w_damage_falloff(comp.kind, d) * r.randf_range(0.85, 1.15)
	# 集火 = 集中火控：命中同一目标时打得更狠，但会有大量溢出。
	# 用伤害加成去抵消溢出浪费，让"集火 / 自由射击"成为一个真选择。
	if doctrine[ship.team]["focus"]:
		dmg *= 1.45
	dmg *= (1.0 - target.damage_reduction())

	var hit_comp = resolve_hit_compartment(ship, target, from, r)
	if hit_comp == null:
		return

	beams.append({"a": from, "b": target.comp_world_pos(hit_comp),
		"life": BEAM_LIFE, "team": ship.team, "hit": true})

	var before: int = hit_comp.state
	var was_breached: bool = hit_comp.breached
	var dealt: float = hit_comp.take_damage(dmg)
	if dealt > 0.0:
		last_damage_t = t
	stat_hits[ship.team] += 1
	stat_damage[ship.team] += dealt
	ship_dmg_dealt[ship.uid] = ship_dmg_dealt.get(ship.uid, 0.0) + dealt
	ship_dmg_taken[target.uid] = ship_dmg_taken.get(target.uid, 0.0) + dealt
	var bucket: Dictionary = dmg_by_comp[target.team]
	var cname: String = Model.comp_name(hit_comp.kind)
	bucket[cname] = bucket.get(cname, 0.0) + dealt

	# 失压：船员被抛出（表现层会用这个位置生成飞出去的小人）
	if hit_comp.breached and not was_breached:
		ejections.append({
			"pos": target.comp_world_pos(hit_comp),
			"count": hit_comp.crew_max,
			"team": target.team,
			"t": t,
		})

	if hit_comp.state == Model.CompState.OFFLINE and before != Model.CompState.OFFLINE:
		log_event("crit", "%s 的%s停转" % [target.ship_name, Model.comp_name(hit_comp.kind)],
			target.team, target.uid, -1, dealt)
		if hit_comp.kind == Model.CompType.MAGAZINE:
			explode_magazine(target, hit_comp)
	elif dealt > 0.0:
		log_event("hit", "%s 命中 %s 的%s（%.0f）" % [ship.ship_name, target.ship_name,
			Model.comp_name(hit_comp.kind), dealt], ship.team, ship.uid, target.uid, dealt)

	if not target.alive():
		ship_kills[ship.uid] = ship_kills.get(ship.uid, 0) + 1
		log_event("kill", "%s 失去战斗力（%s 的战果）" % [target.ship_name, ship.ship_name],
			target.team, target.uid)

func resolve_hit_compartment(shooter, target, origin: Vector3, r: RandomNumberGenerator):
	# 在"目标自身坐标系"里判定：谁的朝向最接近来袭方向，谁挨打。
	# 这样构造上左右对称，不会因为两军朝向相反产生系统性偏差。
	var to_target: Vector3 = (target.pos - origin).normalized()
	var local_incoming: Vector3 = (target.basis().inverse() * (-to_target)).normalized()

	# 小角度抖动：同一位置不会每次都命中同一个舱室
	var jitter := deg_to_rad(r.randf_range(-12.0, 12.0))
	local_incoming = local_incoming.rotated(Vector3.UP, jitter)

	var best = null
	var best_score := -2.0
	for c in target.compartments:
		if not c.alive():
			continue
		# 用装甲面朝向判定：谁的面朝向来袭方向，谁挨打
		var score: float = c.dir.dot(local_incoming)
		if score > best_score:
			best_score = score
			best = c
	if best != null:
		return best
	for c in target.compartments:
		if c.alive():
			return c
	return null

func explode_magazine(ship, mag) -> void:
	var base := 45.0
	log_event("crit", "%s 的弹药库殉爆！" % ship.ship_name, ship.team, ship.uid, -1, base)
	for c in ship.compartments:
		if c == mag or not c.alive():
			continue
		# 按舰体局部坐标的实际距离算波及：越近越惨
		var dist: float = (c.local_pos - mag.local_pos).length()
		var adjacency: float = maxf(0.0, 1.0 - dist / 2.6)
		if adjacency <= 0.05:
			continue
		var was_breached: bool = c.breached
		c.take_damage(base * adjacency)
		if c.breached and not was_breached:
			ejections.append({
				"pos": ship.comp_world_pos(c),
				"count": c.crew_max,
				"team": ship.team,
				"t": t,
			})
		if c.state == Model.CompState.OFFLINE:
			log_event("crit", "殉爆波及%s，停转" % Model.comp_name(c.kind), ship.team, ship.uid)

# ---------------------------------------------------------------- 汇总

func summary() -> Dictionary:
	var out := {}
	for team in ["player", "enemy"]:
		var total := 0
		var survived := 0
		var hull_sum := 0.0
		var comps := {}
		var crew_lost := 0
		var crew_left := 0
		var captains: Array = []
		var top_killer := ""
		var top_kills := 0
		for s in ships:
			if s.team != team:
				continue
			total += 1
			if s.captain != null:
				captains.append(s.captain.label())
			var k: int = ship_kills.get(s.uid, 0)
			if k > top_kills:
				top_kills = k
				top_killer = s.ship_name
			if s.alive():
				survived += 1
				hull_sum += s.hull_integrity()
			crew_lost += s.crew_capacity() - s.crew_alive()
			crew_left += s.crew_alive()
			for c in s.compartments:
				if c.state == Model.CompState.OFFLINE:
					var n: String = Model.comp_name(c.kind)
					comps[n] = comps.get(n, 0) + 1
		out[team] = {
			"total": total,
			"survived": survived,
			"lost": total - survived,
			"avg_hull": hull_sum / maxf(1.0, float(survived)),
			"comps": comps,
			"crew_lost": crew_lost,
			"crew_left": crew_left,
			"captains": captains,
			"dmg_by_comp": dmg_by_comp[team].duplicate(),
			"top_killer": top_killer,
			"top_kills": top_kills,
		}
	out["time"] = snappedf(t, 0.1)
	out["winner"] = winner
	out["doctrine"] = doctrine.duplicate(true)
	return out


# ---------------------------------------------------------------- 场景构造

static func make_battle(n_per_side: int, seed: int, loadout: Array,
		doctrine: Dictionary = {}) -> BattleSim:
	var ships: Array = []
	var uid := 0
	# 沿 Z 轴展开（深度），X 是两军间距，Y 做少量高度差。
	# 敌方 z 取反：让两队阵型正好是 180° 旋转关系，避免手性不对称。
	for i in n_per_side:
		var off := (float(i) - (n_per_side - 1) / 2.0) * 4.0
		var p := Model.ShipModel.new(uid, "P-%02d" % (i + 1), "player",
			Vector3(-30.0, float(i % 3 - 1) * 0.8, off), loadout)
		p.heading = Vector3(1, 0, 0)
		ships.append(p)
		uid += 1
	for i in n_per_side:
		var off := (float(i) - (n_per_side - 1) / 2.0) * 4.0
		var e := Model.ShipModel.new(uid, "E-%02d" % (i + 1), "enemy",
			Vector3(30.0, float(i % 3 - 1) * 0.8, -off), loadout)
		e.heading = Vector3(-1, 0, 0)
		ships.append(e)
		uid += 1

	# 舰长是随机的，玩家不能指定——只能通过手册约束他们。
	# 名字从池里不重复分配；性格用每舰独立种子，避免"玩家先抽、敌人后抽"的偏差。
	var pool: Array = Model.CAPTAIN_NAMES.duplicate()
	var nrng := RandomNumberGenerator.new()
	nrng.seed = hash("%d:names" % seed)
	for i in range(pool.size() - 1, 0, -1):
		var j := nrng.randi_range(0, i)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp

	var name_idx := 0
	for s in ships:
		var crng := RandomNumberGenerator.new()
		crng.seed = hash("%d:captain:%d" % [seed, s.uid])
		var pers: int = [Model.CapType.AGGRESSIVE, Model.CapType.STEADY, Model.CapType.CAUTIOUS][crng.randi_range(0, 2)]
		var nm: String = pool[name_idx % pool.size()]
		name_idx += 1
		s.captain = Model.Captain.new(nm, pers)

	var sim := BattleSim.new(ships, seed)
	# 玩家的手册来自配船界面；敌方用传入的 AI 手册（默认中距 + 集火）。
	if doctrine.has("fire_band"):
		sim.doctrine["player"]["band"] = doctrine["fire_band"]
	if doctrine.has("focus_fire"):
		sim.doctrine["player"]["focus"] = doctrine["focus_fire"]
	if doctrine.has("enemy_band"):
		sim.doctrine["enemy"]["band"] = doctrine["enemy_band"]
	if doctrine.has("enemy_focus"):
		sim.doctrine["enemy"]["focus"] = doctrine["enemy_focus"]
	return sim
