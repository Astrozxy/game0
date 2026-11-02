extends Node
## 流程：配船 → 战斗 → 战果 → 回配船。

var current: Node = null

func _ready() -> void:
	_show_builder()

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
	_show_builder()
