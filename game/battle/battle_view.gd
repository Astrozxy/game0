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
const CREW_PER_SHIP := 104
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
var crew_data: Array = []            # 每个船员一条：{ship, idx, pos, target, timer, ...}
var crew_mm: MultiMesh = null
var crew_mm_node: MultiMeshInstance3D = null
var turret_nodes: Dictionary = {}    # "uid:index" -> 可旋转的炮塔节点
var turret_pods: Dictionary = {}     # "uid:index" -> 炮塔所在的 pod（用于换算朝向）
var ship_mats: Dictionary = {}       # uid -> 共用材质集
var comp_base_colors: Dictionary = {}
var comp_base_emission: Dictionary = {}
var player_hull: int = Model.HullClass.CRUISER
var commanded_hull: int = Model.HullClass.CRUISER
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
	# 舰级：默认巡洋舰；--hull=N 指定，--mix 让敌方用另一种舰级
	var cls := commanded_hull
	var mix := false
	var args: Array = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--hull="):
			cls = int(a.split("=")[1])
		if a == "--mix":
			mix = true
	var ecls := cls
	if mix:
		ecls = (cls + 1) % Model.HULLS.size()
	player_hull = cls
	sim = BattleSim.make_battle(SHIPS_PER_SIDE, randi(), loadout, doctrine, cls, ecls)
	_build_ships()
	_build_crew_multimesh()
	_build_hud()
	# 调试：--closeup 时跟着第一艘舰近距离观察
	if args.has("--closeup"):
		for s in sim.ships:
			if s.team == "player":
				follow_uid = s.uid
				cam_target = s.pos
				break
		cam_dist = 8.0
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
	# 舰级决定体量：以巡洋舰几何为基准，按舰级数据整体缩放
	var hd := Model.hull_data(ship.hull_class)
	var hx: float = float(hd['width']) / 3.4
	var hy: float = float(hd['height']) / 1.10
	var hz: float = float(hd['length']) / 13.0
	var body := Node3D.new()
	body.scale = Vector3(hx, hy, hz)
	node.add_child(body)


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
	_add_box(body, Vector3(3.05, 1.05, 7.2), Vector3(0, 0, 0.1), hull_mat)
	_add_box(body, Vector3(3.25, 0.55, 5.6), Vector3(0, 0.06, 0.3), plate_mat)
	_add_box(body, Vector3(2.35, 0.42, 6.4), Vector3(0, -0.62, 0.2), plate_mat)

	# ---- 背脊与上层建筑 ----
	_add_box(body, Vector3(0.95, 0.34, 5.4), Vector3(0, 0.66, -0.1), plate_mat)
	_add_box(body, Vector3(0.55, 0.22, 4.2), Vector3(0, 0.84, -0.2), hull_mat)

	# ---- 舰首：三段收窄 ----
	var b1 := _add_cyl(body, 0.95, 1.42, 1.6, Vector3(0, 0, 4.30), hull_mat, 6)
	b1.rotation_degrees = Vector3(-90, 0, 0)
	var b2 := _add_cyl(body, 0.52, 0.95, 1.4, Vector3(0, 0, 5.40), hull_mat, 6)
	b2.rotation_degrees = Vector3(-90, 0, 0)
	var b3 := _add_cyl(body, 0.06, 0.52, 1.2, Vector3(0, 0, 6.30), hull_mat, 6)
	b3.rotation_degrees = Vector3(-90, 0, 0)
	# 舰首装甲脊
	_add_box(body, Vector3(0.40, 0.24, 2.6), Vector3(0, 0.34, 4.60), plate_mat)
	# 舰首侧棱
	for sx in [-0.62, 0.62]:
		var flank := _add_box(body, Vector3(0.12, 0.30, 2.0), Vector3(sx, 0.02, 4.40), plate_mat)
		flank.rotation_degrees = Vector3(0, sx * 5.0, 0)

	# ---- 舰尾 ----
	_add_box(body, Vector3(2.75, 0.95, 2.4), Vector3(0, 0, -4.20), hull_mat)
	_add_box(body, Vector3(1.65, 0.34, 1.8), Vector3(0, 0.52, -4.10), plate_mat)

	# ---- 双引擎组（13 / 14 号硬点）----
	for ex in [-0.92, 0.92]:
		var housing := _add_box(body, Vector3(0.78, 0.72, 1.2), Vector3(ex, 0, -5.30), hull_mat)
		var noz := _add_cyl(body, 0.30, 0.38, 0.9, Vector3(ex, 0, -5.95),
			_metal(Color(0.10, 0.11, 0.13), 0.9, 0.25), 10)
		noz.rotation_degrees = Vector3(90, 0, 0)
		var glow := _add_cyl(body, 0.26, 0.26, 0.10, Vector3(ex, 0, -6.40), accent_mat, 10)
		glow.rotation_degrees = Vector3(90, 0, 0)

	# ---- 引擎尾焰（按舰级的引擎硬点位置放置）----
	var eng_pts: Array = []
	var hcls: int = ship.hull_class
	for hi in Model.slot_count(hcls):
		if Model.hardpoint_name(hcls, hi).begins_with("引擎"):
			eng_pts.append(Model.hardpoint_pos(hcls, hi))
	for ep in eng_pts:
		var plume := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.24
		cone.bottom_radius = 0.02
		cone.height = 1.5
		cone.radial_segments = 10
		plume.mesh = cone
		plume.position = Vector3(ep.x, ep.y, ep.z - 0.95)
		plume.rotation_degrees = Vector3(-90, 0, 0)
		var pm := StandardMaterial3D.new()
		pm.albedo_color = Color(accent.r, accent.g, accent.b, 0.22)
		pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pm.emission_enabled = true
		pm.emission = accent * 0.9
		pm.cull_mode = BaseMaterial3D.CULL_DISABLED
		plume.material_override = pm
		node.add_child(plume)

	# ---- 舷侧装甲带与灯带 ----
	for sx in [-1.58, 1.58]:
		_add_box(body, Vector3(0.14, 0.62, 5.2), Vector3(sx, -0.02, 0.9), plate_mat)
		_add_box(body, Vector3(0.05, 0.08, 4.6), Vector3(sx * 1.02, 0.16, 0.6), accent_mat)

	# ---- 舰桥塔（11 号硬点）----
	_add_box(body, Vector3(1.05, 0.55, 1.5), Vector3(0, 0.95, -2.20), plate_mat)
	_add_box(body, Vector3(0.72, 0.42, 1.0), Vector3(0, 1.30, -2.20), hull_mat)
	_add_box(body, Vector3(0.44, 0.16, 0.68), Vector3(0, 1.52, -2.20), accent_mat)
	for wx in [-0.24, 0.0, 0.24]:
		_add_box(body, Vector3(0.12, 0.07, 0.05), Vector3(wx, 1.18, -1.52), glow_mat)

	# ---- 传感器桅杆（12 号硬点）----
	_add_box(body, Vector3(0.22, 0.55, 0.22), Vector3(0, 0.95, -3.60), plate_mat)
	_add_box(body, Vector3(0.62, 0.08, 0.62), Vector3(0, 1.22, -3.60), hull_mat)
	for ang in [0.0, 90.0, 180.0, 270.0]:
		var strut := _add_box(body, Vector3(0.05, 0.05, 0.34), Vector3(0, 1.26, -3.60), plate_mat)
		strut.rotation_degrees = Vector3(0, ang, 25)

	# ---- 舷侧机库/舱段（增加体量层次）----
	for sx in [-1.05, 1.05]:
		_add_box(body, Vector3(0.55, 0.45, 2.0), Vector3(sx, 0.62, 0.6), plate_mat)
		_add_box(body, Vector3(0.62, 0.06, 1.7), Vector3(sx, 0.86, 0.6), hull_mat)

	# ---- 面板分割线（廉价但有效的"复杂度"）----
	for i in 7:
		var z := -4.0 + float(i) * 1.15
		_add_box(body, Vector3(3.12, 0.03, 0.03), Vector3(0, 0.53, z), line_mat)
	for i in 5:
		var z2 := -3.0 + float(i) * 1.3
		_add_box(body, Vector3(3.30, 0.03, 0.03), Vector3(0, 0.34, z2), line_mat)

	# ---- 腹部装甲与散热片 ----
	_add_box(body, Vector3(1.9, 0.16, 4.2), Vector3(0, -0.86, 0.4), plate_mat)
	for i in 4:
		_add_box(body, Vector3(1.4, 0.22, 0.10), Vector3(0, -0.96, -1.2 + float(i) * 0.9), line_mat)

	_build_hull_greebles(node, ship)
	if ship.hull_class == Model.HullClass.CARRIER:
		_build_carrier_deck(node, ship)

## 航母的飞行甲板与岛式舰桥（在舰体坐标空间里加，不跟随缩放）
func _build_carrier_deck(node: Node3D, ship) -> void:
	var mats := _mats_for(ship)
	var hd := Model.hull_data(ship.hull_class)
	var w: float = float(hd["width"])
	var l: float = float(hd["length"])
	var h: float = float(hd["height"])

	# 平直飞行甲板
	_add_box(node, Vector3(w * 0.94, 0.16, l * 0.88), Vector3(0, h * 0.62, 0.5), mats["plate"])
	# 跑道中线与横向停机线
	_add_box(node, Vector3(0.12, 0.03, l * 0.72), Vector3(0, h * 0.71, 0.5), mats["glow"])
	for i in 8:
		var z := -l * 0.32 + float(i) * (l * 0.10)
		_add_box(node, Vector3(w * 0.68, 0.02, 0.05), Vector3(0, h * 0.71, z), mats["detail"])
	# 甲板边缘灯
	for i in 9:
		var zz := -l * 0.40 + float(i) * (l * 0.10)
		for s in [-1.0, 1.0]:
			_add_box(node, Vector3(0.06, 0.04, 0.06), Vector3(s * w * 0.45, h * 0.70, zz), mats["glow"])
	# 岛式舰桥（右舷）
	var ix := w * 0.33
	_add_box(node, Vector3(0.95, 1.45, 2.9), Vector3(ix, h * 0.62 + 0.72, -l * 0.09), mats["hull"])
	_add_box(node, Vector3(0.78, 0.48, 1.7), Vector3(ix, h * 0.62 + 1.60, -l * 0.09), mats["plate"])
	for i in 4:
		_add_box(node, Vector3(0.06, 0.09, 0.12),
			Vector3(ix + 0.50, h * 0.62 + 1.12, -l * 0.09 - 0.60 + float(i) * 0.40), mats["glow"])
	# 侧面升降机
	_add_box(node, Vector3(1.5, 0.05, 1.9), Vector3(-w * 0.27, h * 0.70, l * 0.24), mats["dark"])

## 船体表面细节：零散设备箱、航行灯、天线。打破大块平板的玩具感。
func _build_hull_greebles(node: Node3D, ship) -> void:
	var mats := _mats_for(ship)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("greeble:%d" % ship.uid)
	var placed := 0
	var tries := 0
	while placed < 26 and tries < 240:
		tries += 1
		var z := rng.randf_range(-4.2, 4.2)
		var half := 1.35
		if z > 3.0:
			half = lerpf(1.35, 0.30, clampf((z - 3.0) / 1.8, 0.0, 1.0))
		elif z < -3.8:
			half = lerpf(1.35, 0.90, clampf((-z - 3.8) / 0.9, 0.0, 1.0))
		var x := rng.randf_range(-half, half)
		var p := Vector3(x, 0.54, z)
		var ok := true
		for hp in Model.HULLS[ship.hull_class]["hardpoints"]:
			if (p - hp[0]).length() < 0.95:
				ok = false
				break
		if not ok:
			continue
		var sz := Vector3(rng.randf_range(0.08, 0.22), rng.randf_range(0.03, 0.12), rng.randf_range(0.08, 0.26))
		_add_box(node, sz, p, mats["plate"] if rng.randf() < 0.6 else mats["detail"])
		placed += 1
	# 舷侧航行灯
	for i in 7:
		var zz := -3.6 + float(i) * 1.15
		for sx in [-1.46, 1.46]:
			_add_box(node, Vector3(0.05, 0.05, 0.05), Vector3(sx, 0.22, zz), mats["glow"])
	# 天线
	for i in 3:
		var zz2 := -1.0 + float(i) * 1.6
		_add_box(node, Vector3(0.018, 0.52, 0.018), Vector3(1.02, 0.78, zz2), mats["detail"])

# ---------------------------------------------------------------- 舱室
#
# 舱室是外挂的装甲模块：本体 + 按类型不同的功能件（炮塔/喷口/护盾环/天线）。

## 每艘船共用一套材质，避免每个舱室都新建材质（省显存、利于合批）
func _mats_for(ship) -> Dictionary:
	if ship_mats.has(ship.uid):
		return ship_mats[ship.uid]
	var accent := _team_accent(ship.team)
	var d := {
		"hull": _metal(Color(0.17, 0.19, 0.23).lerp(accent, 0.08), 0.55, 0.48),
		"plate": _metal(Color(0.25, 0.28, 0.33).lerp(accent, 0.10), 0.50, 0.55),
		"detail": _metal(Color(0.34, 0.37, 0.42), 0.55, 0.42),
		"dark": _metal(Color(0.09, 0.10, 0.12), 0.60, 0.50),
		"accent": _emissive(accent, 0.9),
		"glow": _emissive(Color(1.0, 0.92, 0.70), 0.85),
		"glass": _glass(accent),
		"warn": _metal(Color(0.82, 0.62, 0.14), 0.35, 0.55),
	}
	ship_mats[ship.uid] = d
	return d

## 玻璃质感：半透明 + 强自发光 + 极低粗糙度，看起来像发光的透镜
func _glass(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, 0.55)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.metallic = 0.05
	m.roughness = 0.06
	m.emission_enabled = true
	m.emission = c * 1.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _add_torus(parent: Node3D, inner: float, outer: float, pos: Vector3,
		mat: Material, rot_deg: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = 14
	t.ring_segments = 8
	mi.mesh = t
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	parent.add_child(mi)
	return mi

# ---------------------------------------------------------------- 舱室
#
# 舱室是外挂的装甲模块：通用底座 + 按类型完全不同的功能件。
# 目标是"能看出里面在干什么"，这样后面才能做对应的击中效果。

func _build_pod(node: Node3D, ship, comp) -> void:
	# 每个舱室用一份自己的材质副本，这样受损/摧毁时能单独变色
	var mats: Dictionary = _mats_for(ship).duplicate()
	var type_col := Model.comp_color(comp.kind)
	var pod := Node3D.new()
	pod.position = comp.local_pos
	pod.transform.basis = _basis_from_dir(comp.dir)
	node.add_child(pod)

	# 通用底座：装甲框 + 四角螺栓
	var base_mat := _metal(Color(0.24, 0.27, 0.32).lerp(type_col, 0.16), 0.62, 0.45)
	_add_box(pod, Vector3(0.64, 0.42, 0.70), Vector3.ZERO, base_mat)
	_add_box(pod, Vector3(0.72, 0.09, 0.78), Vector3(0, -0.17, 0), mats["plate"])
	for bx in [-0.26, 0.26]:
		for bz in [-0.29, 0.29]:
			_add_cyl(pod, 0.028, 0.028, 0.05, Vector3(bx, 0.22, bz), mats["detail"], 6)

	match comp.kind:
		Model.CompType.WEAPON, Model.CompType.WEAPON_LONG, Model.CompType.WEAPON_CLOSE:
			var yaw := _build_turret(pod, comp.kind, mats)
			var key := "%d:%d" % [ship.uid, comp.index]
			turret_nodes[key] = yaw
			turret_pods[key] = pod
		Model.CompType.ENGINE:
			_build_reactor(pod, mats)
		Model.CompType.SHIELD:
			_build_shield_emitter(pod, mats, type_col)
		Model.CompType.SENSOR:
			_build_sensor_array(pod, mats)
		Model.CompType.CREW:
			_build_quarters(pod, mats)
		Model.CompType.MAGAZINE:
			_build_magazine(pod, mats)

	var tint: Array = [
		base_mat, mats["detail"], mats["plate"], mats["accent"],
		mats["glow"], mats["warn"], mats["glass"]]
	var key := "%d:%d" % [ship.uid, comp.index]
	comp_mats[key] = tint
	var cols: Array = []
	var emis: Array = []
	for m in tint:
		cols.append(m.albedo_color)
		emis.append(m.emission)
	comp_base_colors[key] = cols
	comp_base_emission[key] = emis

# ---------------------------------------------------------------- 各类型功能件

## 聚变堆：发光环 + 约束环 + 支架 + 冷却管路 + 喷口
func _build_reactor(pod: Node3D, mats: Dictionary) -> void:
	var core_col := Color(0.42, 0.86, 1.0)
	var core_mat := _emissive(core_col, 1.3)
	# 主环（轴向沿 Z）
	_add_torus(pod, 0.15, 0.29, Vector3(0, 0.26, 0), core_mat, Vector3(90, 0, 0))
	_add_cyl(pod, 0.09, 0.09, 0.34, Vector3(0, 0.26, 0), _emissive(core_col, 0.65), 10)
	# 约束环
	for z in [-0.19, 0.19]:
		_add_torus(pod, 0.30, 0.35, Vector3(0, 0.26, z), mats["detail"], Vector3(90, 0, 0))
	# 支架
	for a in [0.0, 90.0, 180.0, 270.0]:
		var r := deg_to_rad(a)
		_add_box(pod, Vector3(0.05, 0.07, 0.46), Vector3(cos(r) * 0.33, 0.26, 0), mats["detail"]).rotation_degrees = Vector3(0, a, 0)
	# 冷却管路
	for sx in [-0.24, 0.24]:
		_add_box(pod, Vector3(0.055, 0.055, 0.52), Vector3(sx, 0.08, 0), mats["plate"])
		_add_cyl(pod, 0.05, 0.05, 0.10, Vector3(sx, 0.08, 0.24), mats["detail"], 8).rotation_degrees = Vector3(90, 0, 0)
	# 尾部喷口
	var noz := _add_cyl(pod, 0.20, 0.26, 0.34, Vector3(0, 0.0, -0.46), mats["dark"], 12)
	noz.rotation_degrees = Vector3(90, 0, 0)
	_add_cyl(pod, 0.16, 0.16, 0.05, Vector3(0, 0.0, -0.64), mats["accent"], 12).rotation_degrees = Vector3(90, 0, 0)

## 护盾发射器：大环 + 三块聚焦晶体 + 能量导管
func _build_shield_emitter(pod: Node3D, mats: Dictionary, col: Color) -> void:
	var cs := _emissive(col, 1.1)
	_add_torus(pod, 0.22, 0.34, Vector3(0, 0.34, 0), cs, Vector3(90, 0, 0))
	_add_torus(pod, 0.12, 0.16, Vector3(0, 0.34, 0.12), cs, Vector3(90, 0, 0))
	# 聚焦晶体（斜置的小方柱）
	for a in [0.0, 120.0, 240.0]:
		var r := deg_to_rad(a)
		var cx := cos(r) * 0.26
		var cy := sin(r) * 0.26 + 0.34
		var cr := _add_box(pod, Vector3(0.06, 0.16, 0.06), Vector3(cx, cy, 0), cs)
		cr.rotation_degrees = Vector3(0, a, 28)
	# 能量导管
	for sx in [-0.22, 0.22]:
		_add_box(pod, Vector3(0.05, 0.30, 0.05), Vector3(sx, 0.14, 0), mats["plate"])

## 传感器阵列：抛物面 + 两根天线 + 相控阵面板（带发光阵元）
func _build_sensor_array(pod: Node3D, mats: Dictionary) -> void:
	var dish := _add_cyl(pod, 0.26, 0.08, 0.14, Vector3(0, 0.36, 0), mats["detail"], 14)
	dish.rotation_degrees = Vector3(0, 0, 0)
	_add_cyl(pod, 0.04, 0.04, 0.22, Vector3(0, 0.22, 0), mats["plate"], 8)
	# 天线
	for sx in [-0.20, 0.20]:
		_add_box(pod, Vector3(0.015, 0.34, 0.015), Vector3(sx, 0.50, -0.10), mats["detail"])
		_add_box(pod, Vector3(0.10, 0.012, 0.012), Vector3(sx, 0.66, -0.10), mats["detail"])
	# 相控阵面板：一排微小发光阵元
	_add_box(pod, Vector3(0.34, 0.10, 0.04), Vector3(0, 0.20, 0.30), mats["plate"])
	for i in 4:
		_add_box(pod, Vector3(0.05, 0.05, 0.02), Vector3(-0.12 + float(i) * 0.08, 0.20, 0.33), mats["glow"])

## 人员舱：上下铺 + 餐桌 + 储物柜 + 舷窗
func _build_quarters(pod: Node3D, mats: Dictionary) -> void:
	# 甲板凹槽
	_add_box(pod, Vector3(0.52, 0.05, 0.58), Vector3(0, 0.22, 0), mats["dark"])
	# 两排上下铺
	for row in 2:
		var z := -0.16 + float(row) * 0.32
		for col in 2:
			var x := -0.13 + float(col) * 0.26
			# 上层铺
			_add_box(pod, Vector3(0.18, 0.03, 0.20), Vector3(x, 0.34, z), mats["plate"])
			_add_box(pod, Vector3(0.16, 0.035, 0.17), Vector3(x, 0.36, z), _emissive(Color(0.45, 0.55, 0.75), 0.25))
			# 下层铺
			_add_box(pod, Vector3(0.18, 0.03, 0.20), Vector3(x, 0.26, z), mats["plate"])
			_add_box(pod, Vector3(0.16, 0.035, 0.17), Vector3(x, 0.28, z), _emissive(Color(0.45, 0.55, 0.75), 0.25))
			# 铺位立柱
			_add_box(pod, Vector3(0.02, 0.20, 0.02), Vector3(x - 0.09, 0.30, z + 0.10), mats["detail"])
	# 餐桌 + 长凳
	_add_box(pod, Vector3(0.26, 0.03, 0.14), Vector3(0, 0.30, 0.06), mats["detail"])
	_add_box(pod, Vector3(0.24, 0.02, 0.05), Vector3(0, 0.26, 0.16), mats["plate"])
	_add_box(pod, Vector3(0.24, 0.02, 0.05), Vector3(0, 0.26, -0.04), mats["plate"])
	# 储物柜
	_add_box(pod, Vector3(0.10, 0.20, 0.28), Vector3(-0.23, 0.30, 0), mats["plate"])
	# 舷窗
	for i in 3:
		_add_box(pod, Vector3(0.05, 0.05, 0.02), Vector3(-0.16 + float(i) * 0.16, 0.30, 0.33), mats["glow"])

## 弹药库：装甲舱门 + 警示条 + 吊装轨道 + 弹药箱
func _build_magazine(pod: Node3D, mats: Dictionary) -> void:
	# 装甲舱门
	_add_box(pod, Vector3(0.50, 0.20, 0.54), Vector3(0, 0.30, 0), mats["plate"])
	_add_box(pod, Vector3(0.42, 0.04, 0.46), Vector3(0, 0.44, 0), mats["warn"])
	# 吊装轨道与吊钩
	_add_box(pod, Vector3(0.04, 0.04, 0.60), Vector3(0.22, 0.50, 0), mats["detail"])
	_add_box(pod, Vector3(0.02, 0.10, 0.02), Vector3(0.16, 0.44, 0.10), mats["detail"])
	# 弹药箱
	for i in 3:
		_add_box(pod, Vector3(0.12, 0.10, 0.12), Vector3(-0.16 + float(i) * 0.14, 0.26, -0.18), mats["warn"])
	# 危险标识灯
	_add_box(pod, Vector3(0.05, 0.05, 0.05), Vector3(0, 0.50, 0.24), _emissive(Color(1.0, 0.35, 0.2), 1.0))

# ---------------------------------------------------------------- 炮塔

## 炮塔：三种武器三种形态，可绕安装面旋转跟踪目标。
## 结构：pod（+Z = 外法线）→ yaw（绕 +Z 旋转）→ inner（-90°X，让炮管沿 +Y）
func _build_turret(pod: Node3D, kind: int, mats: Dictionary) -> Node3D:
	_add_cyl(pod, 0.28, 0.32, 0.10, Vector3(0, 0.28, 0), mats["detail"], 12)

	var yaw := Node3D.new()
	yaw.position = Vector3(0, 0.36, 0)
	pod.add_child(yaw)

	var inner := Node3D.new()
	inner.rotation_degrees = Vector3(-90, 0, 0)
	yaw.add_child(inner)

	match kind:
		Model.CompType.WEAPON_LONG:
			_build_cannon_turret(inner, mats)
		Model.CompType.WEAPON_CLOSE:
			_build_gatling_turret(inner, mats)
		_:
			_build_laser_turret(inner, mats)

	return yaw

## 激光炮塔：细长炮管 + 玻璃透镜 + 冷却鳍 + 供能导管
func _build_laser_turret(inner: Node3D, mats: Dictionary) -> void:
	# 炮塔壳体
	_add_box(inner, Vector3(0.44, 0.20, 0.42), Vector3(0, 0.04, 0), mats["plate"])
	# 炮管
	var barrel := _add_cyl(inner, 0.040, 0.058, 0.92, Vector3(0, 0.04, 0.52), mats["detail"], 10)
	barrel.rotation_degrees = Vector3(-90, 0, 0)
	# 透镜座
	var housing := _add_cyl(inner, 0.11, 0.09, 0.16, Vector3(0, 0.04, 1.02), mats["detail"], 12)
	housing.rotation_degrees = Vector3(-90, 0, 0)
	# 玻璃透镜（核心细节）
	var lens := _add_cyl(inner, 0.085, 0.085, 0.03, Vector3(0, 0.04, 1.11), mats["glass"], 14)
	lens.rotation_degrees = Vector3(-90, 0, 0)
	# 透镜环
	_add_torus(inner, 0.085, 0.115, Vector3(0, 0.04, 1.09), mats["accent"], Vector3(90, 0, 0))
	# 冷却鳍片
	for i in 4:
		_add_box(inner, Vector3(0.20, 0.02, 0.08), Vector3(0, 0.14 + float(i) * 0.03, 0.22 + float(i) * 0.12), mats["detail"])
	# 供能导管
	_add_box(inner, Vector3(0.05, 0.05, 0.34), Vector3(0.20, 0.02, 0.02), mats["plate"])
	# 观瞄镜
	_add_box(inner, Vector3(0.05, 0.06, 0.10), Vector3(-0.16, 0.16, 0.34), mats["dark"])

## 火炮塔：双联炮管 + 自动装填弹鼓 + 输弹槽 + 后座
func _build_cannon_turret(inner: Node3D, mats: Dictionary) -> void:
	# 炮塔壳体
	_add_box(inner, Vector3(0.50, 0.22, 0.46), Vector3(0, 0.04, 0), mats["plate"])
	# 双联炮管
	for sx in [-0.12, 0.12]:
		_add_box(inner, Vector3(0.085, 0.085, 1.20), Vector3(sx, 0.04, 0.58), mats["detail"])
		_add_box(inner, Vector3(0.13, 0.13, 0.16), Vector3(sx, 0.04, 1.18), mats["detail"])
		_add_box(inner, Vector3(0.16, 0.16, 0.10), Vector3(sx, 0.04, 1.28), mats["detail"])
		# 后座筒
		_add_cyl(inner, 0.045, 0.045, 0.26, Vector3(sx, 0.16, 0.10), mats["detail"], 8).rotation_degrees = Vector3(-90, 0, 0)
	# 炮闩
	_add_box(inner, Vector3(0.40, 0.24, 0.22), Vector3(0, 0.04, -0.16), mats["dark"])
	# 自动装填弹鼓（竖置，露出弹头）
	var drum := _add_cyl(inner, 0.16, 0.16, 0.16, Vector3(-0.30, 0.04, -0.20), mats["plate"], 12)
	drum.rotation_degrees = Vector3(0, 0, 90)
	for i in 6:
		var a := TAU * float(i) / 6.0
		var py := cos(a) * 0.11
		var pz := sin(a) * 0.11
		_add_cyl(inner, 0.018, 0.018, 0.05, Vector3(-0.39, 0.04 + py, -0.20 + pz), mats["warn"], 6).rotation_degrees = Vector3(0, 0, 90)
	# 输弹槽：从弹鼓通向炮闩
	_add_box(inner, Vector3(0.06, 0.10, 0.22), Vector3(-0.18, 0.04, -0.16), mats["detail"])
	# 俯仰耳轴
	_add_cyl(inner, 0.05, 0.05, 0.46, Vector3(0, 0.06, -0.02), mats["detail"], 8).rotation_degrees = Vector3(0, 0, 90)

## 近防炮塔：六管加特林 + 弹箱 + 弹链 + 跟踪雷达
func _build_gatling_turret(inner: Node3D, mats: Dictionary) -> void:
	_add_box(inner, Vector3(0.36, 0.18, 0.34), Vector3(0, 0.04, 0), mats["plate"])
	# 六管
	for i in 6:
		var a := TAU * float(i) / 6.0
		var px := cos(a) * 0.050
		var py := sin(a) * 0.050
		_add_box(inner, Vector3(0.024, 0.024, 0.62), Vector3(px, 0.04 + py, 0.36), mats["detail"])
	# 旋转鼓
	_add_cyl(inner, 0.105, 0.105, 0.14, Vector3(0, 0.04, 0.12), mats["dark"], 10).rotation_degrees = Vector3(-90, 0, 0)
	# 弹箱与弹链
	_add_box(inner, Vector3(0.16, 0.14, 0.20), Vector3(-0.24, 0.02, -0.10), mats["warn"])
	for i in 5:
		_add_box(inner, Vector3(0.02, 0.02, 0.03), Vector3(-0.15 + float(i) * 0.025, 0.06, -0.06), mats["detail"])
	# 跟踪雷达
	_add_box(inner, Vector3(0.018, 0.14, 0.018), Vector3(0.14, 0.16, -0.12), mats["detail"])
	_add_box(inner, Vector3(0.10, 0.025, 0.07), Vector3(0.14, 0.23, -0.12), mats["detail"])

## 炮塔跟踪最近的目标。纯表现层，不影响命中判定。
func _update_turrets(delta: float) -> void:
	if turret_nodes.is_empty():
		return
	for ship in sim.ships:
		if not ship.alive():
			continue
		var enemies := sim.enemies_of(ship)
		if enemies.is_empty():
			continue
		var tgt = enemies[0]
		var best := INF
		for e in enemies:
			var dd: float = (e.pos - ship.pos).length()
			if dd < best:
				best = dd
				tgt = e
		for comp in ship.compartments:
			if not Model.is_weapon(comp.kind) or not comp.alive():
				continue
			var key := "%d:%d" % [ship.uid, comp.index]
			var yaw: Node3D = turret_nodes.get(key)
			var pod: Node3D = turret_pods.get(key)
			if yaw == null or pod == null:
				continue
			var from: Vector3 = ship.local_to_world(comp.local_pos)
			var dir_world: Vector3 = (tgt.pos - from).normalized()
			var d: Vector3 = pod.global_transform.basis.inverse() * dir_world
			var ang: float = atan2(-d.x, d.y)
			yaw.rotation.z = lerp_angle(yaw.rotation.z, ang, clampf(delta * 7.0, 0.0, 1.0))

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

## 船员用 MultiMesh 绘制：每舰 100+ 人，全部塞进一个绘制批次。
## 逐个小人的逻辑只做"往哪跑、跑到了没"，不做精细动作。
func _build_crew_multimesh() -> void:
	var total: int = sim.ships.size() * CREW_PER_SHIP
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var cap := CapsuleMesh.new()
	cap.radius = 0.030
	cap.height = 0.13
	cap.radial_segments = 6
	cap.rings = 2
	mm.mesh = cap
	mm.instance_count = total
	crew_mm = mm

	crew_mm_node = MultiMeshInstance3D.new()
	crew_mm_node.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.55, 0.75)
	mat.metallic = 0.0
	mat.roughness = 0.8
	crew_mm_node.material_override = mat
	crew_mm_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(crew_mm_node)

	var idx := 0
	for ship in sim.ships:
		var col := Color(0.88, 0.94, 1.0) if ship.team == "player" else Color(1.0, 0.88, 0.84)
		for i in CREW_PER_SHIP:
			var p := _idle_spot(ship)
			crew_data.append({
				"ship": ship, "idx": idx, "pos": p, "target": p,
				"timer": randf_range(0.0, 1.2), "phase": randf() * TAU,
				"vel": Vector3.ZERO, "life": 0.0, "flying": false,
			})
			mm.set_instance_color(idx, col)
			mm.set_instance_transform(idx, Transform3D(Basis(), Vector3(0, -900, 0)))
			idx += 1

## 甲板上一个随机待命点（按舰体轮廓收窄，避免站到船外）
func _idle_spot(ship) -> Vector3:
	var z := randf_range(-4.8, 4.4)
	var half := 1.42
	if z > 3.2:
		half = lerpf(1.42, 0.22, clampf((z - 3.2) / 1.6, 0.0, 1.0))
	elif z < -3.8:
		half = lerpf(1.42, 0.85, clampf((-z - 3.8) / 1.0, 0.0, 1.0))
	var x := randf_range(-half, half)
	return Vector3(x, 0.56, z)

## 某个舱室旁边的一个落脚点（在装甲面上）
func _station_spot(comp) -> Vector3:
	var base: Vector3 = comp.local_pos + comp.dir * 0.42
	return base + Vector3(randf_range(-0.2, 0.2), randf_range(0.0, 0.12), randf_range(-0.2, 0.2))

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
	_update_turrets(delta)
	_update_crew_mm(delta)
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
			var key := "%d:%d" % [ship.uid, comp.index]
			var mats_list: Array = comp_mats.get(key, [])
			var cols: Array = comp_base_colors.get(key, [])
			var emis: Array = comp_base_emission.get(key, [])
			for j in mats_list.size():
				var mat: StandardMaterial3D = mats_list[j]
				if mat == null:
					continue
				var base_col: Color = cols[j] if j < cols.size() else Color(0.3, 0.3, 0.3)
				var base_emi: Color = emis[j] if j < emis.size() else Color(0, 0, 0)
				if comp.state == Model.CompState.OFFLINE:
					mat.albedo_color = Color(0.07, 0.07, 0.09)
					mat.emission = Color(0, 0, 0)
				elif comp.state == Model.CompState.DAMAGED:
					# 轻微烧灼：保留原色，只往焦褐色偏一点
					mat.albedo_color = base_col.lerp(Color(0.45, 0.26, 0.12), 0.45)
					mat.emission = base_emi * 0.55
				else:
					mat.albedo_color = base_col
					mat.emission = base_emi

			# 舱室被打爆的那一瞬间：附近船员四散 / 被抛出
			var prev: int = prev_comp_state.get(key, Model.CompState.ONLINE)
			if comp.state == Model.CompState.OFFLINE and prev != Model.CompState.OFFLINE:
				_panic_near(ship, comp)
				# 被打爆的炮塔：炮管垂下来，像卡死了
				var yaw: Node3D = turret_nodes.get(key)
				if yaw != null:
					yaw.rotation.z = 0.9
					yaw.scale = Vector3(0.86, 0.86, 0.86)
			prev_comp_state[key] = comp.state
		_update_damage_emitter(ship, node)

# ---------------------------------------------------------------- 船员

## 船员用 MultiMesh 绘制：每舰 100+ 人，全部塞进一个绘制批次。
## 逐个小人的逻辑只做"往哪跑、跑到了没"，不做精细动作。
func _update_crew_mm(delta: float) -> void:
	if crew_mm == null:
		return
	var dt: float = delta * maxf(speed_scale, 0.15)
	var identity := Basis()

	for c in crew_data:
		var ship = c["ship"]
		var i: int = c["idx"]
		if not ship.alive():
			crew_mm.set_instance_transform(i, Transform3D(identity, Vector3(0, -900, 0)))
			continue

		# 被抛出船外的人：匀速飘走，生命结束后藏起来
		if c["flying"]:
			var fp: Vector3 = c["pos"] + c["vel"] * dt
			c["pos"] = fp
			c["life"] -= dt
			if c["life"] <= 0.0:
				crew_mm.set_instance_transform(i, Transform3D(identity, Vector3(0, -900, 0)))
				continue
			crew_mm.set_instance_transform(i, Transform3D(identity, ship.local_to_world(fp)))
			continue

		var pos: Vector3 = c["pos"]
		var target: Vector3 = c["target"]
		var d: Vector3 = target - pos
		if d.length() > 0.06:
			pos += d.normalized() * minf(CREW_SPEED * dt, d.length())
			c["phase"] += dt * 11.0
			pos.y = target.y + sin(c["phase"]) * 0.012
		else:
			c["timer"] -= dt
			if c["timer"] <= 0.0:
				c["target"] = _random_crew_target(ship)
				c["timer"] = randf_range(1.2, 3.5)
		c["pos"] = pos
		# 朝向：面朝移动方向；站着不动时保持上一次朝向
		if d.length() > 0.06:
			c["yaw"] = atan2(d.x, d.z)
		var b: Basis = ship.basis() * Basis(Vector3.UP, float(c.get("yaw", 0.0)))
		crew_mm.set_instance_transform(i, Transform3D(b, ship.local_to_world(pos)))

## 随机目标：多数人往武器舱跑，少数在甲板待命
func _random_crew_target(ship) -> Vector3:
	if randf() < 0.7:
		var guns: Array = []
		for comp in ship.compartments:
			if comp.alive() and Model.is_weapon(comp.kind):
				guns.append(comp)
		if guns.size() > 0:
			return _station_spot(guns[randi() % guns.size()])
	return _idle_spot(ship)

## 某个舱室被击穿：附近的船员四散，一部分当场被抛出船外
func _panic_near(ship, comp) -> void:
	var blast: Vector3 = comp.local_pos
	for c in crew_data:
		if c["ship"] != ship or c["flying"]:
			continue
		var p: Vector3 = c["pos"]
		if (p - blast).length() > 3.4:
			continue
		var away: Vector3 = p - blast
		if away.length() < 0.01:
			away = Vector3(randf_range(-1, 1), 0.4, randf_range(-1, 1))
		if randf() < 0.35:
			# 被抛出：给一个向外的初速度
			c["flying"] = true
			c["vel"] = away.normalized() * randf_range(0.5, 1.2) + Vector3(0, randf_range(0.2, 0.8), 0)
			c["life"] = randf_range(2.5, 4.0)
		else:
			# 四散逃跑
			c["target"] = p + away.normalized() * randf_range(1.0, 2.2)
			c["timer"] = randf_range(0.8, 1.6)

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
