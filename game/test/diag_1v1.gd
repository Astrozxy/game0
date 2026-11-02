extends SceneTree
## 1v1 伤害对比：两边开火数、命中率、总伤害是否对称。

func _init() -> void:
	var runs := 30
	var agg := {
		"shots": {"p": 0, "e": 0},
		"hits": {"p": 0, "e": 0},
		"dmg": {"p": 0.0, "e": 0.0},
		"hull_end": {"p": 0.0, "e": 0.0},
	}
	var pw := 0
	for seed in runs:
		var sim := BattleSim.make_battle(1, seed, Model.default_loadout())
		var steps := 0
		while not sim.over and steps < 6000:
			sim.step(0.05)
			steps += 1
		if sim.winner == "player":
			pw += 1
		agg["shots"]["p"] += sim.stat_shots["player"]
		agg["shots"]["e"] += sim.stat_shots["enemy"]
		agg["hits"]["p"] += sim.stat_hits["player"]
		agg["hits"]["e"] += sim.stat_hits["enemy"]
		agg["dmg"]["p"] += sim.stat_damage["player"]
		agg["dmg"]["e"] += sim.stat_damage["enemy"]
		for s in sim.ships:
			if s.team == "player":
				agg["hull_end"]["p"] += s.hull_integrity()
			else:
				agg["hull_end"]["e"] += s.hull_integrity()

	print("runs=%d  player wins=%d" % [runs, pw])
	for team in [["p", "player"], ["e", "enemy"]]:
		var k: String = team[0]
		var label: String = team[1]
		var shots: int = agg["shots"][k]
		var hits: int = agg["hits"][k]
		var dmg: float = agg["dmg"][k]
		print("%-6s shots=%4d hits=%4d (%.1f%%) dmg=%7.0f  avg/hit=%.1f  end_hull=%.2f" % [
			label, shots, hits, 100.0 * hits / maxf(1.0, shots), dmg,
			dmg / maxf(1.0, hits), agg["hull_end"][k] / runs])
	quit()
