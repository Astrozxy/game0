extends Control
## 配船界面：动力仓在中轴，10 个槽位绕轴分布。
## 玩家决定每个槽放什么舱室，以及编写战斗手册（允许的交战边界）。
##
## 布局按实际窗口尺寸自适应，不写死 1600x900。

signal launch(loadout: Array, doctrine: Dictionary)

var loadout: Array = Model.default_loadout()
var slot_buttons: Array = []
var stats_label: Label
var band_buttons: Dictionary = {}

# 战斗手册：玩家定的"允许边界"。舰长在这条边界内自行决定怎么打。
var doctrine := {
	"fire_band": "mid",
	"focus_fire": true,
	"hold_range": true,
}

# 布局（在 _build_ui 里按窗口尺寸算）
var center_pos := Vector2.ZERO
var ring_front := 0.0
var ring_rear := 0.0
var slot_size := 0.0

func _ready() -> void:
	size = get_viewport_rect().size
	_build_ui()
	_refresh()

func _build_ui() -> void:
	var W: float = size.x
	var H: float = size.y
	slot_size = clampf(minf(W, H) * 0.085, 56.0, 96.0)
	center_pos = Vector2(W * 0.30, H * 0.50)
	ring_front = minf(W, H) * 0.30
	ring_rear = ring_front * 0.64

	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var title := Label.new()
	title.text = "EMBERFALL · 配船"
	title.position = Vector2(W * 0.035, H * 0.045)
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(0.92, 0.94, 0.97))
	add_child(title)

	var hint := Label.new()
	hint.text = "点击舱室切换类型。外圈 = 前部，内圈 = 后部，中心为动力仓。"
	hint.position = Vector2(W * 0.035, H * 0.105)
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.55, 0.60, 0.66))
	add_child(hint)

	var core := Label.new()
	core.text = "动力仓"
	core.position = center_pos + Vector2(-40, -12)
	core.add_theme_font_size_override("font_size", 17)
	core.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	add_child(core)

	for i in Model.SLOT_COUNT:
		var btn := Button.new()
		btn.size = Vector2(slot_size, slot_size)
		btn.custom_minimum_size = Vector2(slot_size, slot_size)
		var radius: float = ring_front if i < 5 else ring_rear
		var ang: float = deg_to_rad(Model.slot_theta(i))
		btn.position = center_pos + Vector2(cos(ang), sin(ang)) * radius - Vector2(slot_size, slot_size) * 0.5
		btn.add_theme_font_size_override("font_size", maxf(10.0, slot_size * 0.17))
		btn.pressed.connect(_cycle_slot.bind(i))
		add_child(btn)
		slot_buttons.append(btn)

	# ---- 右侧：性能面板 ----
	var panel_w: float = minf(W * 0.40, 620.0)
	var panel := PanelContainer.new()
	panel.position = Vector2(W - panel_w - W * 0.02, H * 0.10)
	panel.size = Vector2(panel_w, H * 0.46)
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 15)
	stats_label.add_theme_color_override("font_color", Color(0.86, 0.89, 0.93))
	stats_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(stats_label)

	# ---- 底部：战斗手册 ----
	var doc_title := Label.new()
	doc_title.text = "战斗手册（舰长会在边界内自行决定怎么打）"
	doc_title.position = Vector2(W - panel_w - W * 0.02, H * 0.60)
	doc_title.add_theme_font_size_override("font_size", 13)
	doc_title.add_theme_color_override("font_color", Color(0.60, 0.66, 0.74))
	add_child(doc_title)

	var band_defs := [
		["close", "允许近距"],
		["mid", "允许中距"],
		["far", "允许远距"],
	]
	var bx: float = W - panel_w - W * 0.02
	var bw: float = minf(132.0, panel_w / 3.0 - 8.0)
	for def in band_defs:
		var b := Button.new()
		b.text = def[1]
		b.position = Vector2(bx, H * 0.65)
		b.size = Vector2(bw, 42)
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(_set_band.bind(def[0]))
		add_child(b)
		band_buttons[def[0]] = b
		bx += bw + 8.0

	var focus_btn := Button.new()
	focus_btn.text = "集火残血"
	focus_btn.position = Vector2(W - panel_w - W * 0.02, H * 0.73)
	focus_btn.size = Vector2(bw, 38)
	focus_btn.add_theme_font_size_override("font_size", 14)
	focus_btn.toggle_mode = true
	focus_btn.button_pressed = true
	focus_btn.toggled.connect(func(on: bool): doctrine["focus_fire"] = on)
	add_child(focus_btn)

	var launch_btn := Button.new()
	launch_btn.text = "出　击"
	launch_btn.position = Vector2(W - panel_w * 0.62 - W * 0.02, H * 0.83)
	launch_btn.size = Vector2(panel_w * 0.60, clampf(H * 0.075, 44.0, 64.0))
	launch_btn.add_theme_font_size_override("font_size", 22)
	launch_btn.add_theme_stylebox_override("normal", _flat(Color(0.72, 0.26, 0.12)))
	launch_btn.add_theme_stylebox_override("hover", _flat(Color(0.85, 0.34, 0.16)))
	launch_btn.add_theme_stylebox_override("pressed", _flat(Color(0.60, 0.20, 0.09)))
	launch_btn.pressed.connect(func(): launch.emit(loadout.duplicate(), doctrine.duplicate()))
	add_child(launch_btn)

func _cycle_slot(i: int) -> void:
	loadout[i] = (int(loadout[i]) + 1) % 6
	_refresh()

func _set_band(band: String) -> void:
	doctrine["fire_band"] = band
	_refresh()

func _refresh() -> void:
	for i in slot_buttons.size():
		var kind: int = loadout[i]
		var btn: Button = slot_buttons[i]
		var short_name := "武器"
		match int(kind):
			Model.CompType.WEAPON: short_name = "武器"
			Model.CompType.MAGAZINE: short_name = "弹药库"
			Model.CompType.CREW: short_name = "宿舍"
			Model.CompType.ENGINE: short_name = "引擎"
			Model.CompType.SHIELD: short_name = "护盾"
			Model.CompType.SENSOR: short_name = "传感器"
		btn.text = "%s\nθ%d°" % [short_name, int(Model.slot_theta(i))]
		var c: Color = Model.comp_color(kind)
		btn.add_theme_stylebox_override("normal", _flat(c.darkened(0.45)))
		btn.add_theme_stylebox_override("hover", _flat(c.darkened(0.30)))
		btn.add_theme_stylebox_override("pressed", _flat(c.darkened(0.20)))
		btn.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))

	var probe := Model.ShipModel.new(0, "probe", "player", Vector3.ZERO, loadout)
	var counts := {0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
	for k in loadout:
		counts[int(k)] = counts.get(int(k), 0) + 1

	var dps: float = counts[Model.CompType.WEAPON] * BattleSim.LASER_BASE_DAMAGE / BattleSim.LASER_COOLDOWN
	var lines: Array = []
	lines.append("舰体配置")
	lines.append("────────────────────────")
	lines.append("武器舱 %d    弹药库 %d" % [counts[0], counts[1]])
	lines.append("引  擎 %d    护  盾 %d" % [counts[3], counts[4]])
	lines.append("宿  舍 %d    传感器 %d" % [counts[2], counts[5]])
	lines.append("")
	lines.append("推算性能")
	lines.append("────────────────────────")
	lines.append("理论火力   %.0f / 秒" % dps)
	lines.append("航速       %.2f" % probe.speed())
	lines.append("命中系数   %.0f%%" % (probe.accuracy() * 100.0))
	lines.append("减伤       %.0f%%" % (probe.damage_reduction() * 100.0))
	lines.append("损管速率   %.2f / 秒" % probe.repair_rate())
	lines.append("总结构     %.0f" % probe.total_max_hp())
	lines.append("船员编制   %d 人" % probe.crew_capacity())
	lines.append("")
	lines.append("提示：弹药库被击穿会殉爆。")
	lines.append("引擎和护盾决定你能不能活着靠近。")
	stats_label.text = "\n".join(lines)

	_refresh_doctrine()

func _refresh_doctrine() -> void:
	for key in band_buttons.keys():
		var b: Button = band_buttons[key]
		var on: bool = key == doctrine["fire_band"]
		var c := Color(0.72, 0.26, 0.12) if on else Color(0.16, 0.19, 0.24)
		b.add_theme_stylebox_override("normal", _flat(c))
		b.add_theme_stylebox_override("hover", _flat(c.lightened(0.12)))
		b.add_theme_stylebox_override("pressed", _flat(c.darkened(0.15)))
		b.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98) if on else Color(0.62, 0.67, 0.74))

func _flat(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 6
	s.content_margin_bottom = 6
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
	s.content_margin_left = 22
	s.content_margin_right = 22
	s.content_margin_top = 18
	s.content_margin_bottom = 18
	return s

func _draw() -> void:
	var front := Color(0.20, 0.24, 0.30)
	var rear := Color(0.16, 0.19, 0.24)
	draw_arc(center_pos, ring_front, 0, TAU, 96, front, 2.0, true)
	draw_arc(center_pos, ring_rear, 0, TAU, 96, rear, 2.0, true)
	draw_circle(center_pos, slot_size * 0.55, Color(0.14, 0.16, 0.20))
	draw_arc(center_pos, slot_size * 0.55, 0, TAU, 64, Color(0.40, 0.44, 0.50), 2.0, true)
