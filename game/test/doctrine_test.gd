extends SceneTree
## 手册有效性实验：玩家换不同手册，敌方固定"中距 + 集火"。
## 如果各档胜率接近，说明手册这个机制没有实际作用，需要重做。

func _run(n_runs: int, player_doctrine: Dictionary) -> Dictionary:
	var pw := 0
	var ew := 0
	var dr := 0
	var dealt := 0.0
	var taken := 0.0
	for seed in n_runs:
		var sim := BattleSim.make_battle(6, seed * 31 + 7, Model.default_loadout(), player_doctrine)
		var steps := 0
		while not sim.over and steps < 6000:
			sim.step(0.05)
			steps += 1
		match sim.winner:
			"player": pw += 1
			"enemy": ew += 1
			_: dr += 1
		dealt += sim.stat_damage["player"]
		taken += sim.stat_damage["enemy"]
	return {"pw": pw, "ew": ew, "dr": dr, "dealt": dealt, "taken": taken}

func _init() -> void:
	var n := 24
	print("=== 手册有效性（玩家换手册，敌方固定中距+集火）===")
	for band in ["close", "mid", "far"]:
		var r: Dictionary = _run(n, {"fire_band": band, "enemy_band": "mid"})
		print("玩家=%-5s  胜 %2d  负 %2d  平 %2d   伤害差 %+8.0f" % [
			band, r["pw"], r["ew"], r["dr"], r["dealt"] - r["taken"]])
	print("")
	print("=== 集火开关（玩家）===")
	for f in [true, false]:
		var r2: Dictionary = _run(n, {"focus_fire": f, "enemy_focus": true})
		print("集火=%-5s  胜 %2d  负 %2d  平 %2d   伤害差 %+8.0f" % [
			str(f), r2["pw"], r2["ew"], r2["dr"], r2["dealt"] - r2["taken"]])
	quit()
