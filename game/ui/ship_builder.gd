extends Control
## 配船界面：动力仓在中轴，10 个槽位绕轴分布。
## 玩家只决定"每个槽放什么舱室"——这是第一版固定的槽位方案。

signal launch(loadout: Array)

const RING_FRONT := 250.0   # h = +1
const RING_REAR := 165.0    # h = -1
const CENTER := Vector2(430, 440)
const BTN := 88.0

var loadout: Array = Model.default_loadout()
var slot_buttons: Array = []
var stats_label: Label

func _ready() -> void:
	size = get_viewport_rect().size
	_build_ui()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var title := Label.new()
	title.text = "EMBERFALL · 配船"
	title.position = Vector2(60, 40)
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(0.92, 0.94, 0.97))
	add_child(title)

	var hint := Label.new()
	hint.text = "点击舱室切换类型。外圈 = 前部（h=+1），内圈 = 后部（h=-1），中心为动力仓。"
	hint.position = Vector2(62, 88)
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.55, 0.60, 0.66))
	add_child(hint)

	var core := Label.new()
	core.text = "动力仓"
	core.position = CENTER + Vector2(-46, -12)
	core.add_theme_font_size_override("font_size", 18)
	core.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	add_child(core)

	for i in Model.SLOT_COUNT:
		var btn := Button.new()
		btn.size = Vector2(BTN, BTN)
		btn.custom_minimum_size = Vector2(BTN, BTN)
		var radius: float = RING_FRONT if i < 5 else RING_REAR
		var ang: float = deg_to_rad(Model.slot_theta(i))
		btn.position = CENTER + Vector2(cos(ang), sin(ang)) * radius - Vector2(BTN, BTN) / 2.0
		btn.add_theme_font_size_override("font_size", 13)
		btn.pressed.connect(_cycle_slot.bind(i))
		add_child(btn)
		slot_buttons.append(btn)

	var panel := PanelContainer.new()
	panel.position = Vector2(860, 150)
	panel.size = Vector2(640, 520)
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 17)
	stats_label.add_theme_color_override("font_color", Color(0.86, 0.89, 0.93))
	stats_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(stats_label)

	var launch_btn := Button.new()
	launch_btn.text = "出　击"
	launch_btn.position = Vector2(860, 710)
	launch_btn.size = Vector2(300, 76)
	launch_btn.add_theme_font_size_override("font_size", 26)
	launch_btn.add_theme_stylebox_override("normal", _flat(Color(0.72, 0.26, 0.12)))
	launch_btn.add_theme_stylebox_override("hover", _flat(Color(0.85, 0.34, 0.16)))
	launch_btn.add_theme_stylebox_override("pressed", _flat(Color(0.60, 0.20, 0.09)))
	launch_btn.pressed.connect(func(): launch.emit(loadout.duplicate()))
	add_child(launch_btn)

	var reset_btn := Button.new()
	reset_btn.text = "重置默认"
	reset_btn.position = Vector2(1180, 710)
	reset_btn.size = Vector2(180, 76)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.pressed.connect(func():
		loadout = Model.default_loadout()
		_refresh())
	add_child(reset_btn)

	_refresh()

func _cycle_slot(i: int) -> void:
	loadout[i] = (int(loadout[i]) + 1) % 6
	_refresh()

func _refresh() -> void:
	for i in slot_buttons.size():
		var kind: int = loadout[i]
		var btn: Button = slot_buttons[i]
		btn.text = "%s\nθ%d°" % [Model.comp_name(kind), int(Model.slot_theta(i))]
		if kind == Model.CompType.WEAPON:
			btn.text = "%s\nθ%d°" % ["武器", int(Model.slot_theta(i))]
		elif kind == Model.CompType.MAGAZINE:
			btn.text = "弹药库\nθ%d°" % int(Model.slot_theta(i))
		elif kind == Model.CompType.CREW:
			btn.text = "宿舍\nθ%d°" % int(Model.slot_theta(i))
		elif kind == Model.CompType.ENGINE:
			btn.text = "引擎\nθ%d°" % int(Model.slot_theta(i))
		elif kind == Model.CompType.SHIELD:
			btn.text = "护盾\nθ%d°" % int(Model.slot_theta(i))
		elif kind == Model.CompType.SENSOR:
			btn.text = "传感器\nθ%d°" % int(Model.slot_theta(i))
		var c: Color = Model.comp_color(kind)
		btn.add_theme_stylebox_override("normal", _flat(c.darkened(0.45)))
		btn.add_theme_stylebox_override("hover", _flat(c.darkened(0.30)))
		btn.add_theme_stylebox_override("pressed", _flat(c.darkened(0.20)))
		btn.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))

	var probe := Model.ShipModel.new(0, "probe", "player", Vector3.ZERO, loadout)
	var weapons := 0
	var magazines := 0
	var engines := 0
	var shields := 0
	var crew := 0
	var sensors := 0
	for k in loadout:
		match int(k):
			Model.CompType.WEAPON: weapons += 1
			Model.CompType.MAGAZINE: magazines += 1
			Model.CompType.ENGINE: engines += 1
			Model.CompType.SHIELD: shields += 1
			Model.CompType.CREW: crew += 1
			Model.CompType.SENSOR: sensors += 1

	var dps: float = weapons * BattleSim.LASER_BASE_DAMAGE / BattleSim.LASER_COOLDOWN
	var lines: Array = []
	lines.append("舰体配置")
	lines.append("────────────────────────")
	lines.append("武器舱   %d      弹药库   %d" % [weapons, magazines])
	lines.append("引  擎   %d      护  盾   %d" % [engines, shields])
	lines.append("宿  舍   %d      传感器   %d" % [crew, sensors])
	lines.append("")
	lines.append("推算性能")
	lines.append("────────────────────────")
	lines.append("理论火力   %.0f / 秒" % dps)
	lines.append("航速       %.2f" % probe.speed())
	lines.append("命中系数   %.0f%%" % (probe.accuracy() * 100.0))
	lines.append("减伤       %.0f%%" % (probe.damage_reduction() * 100.0))
	lines.append("损管速率   %.2f / 秒" % probe.repair_rate())
	lines.append("总结构     %.0f" % probe.total_max_hp())
	lines.append("")
	lines.append("提示：弹药库被击穿会殉爆，别贴着武器放。")
	lines.append("引擎和护盾决定你能不能活着靠近。")
	stats_label.text = "\n".join(lines)

func _flat(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s

func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.07, 0.08, 0.11)
	s.border_color = Color(0.18, 0.21, 0.26)
	s.set_border_width_all(1)
	s.corner_radius_top_left = 8
	s.corner_radius_top_right = 8
	s.corner_radius_bottom_left = 8
	s.corner_radius_bottom_right = 8
	s.content_margin_left = 26
	s.content_margin_right = 26
	s.content_margin_top = 22
	s.content_margin_bottom = 22
	return s

func _draw() -> void:
	var front := Color(0.20, 0.24, 0.30)
	var rear := Color(0.16, 0.19, 0.24)
	draw_arc(CENTER, RING_FRONT, 0, TAU, 96, front, 2.0, true)
	draw_arc(CENTER, RING_REAR, 0, TAU, 96, rear, 2.0, true)
	draw_circle(CENTER, 46.0, Color(0.14, 0.16, 0.20))
	draw_arc(CENTER, 46.0, 0, TAU, 64, Color(0.40, 0.44, 0.50), 2.0, true)
