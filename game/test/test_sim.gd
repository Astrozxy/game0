extends SceneTree
## 无头测试：不渲染，直接跑战斗，验证逻辑与数值。
## 运行：Godot --headless --path <project> --script res://test/test_sim.gd

func _init() -> void:
	var runs := 30
	var player_wins := 0
	var enemy_wins := 0
	var draws := 0
	var durations := []
	var player_lost_sum := 0.0
	var enemy_lost_sum := 0.0

	for seed in runs:
		var sim := BattleSim.make_battle(6, seed, Model.default_loadout())
		var steps := 0
		while not sim.over and steps < 6000:
			sim.step(0.05)
			steps += 1
		var s: Dictionary = sim.summary()
		durations.append(s["time"])
		player_lost_sum += s["player"]["lost"]
		enemy_lost_sum += s["enemy"]["lost"]
		match s["winner"]:
			"player": player_wins += 1
			"enemy": enemy_wins += 1
			_: draws += 1

	var avg_time := 0.0
	for d in durations:
		avg_time += d
	avg_time /= maxf(1.0, float(durations.size()))

	print("=== EMBERFALL headless test ===")
	print("runs: %d   per side: 6" % runs)
	print("win: player %.0f%%  enemy %.0f%%  draw %.0f%%" % [
		player_wins * 100.0 / runs, enemy_wins * 100.0 / runs, draws * 100.0 / runs])
	print("avg duration: %.1f s" % avg_time)
	print("avg losses: player %.1f  enemy %.1f" % [
		player_lost_sum / runs, enemy_lost_sum / runs])

	var sim2 := BattleSim.make_battle(6, 1, Model.default_loadout())
	var steps2 := 0
	while not sim2.over and steps2 < 6000:
		sim2.step(0.05)
		steps2 += 1
	print("")
	print("--- sample (seed 1) ---")
	var n: int = mini(20, sim2.events.size())
	for i in n:
		var e: Dictionary = sim2.events[i]
		print("[%6.1f] %s" % [e["t"], e["text"]])
	print("... total events: %d" % sim2.events.size())
	quit()
