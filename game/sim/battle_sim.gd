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
const WEAPON_ARC_HALF_DEG := 100.0
const BEAM_LIFE := 0.12

var ships: Array = []
var duration := 180.0
var rng := RandomNumberGenerator.new()

var t := 0.0
var events: Array = []      # {t, kind, text, team, uid, target_uid, value}
var beams: Array = []       # {a: Vector3, b: Vector3, life: float, team: String}
var over := false
var winner := ""

# 手册
var fire_band := "mid"
var focus_fire := true
var hold_range := true

var _cooldowns: Dictionary = {}   # "uid:index" -> 剩余秒
var _rngs: Dictionary = {}        # uid -> RandomNumberGenerator（每舰独立随机流）

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

	for idx in order:
		var s = ships[idx]
		if not s.alive():
			continue
		var target = pick_target(s)
		if target != null:
			turn_toward(s, target, dt)
		move_ship(s, dt)

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
	if t >= duration:
		over = true
		winner = "player" if p_alive > e_alive else ("enemy" if e_alive > p_alive else "draw")
		log_event("end", "时间到，判定：%s" % winner)

# ---------------------------------------------------------------- 目标

func pick_target(ship):
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return null
	var best_score := INF
	var tied: Array = []
	for e in enemies:
		var d: float = (e.pos - ship.pos).length()
		var score: float = d * (0.4 + e.hull_integrity()) if focus_fire else d
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

func move_ship(ship, dt: float) -> void:
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return
	var nearest = enemies[0]
	var best := INF
	for e in enemies:
		var d: float = (e.pos - ship.pos).length()
		if d < best:
			best = d
			nearest = e
	var d: float = best
	var desired_gap := 18.0 if hold_range else 10.0
	if d > desired_gap + 2.0:
		var dir: Vector3 = (nearest.pos - ship.pos).normalized()
		ship.pos += dir * ship.speed() * dt
	elif d < desired_gap - 2.0:
		var dir: Vector3 = (ship.pos - nearest.pos).normalized()
		ship.pos += dir * ship.speed() * 0.6 * dt

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

func doctrine_allows(d: float) -> bool:
	var order := {"close": 0, "mid": 1, "far": 2}
	return order[range_band(d)] <= order[fire_band]

func ship_fire(ship) -> void:
	var weapons: Array = ship.weapons()
	if weapons.is_empty():
		return
	var enemies := enemies_of(ship)
	if enemies.is_empty():
		return

	var primary = pick_target(ship)

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
		_cooldowns[key] = LASER_COOLDOWN
		fire_laser(ship, comp, target)

func weapon_can_hit(ship, comp, target) -> bool:
	var d: float = (target.pos - ship.pos).length()
	if d > LASER_MAX_RANGE:
		return false
	if not doctrine_allows(d):
		return false
	var mount_dir: Vector3 = (ship.basis() * comp.local_offset()).normalized()
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
	var d: float = (target.pos - ship.pos).length()
	var band := range_band(d)
	var acc: float = clampf(band_accuracy(band) * ship.accuracy(), 0.05, 0.98)
	var from: Vector3 = ship.comp_world_pos(comp)

	var r: RandomNumberGenerator = _rngs[ship.uid]

	if r.randf() > acc:
		# 打空：光束擦过目标旁边
		var miss_pt: Vector3 = target.pos + Vector3(
			r.randf_range(-2.0, 2.0), r.randf_range(-2.0, 2.0), r.randf_range(-2.0, 2.0))
		beams.append({"a": from, "b": miss_pt, "life": BEAM_LIFE, "team": ship.team, "hit": false})
		return

	var dmg: float = LASER_BASE_DAMAGE * band_damage(d) * r.randf_range(0.85, 1.15)
	dmg *= (1.0 - target.damage_reduction())

	var hit_comp = resolve_hit_compartment(ship, target, from, r)
	if hit_comp == null:
		return

	beams.append({"a": from, "b": target.comp_world_pos(hit_comp),
		"life": BEAM_LIFE, "team": ship.team, "hit": true})

	var before: int = hit_comp.state
	var was_breached: bool = hit_comp.breached
	var dealt: float = hit_comp.take_damage(dmg)
	stat_hits[ship.team] += 1
	stat_damage[ship.team] += dealt
	ship_dmg_dealt[ship.uid] = ship_dmg_dealt.get(ship.uid, 0.0) + dealt
	ship_dmg_taken[target.uid] = ship_dmg_taken.get(target.uid, 0.0) + dealt

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
		log_event("kill", "%s 失去战斗力" % target.ship_name, target.team, target.uid)

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
		var off: Vector3 = c.local_offset()
		if off.length() < 0.0001:
			continue
		var score: float = off.normalized().dot(local_incoming)
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
		var d_theta: float = absf(fmod(c.theta_deg - mag.theta_deg + 180.0, 360.0) - 180.0)
		var d_h: float = absf(c.h - mag.h)
		var adjacency: float = maxf(0.0, 1.0 - (d_theta / 180.0) * 0.7 - d_h * 0.3)
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
		for s in ships:
			if s.team != team:
				continue
			total += 1
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
		}
	out["time"] = snappedf(t, 0.1)
	out["winner"] = winner
	return out


# ---------------------------------------------------------------- 场景构造

static func make_battle(n_per_side: int, seed: int, loadout: Array) -> BattleSim:
	var ships: Array = []
	var uid := 0
	# 沿 Z 轴展开（深度），X 是两军间距，Y 只做少量高度差。
	# 这样从斜上方看是一张战术图，而不是一列竖排。
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
			Vector3(30.0, float(i % 3 - 1) * 0.8, off), loadout)
		e.heading = Vector3(-1, 0, 0)
		ships.append(e)
		uid += 1
	var sim := BattleSim.new(ships, seed)
	return sim
