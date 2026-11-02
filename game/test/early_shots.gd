extends SceneTree
## 1v1 前 20 秒：在还没打出伤害时，两边开火数是否相等。
## 相等 → 偏差发生在伤害之后；不等 → 偏差在位置/射界。

func _init() -> void:
	var runs := 20
	var early := {"p": 0, "e": 0}
	var dists := []

	for seed in runs:
		var sim := BattleSim.make_battle(1, seed, Model.default_loadout())
		var steps := 0
		while not sim.over and sim.t < 20.0 and steps < 6000:
			sim.step(0.05)
			steps += 1
		early["p"] += sim.stat_shots["player"]
		early["e"] += sim.stat_shots["enemy"]
		var ps = sim.ships[0]
		var es = sim.ships[1]
		dists.append(snappedf((ps.pos - es.pos).length(), 0.1))

	print("runs=%d" % runs)
	print("前20秒开火：player %d  enemy %d" % [early["p"], early["e"]])
	var sum := 0.0
	for d in dists:
		sum += d
	print("20秒时平均距离：%.1f" % (sum / maxf(1.0, float(dists.size()))))
	quit()
