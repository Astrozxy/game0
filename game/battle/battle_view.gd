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
const CREW_PER_SHIP := 26
const CREW_SPEED := 2.9
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
var emitters: Dictionary = {}        # uid -> CPUParticles3D（受损舱室的火花/碎屑）
var prev_comp_state: Dictionary = {} # "uid:index" -> 上一帧状态（用于检测"刚被打爆"）
var crew_units: Dictionary = {}      # uid -> Array[Dictionary]
var flying_crew: Array = []          # {node, vel, spin, life}
var beam_mesh: ImmediateMesh

var cam: Camera3D
var cam_dist := 58.0
var cam_target := Vector3.ZERO
var follow_uid := -1

var time_label: Label
var log_label: Label
var result_layer: Control
var _pause_btn: Button
var _speed_btn: Button
var crew_label: Label
var _doc_label: Label

func _ready() -> void:
	_setup_world()
	sim = BattleSim.make_battle(SHIPS_PER_SIDE, randi(), loadout, doctrine)
	_build_ships()
	_build_hud()
	# 调试：--closeup 时跟着第一艘舰近距离观察
	if OS.get_cmdline_args().has("--closeup") or OS.get_cmdline_user_args().has("--closeup"):
		for s in sim.ships:
			if s.team == "player":
				follow_uid = s.uid
				cam_target = s.pos
				break
		cam_dist = 13.0
	_apply_camera()

func _setup_world() -> void:
	cam = Camera3D.new()
	cam.fov = 50.0
	add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-72, -18, 0)
	light.light_energy = 1.15
	add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.03, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.42, 0.47, 0.58)
	e.ambient_light_energy = 0.95
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

		_build_hull(node, ship)
		for comp in ship.compartments:
			_build_pod(node, ship, comp)

		_build_crew_for(node, ship)
		var em := _make_emitter()
		node.add_child(em)
		emitters[ship.uid] = em
		ship_nodes[ship.uid] = node

# ---------------------------------------------------------------- 舰体
#
# 坐标约定：+Z 是舰首方向，+Y 向上，+X 向右。
# 舰体做成细长的分段结构：舰首锥、主装甲段、舰尾引擎组。

func _metal(c: Color, metallic := 0.22, rough := 0.62) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = rough
	return m

func _add_box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi

func _add_cyl(parent: Node3D, r_top: float, r_bot: float, h: float,
		pos: Vector3, mat: Material, segs := 8) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = segs
	mi.mesh = c
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi

func _basis_from_dir(dir: Vector3) -> Basis:
	var f := dir.normalized()
	var up := Vector3.UP
	if absf(f.dot(up)) > 0.97:
		up = Vector3.FORWARD
	var right := up.cross(f).normalized()
	var u := f.cross(right).normalized()
	return Basis(right, u, f)

func _team_accent(team: String) -> Color:
	return Color(0.35, 0.78, 1.0) if team == "player" else Color(1.0, 0.42, 0.35)

func _build_hull(node: Node3D, ship) -> void:
	var accent := _team_accent(ship.team)
	var dark := Color(0.19, 0.21, 0.26).lerp(accent, 0.10)
	var mid := Color(0.27, 0.30, 0.36).lerp(accent, 0.12)

	var hull_mat := _metal(dark, 0.85, 0.30)
	var plate_mat := _metal(mid, 0.80, 0.34)
	var accent_mat := _metal(accent * 0.9, 0.30, 0.35)
	accent_mat.emission_enabled = true
	accent_mat.emission = accent * 0.55
	var line_mat := _metal(Color(0.10, 0.11, 0.14), 0.6, 0.5)
	var glow_mat := _emissive(Color(1.0, 0.90, 0.65), 0.7)

	# ---- 主装甲段（三层，形成厚度感）----
	_add_box(node, Vector3(3.05, 1.05, 7.2), Vector3(0, 0, 0.1), hull_mat)
	_add_box(node, Vector3(3.25, 0.55, 5.6), Vector3(0, 0.06, 0.3), plate_mat)
	_add_box(node, Vector3(2.35, 0.42, 6.4), Vector3(0, -0.62, 0.2), plate_mat)

	# ---- 背脊与上层建筑 ----
	_add_box(node, Vector3(0.95, 0.34, 5.4), Vector3(0, 0.66, -0.1), plate_mat)
	_add_box(node, Vector3(0.55, 0.22, 4.2), Vector3(0, 0.84, -0.2), hull_mat)

	# ---- 舰首：三段收窄 ----
	var b1 := _add_cyl(node, 0.95, 1.42, 1.6, Vector3(0, 0, 4.30), hull_mat, 6)
	b1.rotation_degrees = Vector3(-90, 0, 0)
	var b2 := _add_cyl(node, 0.52, 0.95, 1.4, Vector3(0, 0, 5.40), hull_mat, 6)
	b2.rotation_degrees = Vector3(-90, 0, 0)
	var b3 := _add_cyl(node, 0.06, 0.52, 1.2, Vector3(0, 0, 6.30), hull_mat, 6)
	b3.rotation_degrees = Vector3(-90, 0, 0)
	# 舰首装甲脊
	_add_box(node, Vector3(0.40, 0.24, 2.6), Vector3(0, 0.34, 4.60), plate_mat)
	# 舰首侧棱
	for sx in [-0.62, 0.62]:
		var flank := _add_box(node, Vector3(0.12, 0.30, 2.0), Vector3(sx, 0.02, 4.40), plate_mat)
		flank.rotation_degrees = Vector3(0, sx * 5.0, 0)

	# ---- 舰尾 ----
	_add_box(node, Vector3(2.75, 0.95, 2.4), Vector3(0, 0, -4.20), hull_mat)
	_add_box(node, Vector3(1.65, 0.34, 1.8), Vector3(0, 0.52, -4.10), plate_mat)

	# ---- 双引擎组（13 / 14 号硬点）----
	for ex in [-0.92, 0.92]:
		var housing := _add_box(node, Vector3(0.78, 0.72, 1.2), Vector3(ex, 0, -5.30), hull_mat)
		var noz := _add_cyl(node, 0.30, 0.38, 0.9, Vector3(ex, 0, -5.95),
			_metal(Color(0.10, 0.11, 0.13), 0.9, 0.25), 10)
		noz.rotation_degrees = Vector3(90, 0, 0)
		var glow := _add_cyl(node, 0.26, 0.26, 0.10, Vector3(ex, 0, -6.40), accent_mat, 10)
		glow.rotation_degrees = Vector3(90, 0, 0)

	# ---- 舷侧装甲带与灯带 ----
	for sx in [-1.58, 1.58]:
		_add_box(node, Vector3(0.14, 0.62, 5.2), Vector3(sx, -0.02, 0.9), plate_mat)
		_add_box(node, Vector3(0.05, 0.08, 4.6), Vector3(sx * 1.02, 0.16, 0.6), accent_mat)

	# ---- 舰桥塔（11 号硬点）----
	_add_box(node, Vector3(1.05, 0.55, 1.5), Vector3(0, 0.95, -2.20), plate_mat)
	_add_box(node, Vector3(0.72, 0.42, 1.0), Vector3(0, 1.30, -2.20), hull_mat)
	_add_box(node, Vector3(0.44, 0.16, 0.68), Vector3(0, 1.52, -2.20), accent_mat)
	for wx in [-0.24, 0.0, 0.24]:
		_add_box(node, Vector3(0.12, 0.07, 0.05), Vector3(wx, 1.18, -1.52), glow_mat)

	# ---- 传感器桅杆（12 号硬点）----
	_add_box(node, Vector3(0.22, 0.55, 0.22), Vector3(0, 0.95, -3.60), plate_mat)
	_add_box(node, Vector3(0.62, 0.08, 0.62), Vector3(0, 1.22, -3.60), hull_mat)
	for ang in [0.0, 90.0, 180.0, 270.0]:
		var strut := _add_box(node, Vector3(0.05, 0.05, 0.34), Vector3(0, 1.26, -3.60), plate_mat)
		strut.rotation_degrees = Vector3(0, ang, 25)

	# ---- 舷侧机库/舱段（增加体量层次）----
	for sx in [-1.05, 1.05]:
		_add_box(node, Vector3(0.55, 0.45, 2.0), Vector3(sx, 0.62, 0.6), plate_mat)
		_add_box(node, Vector3(0.62, 0.06, 1.7), Vector3(sx, 0.86, 0.6), hull_mat)

	# ---- 面板分割线（廉价但有效的"复杂度"）----
	for i in 7:
		var z := -4.0 + float(i) * 1.15
		_add_box(node, Vector3(3.12, 0.03, 0.03), Vector3(0, 0.53, z), line_mat)
	for i in 5:
		var z2 := -3.0 + float(i) * 1.3
		_add_box(node, Vector3(3.30, 0.03, 0.03), Vector3(0, 0.34, z2), line_mat)

	# ---- 腹部装甲与散热片 ----
	_add_box(node, Vector3(1.9, 0.16, 4.2), Vector3(0, -0.86, 0.4), plate_mat)
	for i in 4:
		_add_box(node, Vector3(1.4, 0.22, 0.10), Vector3(0, -0.96, -1.2 + float(i) * 0.9), line_mat)

# ---------------------------------------------------------------- 舱室
#
# 舱室是外挂的装甲模块：本体 + 按类型不同的功能件（炮塔/喷口/护盾环/天线）。

func _build_pod(node: Node3D, ship, comp) -> void:
	var accent := _team_accent(ship.team)
	var type_col := Model.comp_color(comp.kind)
	var pod := Node3D.new()
	pod.position = comp.local_pos
	pod.transform.basis = _basis_from_dir(comp.dir)
	node.add_child(pod)

	var base_mat := _metal(Color(0.28, 0.31, 0.37).lerp(type_col, 0.30), 0.82, 0.32)
	base_mat.emission_enabled = true
	base_mat.emission = type_col * 0.10

	# 模块本体（朝外的一侧略厚）
	_add_box(pod, Vector3(0.60, 0.46, 0.66), Vector3.ZERO, base_mat)

	var detail_mat := _metal(type_col.darkened(0.25), 0.55, 0.35)

	match comp.kind:
		Model.CompType.WEAPON, Model.CompType.WEAPON_LONG, Model.CompType.WEAPON_CLOSE:
			# 炮塔：基座 + 炮管
			var base := _add_cyl(pod, 0.26, 0.30, 0.16, Vector3(0, 0.36, 0), detail_mat, 10)
			var barrel_len := 1.25 if comp.kind == Model.CompType.WEAPON_LONG else 0.75
			_add_box(pod, Vector3(0.10, 0.10, barrel_len),
				Vector3(0, 0.36, barrel_len * 0.45), detail_mat)
			# 炮口
			_add_box(pod, Vector3(0.15, 0.15, 0.12),
				Vector3(0, 0.36, barrel_len * 0.9), detail_mat)
		Model.CompType.ENGINE:
			var noz := _add_cyl(pod, 0.22, 0.28, 0.42, Vector3(0, 0, -0.45), detail_mat, 10)
			noz.rotation_degrees = Vector3(90, 0, 0)
			var gl := _add_cyl(pod, 0.16, 0.16, 0.06, Vector3(0, 0, -0.68), _emissive(accent), 10)
			gl.rotation_degrees = Vector3(90, 0, 0)
		Model.CompType.SHIELD:
			var ring := MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = 0.30
			torus.outer_radius = 0.42
			ring.mesh = torus
			ring.position = Vector3(0, 0.42, 0)
			ring.rotation_degrees = Vector3(90, 0, 0)
			ring.material_override = _emissive(type_col)
			pod.add_child(ring)
		Model.CompType.SENSOR:
			var dish := _add_cyl(pod, 0.28, 0.08, 0.16, Vector3(0, 0.42, 0), _metal(Color(0.55, 0.60, 0.66), 0.6, 0.4), 12)
			dish.rotation_degrees = Vector3(0, 0, 0)
			_add_box(pod, Vector3(0.04, 0.45, 0.04), Vector3(0.18, 0.55, 0), detail_mat)
		Model.CompType.CREW:
			for wx in [-0.22, 0.0, 0.22]:
				_add_box(pod, Vector3(0.10, 0.06, 0.03), Vector3(wx, 0.16, 0.45),
					_emissive(Color(1.0, 0.92, 0.70)))
		Model.CompType.MAGAZINE:
			_add_box(pod, Vector3(0.84, 0.20, 0.92), Vector3(0, 0.30, 0), detail_mat)
			_add_box(pod, Vector3(0.30, 0.10, 0.30), Vector3(0, 0.44, 0), _emissive(Color(1.0, 0.72, 0.25)))

	comp_mats["%d:%d" % [ship.uid, comp.index]] = base_mat

func _emissive(c: Color, strength := 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c * strength
	m.metallic = 0.2
	m.roughness = 0.4
	return m

## 船员小人：身体 + 头 + 背包。巨舰尺度下很小，只有拉近才看得清。
func _make_crew_figure(team: String) -> Node3D:
	var root := Node3D.new()
	var skin := Color(0.86, 0.93, 1.0) if team == "player" else Color(1.0, 0.87, 0.83)
	var suit := _emissive(skin, 0.45)
	suit.metallic = 0.05
	suit.roughness = 0.75

	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.038
	cap.height = 0.19
	body.mesh = cap
	body.position.y = 0.095
	body.material_override = suit
	root.add_child(body)

	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.032
	sph.height = 0.064
	head.mesh = sph
	head.position.y = 0.215
	head.material_override = _emissive(Color(0.95, 0.95, 0.98), 0.35)
	root.add_child(head)

	var pack := MeshInstance3D.new()
	var pb := BoxMesh.new()
	pb.size = Vector3(0.048, 0.065, 0.028)
	pack.mesh = pb
	pack.position = Vector3(0, 0.115, -0.034)
	pack.material_override = _metal(Color(0.30, 0.32, 0.37), 0.4, 0.6)
	root.add_child(pack)

	return root

func _build_crew_for(ship_node: Node3D, ship) -> void:
	var units: Array = []
	for i in CREW_PER_SHIP:
		var fig := _make_crew_figure(ship.team)
		var spot := _idle_spot(ship)
		fig.position = spot
		ship_node.add_child(fig)
		units.append({
			"node": fig,
			"state": "idle",
			"target": spot,
			"timer": randf_range(0.1, 0.9),
			"phase": randf() * TAU,
			"station": -1,
			"home": spot,
		})
	crew_units[ship.uid] = units

## 甲板上一个随机待命点（贴近舰体表面）
func _idle_spot(ship) -> Vector3:
	var z := randf_range(-4.6, 4.2)
	var x := randf_range(-1.25, 1.25)
	return Vector3(x, 0.56, z)

## 某个舱室旁边的一个落脚点（在装甲面上）
func _station_spot(comp) -> Vector3:
	var base: Vector3 = comp.local_pos + comp.dir * 0.42
	return base + Vector3(randf_range(-0.18, 0.18), randf_range(0.0, 0.10), randf_range(-0.18, 0.18))

## 受损舱室的粒子发射器：引擎喷火花、武器舱掉碎屑、护盾冒电弧。
func _make_emitter() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 16
	p.lifetime = 0.75
	p.emitting = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.45
	p.direction = Vector3(0, 0.5, 0)
	p.spread = 75.0
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 2.8
	p.gravity = Vector3(0, -1.4, 0)
	p.scale_amount_min = 0.04
	p.scale_amount_max = 0.13
	var m := BoxMesh.new()
	m.size = Vector3(1, 1, 1)
	p.mesh = m
	return p

func _spark_color(kind: int) -> Color:
	match kind:
		Model.CompType.ENGINE:   return Color(1.0, 0.45, 0.10)
		Model.CompType.WEAPON:   return Color(1.0, 0.85, 0.35)
		Model.CompType.MAGAZINE: return Color(1.0, 0.30, 0.20)
		Model.CompType.SHIELD:   return Color(0.45, 0.65, 1.0)
		Model.CompType.CREW:     return Color(0.95, 0.95, 0.95)
		Model.CompType.SENSOR:   return Color(0.45, 0.95, 0.95)
	return Color(1, 1, 1)

func _update_damage_emitter(ship, node: Node3D) -> void:
	var em: CPUParticles3D = emitters.get(ship.uid)
	if em == null:
		return
	if not ship.alive():
		em.emitting = false
		return
	var worst = null
	for c in ship.compartments:
		if c.alive() and c.hp_ratio() < 0.72:
			if worst == null or c.hp_ratio() < worst.hp_ratio():
				worst = c
	if worst == null:
		em.emitting = false
		return
	em.position = worst.local_offset()
	em.emitting = true
	em.color = _spark_color(worst.kind)
	em.amount = 10 + int((1.0 - worst.hp_ratio()) * 18.0)

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

	var doc_label := Label.new()
	doc_label.position = Vector2(980, 14)
	doc_label.add_theme_font_size_override("font_size", 14)
	doc_label.add_theme_color_override("font_color", Color(0.78, 0.72, 0.60))
	layer.add_child(doc_label)
	_doc_label = doc_label

func _band_label(b: String) -> String:
	match b:
		"close": return "允许近距"
		"far":   return "允许远距"
		_:       return "允许中距"

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

			# 舱室被打爆的那一瞬间：附近船员四散 / 被抛出
			var key := "%d:%d" % [ship.uid, comp.index]
			var prev: int = prev_comp_state.get(key, Model.CompState.ONLINE)
			if comp.state == Model.CompState.OFFLINE and prev != Model.CompState.OFFLINE:
				_panic_near(ship, comp)
			prev_comp_state[key] = comp.state
		_update_damage_emitter(ship, node)

# ---------------------------------------------------------------- 船员

func _update_crew(delta: float) -> void:
	var dt: float = delta * maxf(speed_scale, 0.15)
	for ship in sim.ships:
		var units: Array = crew_units.get(ship.uid, [])
		if units.is_empty():
			continue
		var alive: bool = ship.alive() and ship.crew_alive() > 0
		for i in units.size():
			var u: Dictionary = units[i]
			var fig: Node3D = u["node"]
			if not alive:
				fig.visible = false
				continue
			fig.visible = true
			var st: String = u["state"]

			match st:
				"panic":
					# 四散逃跑：朝远离爆点的方向跑，跑一段后恢复
					_walk_crew(u, dt)
					u["timer"] -= dt
					if u["timer"] <= 0.0:
						u["state"] = "idle"
						u["timer"] = randf_range(0.3, 1.0)
						u["target"] = _idle_spot(ship)
						u["station"] = -1
				"walk":
					if _walk_crew(u, dt):
						u["state"] = "work"
						u["timer"] = randf_range(1.6, 3.6)
				"work":
					# 干活：轻微上下起伏 + 小幅摆动
					u["phase"] += dt * 7.0
					var base: Vector3 = u["work_pos"]
					fig.position = base + Vector3(0, sin(u["phase"]) * 0.022, 0)
					fig.rotation.y += sin(u["phase"] * 0.5) * 0.03
					u["timer"] -= dt
					if u["timer"] <= 0.0:
						u["state"] = "idle"
						u["timer"] = randf_range(0.2, 0.8)
				_:
					_walk_crew(u, dt)
					u["timer"] -= dt
					if u["timer"] <= 0.0:
						_assign_job(ship, u, i)

## 朝目标走；到达返回 true
func _walk_crew(u: Dictionary, dt: float) -> bool:
	var fig: Node3D = u["node"]
	var target: Vector3 = u["target"]
	var cur: Vector3 = fig.position
	var d: Vector3 = target - cur
	if d.length() <= 0.06:
		return true
	var step: Vector3 = d.normalized() * minf(CREW_SPEED * dt, d.length())
	fig.position = cur + step
	# 面朝移动方向 + 走路的上下起伏
	u["phase"] += dt * 12.0
	fig.rotation.y = atan2(step.x, step.z)
	fig.position.y += sin(u["phase"]) * 0.012
	return false

## 分配岗位：按编号分散到不同炮位；有受损舱室时，部分人去修理；其余回甲板
func _assign_job(ship, u: Dictionary, idx: int) -> void:
	var guns: Array = []
	var damaged: Array = []
	for c in ship.compartments:
		if not c.alive():
			continue
		if Model.is_weapon(c.kind):
			guns.append(c)
		if c.hp_ratio() < 0.65:
			damaged.append(c)

	var pick = null
	# 每 4 个人里有 1 个负责修理
	if damaged.size() > 0 and idx % 4 == 0:
		pick = damaged[idx % damaged.size()]
	elif guns.size() > 0:
		pick = guns[idx % guns.size()]

	if pick != null:
		u["state"] = "walk"
		u["station"] = pick.index
		u["work_pos"] = _station_spot(pick)
		u["target"] = u["work_pos"]
	else:
		u["state"] = "walk"
		u["station"] = -1
		u["target"] = _idle_spot(ship)
	u["timer"] = randf_range(2.5, 5.0)

## 某个舱室被击穿：附近的船员四散，一部分当场被抛出船外
func _panic_near(ship, comp) -> void:
	var units: Array = crew_units.get(ship.uid, [])
	if units.is_empty():
		return
	var blast: Vector3 = comp.local_pos
	for u in units:
		var fig: Node3D = u["node"]
		if not fig.visible:
			continue
		var d: float = (fig.position - blast).length()
		if d > 3.2:
			continue
		# 一半恐慌逃跑，一半被抛出去
		if randf() < 0.5:
			u["state"] = "panic"
			var away: Vector3 = (fig.position - blast)
			if away.length() < 0.01:
				away = Vector3(randf_range(-1, 1), 0.2, randf_range(-1, 1))
			u["target"] = fig.position + away.normalized() * randf_range(1.2, 2.4) + Vector3(0, 0.05, 0)
			u["timer"] = randf_range(0.8, 1.6)
			u["station"] = -1
		else:
			fig.visible = false
			_spawn_flying_crew(ship, fig.position, 1)

func _spawn_flying_crew(ship, local_pos: Vector3, count: int) -> void:
	var world: Vector3 = ship.local_to_world(local_pos)
	for i in count:
		var fig := _make_crew_figure(ship.team)
		fig.position = world + Vector3(randf_range(-0.12, 0.12), randf_range(-0.12, 0.12), randf_range(-0.12, 0.12))
		add_child(fig)
		flying_crew.append({
			"node": fig,
			"vel": Vector3(randf_range(-0.9, 0.9), randf_range(-0.2, 1.1), randf_range(-0.9, 0.9)),
			"spin": Vector3(randf_range(-2.2, 2.2), randf_range(-2.2, 2.2), randf_range(-2.2, 2.2)),
			"life": 3.6,
		})

func _drain_ejections() -> void:
	while sim.ejections.size() > 0:
		var e: Dictionary = sim.ejections.pop_front()
		var n: int = mini(int(e["count"]), 5)
		for i in n:
			var fig := _make_crew_figure(e["team"])
			fig.position = e["pos"] + Vector3(randf_range(-0.35, 0.35), randf_range(-0.35, 0.35), randf_range(-0.35, 0.35))
			add_child(fig)
			flying_crew.append({
				"node": fig,
				"vel": Vector3(randf_range(-0.9, 0.9), randf_range(-0.2, 1.2), randf_range(-0.9, 0.9)),
				"spin": Vector3(randf_range(-2.5, 2.5), randf_range(-2.5, 2.5), randf_range(-2.5, 2.5)),
				"life": 3.5,
			})

func _update_flying_crew(delta: float) -> void:
	for i in range(flying_crew.size() - 1, -1, -1):
		var f: Dictionary = flying_crew[i]
		var node: Node3D = f["node"]
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
	_doc_label.text = "手册：%s · %s" % [_band_label(sim.doctrine["player"]["band"]), "集火" if sim.doctrine["player"]["focus"] else "自由射击"]
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
	var doc: Dictionary = s.get("doctrine", {})
	if doc.size() > 0:
		var pd: Dictionary = doc.get("player", {})
		var ed: Dictionary = doc.get("enemy", {})
		lines.append("我方手册：%s · %s" % [
			_band_label(pd.get("band", "mid")),
			"集火" if pd.get("focus", true) else "自由射击"])
		lines.append("敌方手册：%s · %s" % [
			_band_label(ed.get("band", "mid")),
			"集火" if ed.get("focus", true) else "自由射击"])
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

		# 归因：这一方的损失主要来自哪类舱室
		var dmgc: Dictionary = d.get("dmg_by_comp", {})
		if dmgc.size() > 0:
			var total_dmg := 0.0
			for v in dmgc.values():
				total_dmg += float(v)
			var keys: Array = dmgc.keys()
			keys.sort_custom(func(a, b): return float(dmgc[a]) > float(dmgc[b]))
			var parts2: Array = []
			for i in mini(3, keys.size()):
				var kk: String = keys[i]
				parts2.append("%s %.0f%%" % [kk, float(dmgc[kk]) * 100.0 / maxf(1.0, total_dmg)])
			lines.append("　　损失来源：" + "，".join(parts2))

		if int(d.get("top_kills", 0)) > 0:
			lines.append("　　头号战果：%s（%d 杀）" % [d["top_killer"], d["top_kills"]])
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
