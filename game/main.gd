extends Node
## 流程：配船 → 战斗 → 战果 → 回配船。

var current: Node = null

func _ready() -> void:
	# 默认：直接开打，打完自动下一局（不需要任何点击）。
	# 想自己配船时用 --builder 启动。
	if OS.get_cmdline_args().has("--builder"):
		_show_builder()
	else:
		_on_launch(Model.default_loadout())

func _clear() -> void:
	if current != null:
		current.queue_free()
		current = null

func _show_builder() -> void:
	_clear()
	var b: Control = preload("res://ui/ship_builder.gd").new()
	b.launch.connect(_on_launch)
	add_child(b)
	current = b

func _on_launch(loadout: Array) -> void:
	_clear()
	var v: Node3D = preload("res://battle/battle_view.gd").new()
	v.loadout = loadout
	v.finished.connect(_on_finished)
	add_child(v)
	current = v

func _on_finished(_summary: Dictionary) -> void:
	# 自动连播：一场打完直接开下一场，不用手动点。
	_on_launch(Model.default_loadout())
