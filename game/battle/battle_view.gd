extends Node3D
## 战斗画面：跑模拟 + 画出来。玩家不能指挥，只能看。
##
## 表现层分三块：
## 1) 舰体与舱室：方块，颜色随状态变化
## 2) 船员：小人，在自己的舱室附近跑动、修理、操作武器
## 3) 失压：舱室被击穿时，船员被抛到太空里
##
## 镜头：滚轮缩放，点击舰船跟随。靠近才能看清船员。

signal finished(summary: Dictionary)

const FIXED_DT := 0.05
const SHIPS_PER_SIDE := 6
const CREW_PER_SHIP := 12
const CREW_SPEED := 2.4
const MIN_DIST := 16.0
const MAX_DIST := 150.0

var loadout: Array = []
var doctrine: Dictionary = {}
var sim: BattleSim
var paused := false
var speed_scale := 1.0
var accum := 0.0
var _result_shown := false
var _finished_emitted := false

var ship_nodes: Dictionary = {}      # uid -> Node3D
var comp_mats: Dictionary = {}       # "uid:index" -> StandardMaterial3D
var crew_units: Dictionary = {}      # uid -> Array[Dictionary]
var flying_crew: Array = []          # {node, vel, spin, life}
var beam_mesh: ImmediateMesh

var cam: Camera3D
var cam_dist := 40.0
var cam_target := Vector3.ZERO
var follow_uid := -1

var time_label: Label
var log_label: Label
var result_layer: Control
var _pause_btn: Button
var _speed_btn: Button
var crew_label: Label

func _ready() -> void:
	_setup_world()
	sim = BattleSim.make_battle(SHIPS_PER_SIDE, randi(), loadout, doctrine)
	_build_ships()
	_build_hud()
	_apply_camera()

func _setup_world() -> void:
	cam = Camera3D.new()
	cam.fov = 50.0
	add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.25
	add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.03, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.32, 0.36, 0.44)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)

	beam_mesh = ImmediateMesh.new()
	var beam_node := MeshInstance3D.new()
	beam_node.mesh = beam_mesh
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.vertex_color_use_as_albedo = true
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_node.material_override = bm
	add_child(beam_node)

func _build_ships() -> void:
	for ship in sim.ships:
		var node := Node3D.new()
		node.position = ship.pos
		node.transform.basis = ship.basis()
		add_child(node)

		var hull := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(2.6, 1.0, 4.4)
		hull.mesh = box
		var hm := StandardMaterial3D.new()
		hm.albedo_color = Color(0.22, 0.32, 0.48) if ship.team == "player" else Color(0.48, 0.22, 0.22)
		hm.metallic = 0.3
		hm.roughness = 0.55
		hull.material_override = hm
		node.add_child(hull)

		for comp in ship.compartments:
			var cm := MeshInstance3D.new()
			var cb := BoxMesh.new()
			cb.size = Vector3(0.9, 0.9, 0.9)
			cm.mesh = cb
			cm.position = comp.local_offset()
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Model.comp_color(comp.kind)
			mat.emission_enabled = true
			mat.emission = Model.comp_color(comp.kind) * 0.25
			cm.material_override = mat
			node.add_child(cm)
			comp_mats["%d:%d" % [ship.uid, comp.index]] = mat

		_build_crew_for(node, ship)
		ship_nodes[ship.uid] = node

func _build_crew_for(ship_node: Node3D, ship) -> void:
	var units: Array = []
	var total_crew := maxi(1, ship.crew_capacity())
	for i in CREW_PER_SHIP:
		# 按编制比例分配到舱室
		var pick := int(float(i) / float(CREW_PER_SHIP) * float(ship.compartments.size()))
		var comp = ship.compartments[mini(pick, ship.compartments.size() - 1)]

		var fig := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.11
		capsule.height = 0.52
		fig.mesh = capsule
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.85, 0.93, 1.0) if ship.team == "player" else Color(1.0, 0.86, 0.82)
		mat.emission_enabled = true
		mat.emission = mat.albedo_color * 0.6
		fig.material_override = mat
		fig.position = comp.local_offset()
		ship_node.add_child(fig)

		units.append({
			"node": fig,
			"comp_index": comp.index,
			"target": comp.local_offset(),
			"timer": randf_range(0.2, 1.6),
			"base": comp.local_offset(),
		})
	crew_units[ship.uid] = units

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := ColorRect.new()
	top.color = Color(0, 0, 0, 0.45)
	top.size = Vector2(1600, 54)
	layer.add_child(top)

	time_label = Label.new()
	time_label.position = Vector2(24, 12)
	time_label.add_theme_font_size_override("font_size", 19)
	time_label.add_theme_color_override("font_color", Color(0.90, 0.93, 0.97))
	layer.add_child(time_label)

	crew_label = Label.new()
	crew_label.position = Vector2(620, 14)
	crew_label.add_theme_font_size_override("font_size", 15)
	crew_label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95))
	layer.add_child(crew_label)

	var pause_btn := Button.new()
	pause_btn.text = "暂停"
	pause_btn.position = Vector2(1280, 10)
	pause_btn.size = Vector2(86, 34)
	pause_btn.pressed.connect(_toggle_pause)
	layer.add_child(pause_btn)
	_pause_btn = pause_btn

	var speed_btn := Button.new()
	speed_btn.text = "1×"
	speed_btn.position = Vector2(1372, 10)
	speed_btn.size = Vector2(64, 34)
	speed_btn.pressed.connect(_cycle_speed)
	layer.add_child(speed_btn)
	_speed_btn = speed_btn

	var back_btn := Button.new()
	back_btn.text = "返回配船"
	back_btn.position = Vector2(1442, 10)
	back_btn.size = Vector2(140, 34)
	back_btn.pressed.connect(func(): finished.emit({}))
	layer.add_child(back_btn)

	log_label = Label.new()
	log_label.position = Vector2(24, 780)
	log_label.size = Vector2(1020, 100)
	log_label.add_theme_font_size_override("font_size", 15)
	log_label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	layer.add_child(log_label)

	var hint := Label.new()
	hint.text = "滚轮缩放 · 点击舰船跟随 · 空格暂停"
	hint.position = Vector2(24, 758)
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.45, 0.50, 0.58))
	layer.add_child(hint)

func _toggle_pause() -> void:
	paused = not paused
	if _pause_btn != null:
		_pause_btn.text = "继续" if paused else "暂停"

func _cycle_speed() -> void:
	if speed_scale < 1.5:
		speed_scale = 2.0
	elif speed_scale < 3.0:
		speed_scale = 4.0
	else:
		speed_scale = 1.0
	if _speed_btn != null:
		_speed_btn.text = "%d×" % int(speed_scale)

# ---------------------------------------------------------------- 镜头

func _apply_camera() -> void:
	if cam == null:
		return
	var dir := Vector3(0, 0.78, -0.63).normalized()
	cam.position = cam_target + dir * cam_dist
	cam.look_at(cam_target)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = clampf(cam_dist * 0.86, MIN_DIST, MAX_DIST)
			_apply_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = clampf(cam_dist * 1.16, MIN_DIST, MAX_DIST)
			_apply_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var picked = _pick_ship(event.position)
			if picked != null:
				follow_uid = picked.uid
				cam_target = picked.pos
				cam_dist = clampf(cam_dist, MIN_DIST, 30.0)
				_apply_camera()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_toggle_pause()

func _pick_ship(screen_pos: Vector2):
	if cam == null:
		return null
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var best = null
	var best_t := INF
	for ship in sim.ships:
		if not ship.alive():
			continue
		var center: Vector3 = ship.pos
		var to_c: Vector3 = center - origin
		var t: float = to_c.dot(dir)
		if t < 0.0:
			continue
		var closest: Vector3 = origin + dir * t
		if (center - closest).length() <= 3.2 and t < best_t:
			best_t = t
			best = ship
	return best

# ---------------------------------------------------------------- 主循环

func _process(delta: float) -> void:
	if sim == null:
		return
	if not paused and not sim.over:
		accum += delta * speed_scale
		var steps := 0
		while accum >= FIXED_DT and steps < 10:
			sim.step(FIXED_DT)
			accum -= FIXED_DT
			steps += 1

	_sync_ships()
	_update_crew(delta)
	_update_flying_crew(delta)
	_drain_ejections()
	_update_camera_follow()
	_sync_beams()
	_update_hud()

	if sim.over and not _result_shown:
		_show_result()

func _sync_ships() -> void:
	for ship in sim.ships:
		var node: Node3D = ship_nodes.get(ship.uid)
		if node == null:
			continue
		node.position = ship.pos
		node.transform.basis = ship.basis()
		node.visible = ship.alive()
		for comp in ship.compartments:
			var mat: StandardMaterial3D = comp_mats.get("%d:%d" % [ship.uid, comp.index])
			if mat == null:
				continue
			if comp.state == Model.CompState.OFFLINE:
				mat.albedo_color = Color(0.08, 0.08, 0.10)
				mat.emission = Color(0, 0, 0)
			elif comp.state == Model.CompState.DAMAGED:
				mat.albedo_color = Color(0.85, 0.45, 0.15)
				mat.emission = Color(0.65, 0.22, 0.0) * 0.55
			else:
				mat.albedo_color = Model.comp_color(comp.kind)
				mat.emission = Model.comp_color(comp.kind) * 0.25

# ---------------------------------------------------------------- 船员

func _update_crew(delta: float) -> void:
	for ship in sim.ships:
		var units: Array = crew_units.get(ship.uid, [])
		if units.is_empty():
			continue
		var alive: bool = ship.alive() and ship.crew_alive() > 0
		for u in units:
			var fig: MeshInstance3D = u["node"]
			if not alive:
				fig.visible = false
				continue
			fig.visible = true
			u["timer"] -= delta * speed_scale
			if u["timer"] <= 0.0:
				u["timer"] = randf_range(0.8, 2.2)
				u["target"] = _pick_crew_target(ship, u)

			var target: Vector3 = u["target"]
			var cur: Vector3 = fig.position
			var d: Vector3 = target - cur
			if d.length() > 0.04:
				fig.position = cur + d.normalized() * minf(CREW_SPEED * delta * speed_scale, d.length())
			else:
				# 到了就原地小幅晃动，像在干活
				fig.position = cur + Vector3(randf_range(-0.01, 0.01), randf_range(0.0, 0.02), randf_range(-0.01, 0.01))

func _pick_crew_target(ship, unit: Dictionary) -> Vector3:
	var home: Vector3 = unit["base"]
	# 优先去受损的舱室修理
	var damaged = null
	for c in ship.compartments:
		if c.alive() and c.hp_ratio() < 0.7:
			damaged = c
			break
	if damaged != null and randf() < 0.55:
		var off: Vector3 = damaged.local_offset()
		return off + Vector3(randf_range(-0.35, 0.35), randf_range(-0.25, 0.25), randf_range(-0.35, 0.35))
	# 否则回自己的舱室附近待命
	return home + Vector3(randf_range(-0.45, 0.45), randf_range(-0.2, 0.3), randf_range(-0.45, 0.45))

func _drain_ejections() -> void:
	while sim.ejections.size() > 0:
		var e: Dictionary = sim.ejections.pop_front()
		var n: int = mini(int(e["count"]), 6)
		for i in n:
			var fig := MeshInstance3D.new()
			var capsule := CapsuleMesh.new()
			capsule.radius = 0.11
			capsule.height = 0.52
			fig.mesh = capsule
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.85, 0.93, 1.0) if e["team"] == "player" else Color(1.0, 0.86, 0.82)
			mat.emission_enabled = true
			mat.emission = mat.albedo_color * 0.5
			fig.material_override = mat
			fig.position = e["pos"] + Vector3(randf_range(-0.4, 0.4), randf_range(-0.4, 0.4), randf_range(-0.4, 0.4))
			add_child(fig)
			flying_crew.append({
				"node": fig,
				"vel": Vector3(randf_range(-0.8, 0.8), randf_range(-0.3, 1.0), randf_range(-0.8, 0.8)),
				"spin": Vector3(randf_range(-2.5, 2.5), randf_range(-2.5, 2.5), randf_range(-2.5, 2.5)),
				"life": 3.5,
			})

func _update_flying_crew(delta: float) -> void:
	for i in range(flying_crew.size() - 1, -1, -1):
		var f: Dictionary = flying_crew[i]
		var node: MeshInstance3D = f["node"]
		node.position += f["vel"] * delta * speed_scale
		node.rotation += f["spin"] * delta * speed_scale
		f["life"] -= delta * speed_scale
		if f["life"] <= 0.0:
			node.queue_free()
			flying_crew.remove_at(i)

func _update_camera_follow() -> void:
	if follow_uid >= 0:
		for ship in sim.ships:
			if ship.uid == follow_uid:
				cam_target = ship.pos
				break
		_apply_camera()

# ---------------------------------------------------------------- 光束与 HUD

func _sync_beams() -> void:
	beam_mesh.clear_surfaces()
	if sim.beams.size() > 0:
		beam_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		for b in sim.beams:
			var c: Color = Color(0.55, 0.85, 1.0) if b["team"] == "player" else Color(1.0, 0.55, 0.45)
			if b["hit"]:
				c = c.lightened(0.35)
			beam_mesh.surface_set_color(c)
			beam_mesh.surface_add_vertex(b["a"])
			beam_mesh.surface_set_color(c)
			beam_mesh.surface_add_vertex(b["b"])
		beam_mesh.surface_end()

func _update_hud() -> void:
	var p_crew := 0
	var e_crew := 0
	for s in sim.ships:
		if s.team == "player":
			p_crew += s.crew_alive()
		else:
			e_crew += s.crew_alive()
	time_label.text = "时间 %5.1f 秒　·　我方 %d 舰　·　敌方 %d 舰" % [
		sim.t, sim.team_alive("player"), sim.team_alive("enemy")]
	crew_label.text = "船员：我方 %d 人　·　敌方 %d 人" % [p_crew, e_crew]

	var lines: Array = []
	var start: int = maxi(0, sim.events.size() - 6)
	for i in range(start, sim.events.size()):
		var e: Dictionary = sim.events[i]
		lines.append("[%6.1f] %s" % [e["t"], e["text"]])
	log_label.text = "\n".join(lines)

# ---------------------------------------------------------------- 战果

func _show_result() -> void:
	_result_shown = true
	var s: Dictionary = sim.summary()

	result_layer = Control.new()
	result_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(result_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.68)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_layer.add_child(dim)

	var panel := PanelContainer.new()
	panel.position = Vector2(500, 150)
	panel.size = Vector2(600, 560)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11)
	style.border_color = Color(0.30, 0.34, 0.40)
	style.set_border_width_all(1)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", style)
	result_layer.add_child(panel)

	var text := Label.new()
	text.add_theme_font_size_override("font_size", 17)
	text.add_theme_color_override("font_color", Color(0.90, 0.93, 0.97))
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var lines: Array = []
	lines.append("战　果")
	lines.append("──────────────────────────")
	lines.append("用时 %.1f 秒" % s["time"])
	lines.append("")
	var verdict := "我方胜利"
	if s["winner"] == "enemy":
		verdict = "我方失败"
	elif s["winner"] == "draw":
		verdict = "两败俱伤"
	lines.append(verdict)
	lines.append("")
	for team in ["player", "enemy"]:
		var d: Dictionary = s[team]
		var label := "我方" if team == "player" else "敌方"
		lines.append("%s：存活 %d / %d，平均船体 %.0f%%" % [
			label, d["survived"], d["total"], d["avg_hull"] * 100.0])
		lines.append("　　阵亡船员：%d 人，幸存 %d 人" % [d["crew_lost"], d["crew_left"]])
		var caps: Array = d.get("captains", [])
		if caps.size() > 0:
			lines.append("　　舰长：" + "、".join(caps))
		var comps: Dictionary = d["comps"]
		if comps.size() > 0:
			var parts: Array = []
			for k in comps.keys():
				parts.append("%s×%d" % [k, comps[k]])
			lines.append("　　损失舱室：" + "，".join(parts))
	text.text = "\n".join(lines)
	panel.add_child(text)

	var again := Button.new()
	again.text = "立即开始下一场"
	again.position = Vector2(640, 660)
	again.size = Vector2(320, 58)
	again.add_theme_font_size_override("font_size", 20)
	again.pressed.connect(func(): _emit_finished(s))
	result_layer.add_child(again)

	var auto := Label.new()
	auto.text = "8 秒后自动开始下一场（滚轮可以拉近看这一场）"
	auto.position = Vector2(590, 730)
	auto.add_theme_font_size_override("font_size", 15)
	auto.add_theme_color_override("font_color", Color(0.55, 0.62, 0.70))
	result_layer.add_child(auto)

	# 自动连播：不需要任何点击。
	var timer := Timer.new()
	timer.wait_time = 8.0
	timer.one_shot = true
	timer.timeout.connect(func(): _emit_finished(s))
	add_child(timer)
	timer.start()

func _emit_finished(summary: Dictionary) -> void:
	if _finished_emitted:
		return
	_finished_emitted = true
	finished.emit(summary)
