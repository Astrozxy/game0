extends Node3D
## 战斗画面：跑模拟 + 画出来。玩家不能指挥，只能看。
## 这是"录像"的第一版形态——战斗自动进行，结束后给战果。

signal finished(summary: Dictionary)

const FIXED_DT := 0.05
const SHIPS_PER_SIDE := 6

var loadout: Array = []
var sim: BattleSim
var paused := false
var speed_scale := 1.0
var accum := 0.0
var _result_shown := false

var ship_nodes: Dictionary = {}     # uid -> Node3D
var comp_mats: Dictionary = {}      # "uid:index" -> StandardMaterial3D
var beam_mesh: ImmediateMesh

var time_label: Label
var log_label: Label
var result_layer: Control
var _pause_btn: Button
var _speed_btn: Button

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

func _ready() -> void:
	_setup_world()
	sim = BattleSim.make_battle(SHIPS_PER_SIDE, randi(), loadout)
	_build_ships()
	_build_hud()

func _setup_world() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0, 44, -38)
	cam.fov = 50.0
	add_child(cam)
	cam.look_at(Vector3(0, 0, 0))

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.2
	add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.03, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.30, 0.34, 0.42)
	e.ambient_light_energy = 0.8
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
		box.size = Vector3(2.4, 0.9, 4.2)
		hull.mesh = box
		var hm := StandardMaterial3D.new()
		hm.albedo_color = Color(0.30, 0.42, 0.60) if ship.team == "player" else Color(0.62, 0.30, 0.30)
		hm.metallic = 0.2
		hm.roughness = 0.6
		hull.material_override = hm
		node.add_child(hull)

		for comp in ship.compartments:
			var cm := MeshInstance3D.new()
			var cb := BoxMesh.new()
			cb.size = Vector3(0.85, 0.85, 0.85)
			cm.mesh = cb
			cm.position = comp.local_offset()
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Model.comp_color(comp.kind)
			mat.emission_enabled = true
			mat.emission = Model.comp_color(comp.kind) * 0.25
			cm.material_override = mat
			node.add_child(cm)
			comp_mats["%d:%d" % [ship.uid, comp.index]] = mat

		ship_nodes[ship.uid] = node

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := ColorRect.new()
	top.color = Color(0, 0, 0, 0.45)
	top.position = Vector2(0, 0)
	top.size = Vector2(1600, 54)
	layer.add_child(top)

	time_label = Label.new()
	time_label.position = Vector2(24, 12)
	time_label.add_theme_font_size_override("font_size", 19)
	time_label.add_theme_color_override("font_color", Color(0.90, 0.93, 0.97))
	layer.add_child(time_label)

	var pause_btn := Button.new()
	pause_btn.text = "暂停"
	pause_btn.position = Vector2(1290, 10)
	pause_btn.size = Vector2(90, 34)
	pause_btn.pressed.connect(_toggle_pause)
	layer.add_child(pause_btn)
	_pause_btn = pause_btn

	var speed_btn := Button.new()
	speed_btn.text = "1×"
	speed_btn.position = Vector2(1390, 10)
	speed_btn.size = Vector2(70, 34)
	speed_btn.pressed.connect(_cycle_speed)
	layer.add_child(speed_btn)
	_speed_btn = speed_btn

	var back_btn := Button.new()
	back_btn.text = "返回配船"
	back_btn.position = Vector2(1470, 10)
	back_btn.size = Vector2(116, 34)
	back_btn.pressed.connect(func(): finished.emit({}))
	layer.add_child(back_btn)

	log_label = Label.new()
	log_label.position = Vector2(24, 790)
	log_label.size = Vector2(1000, 100)
	log_label.add_theme_font_size_override("font_size", 15)
	log_label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	layer.add_child(log_label)

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

	_sync_visuals()
	_update_hud()
	if sim.over and not _result_shown:
		_show_result()

func _sync_visuals() -> void:
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
				mat.albedo_color = Color(0.10, 0.10, 0.12)
				mat.emission = Color(0, 0, 0)
			elif comp.state == Model.CompState.DAMAGED:
				mat.albedo_color = Color(0.85, 0.45, 0.15)
				mat.emission = Color(0.6, 0.2, 0.0) * 0.5
			else:
				mat.albedo_color = Model.comp_color(comp.kind)
				mat.emission = Model.comp_color(comp.kind) * 0.25

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
	time_label.text = "时间 %5.1f 秒　·　我方 %d　·　敌方 %d" % [
		sim.t, sim.team_alive("player"), sim.team_alive("enemy")]

	var lines: Array = []
	var start: int = maxi(0, sim.events.size() - 6)
	for i in range(start, sim.events.size()):
		var e: Dictionary = sim.events[i]
		lines.append("[%6.1f] %s" % [e["t"], e["text"]])
	log_label.text = "\n".join(lines)

func _show_result() -> void:
	_result_shown = true
	var s: Dictionary = sim.summary()

	result_layer = Control.new()
	result_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(result_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.66)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	result_layer.add_child(dim)

	var panel := PanelContainer.new()
	panel.position = Vector2(520, 200)
	panel.size = Vector2(560, 460)
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
		var comps: Dictionary = d["comps"]
		if comps.size() > 0:
			var parts: Array = []
			for k in comps.keys():
				parts.append("%s×%d" % [k, comps[k]])
			lines.append("　　损失舱室：" + "，".join(parts))
	text.text = "\n".join(lines)
	panel.add_child(text)

	var again := Button.new()
	again.text = "改配装，再打一场"
	again.position = Vector2(520 + 130, 200 + 380)
	again.size = Vector2(300, 56)
	again.add_theme_font_size_override("font_size", 20)
	again.pressed.connect(func(): finished.emit(s))
	result_layer.add_child(again)
