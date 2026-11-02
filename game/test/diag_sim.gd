extends SceneTree
## 诊断：为什么两军不对称。统计开火/命中/伤害，以及首次交火时间。

func _init() -> void:
	var runs := 6
	var acc := {
		"shots": {"player": 0, "enemy": 0},
		"hits": {"player": 0, "enemy": 0},
		"damage": {"player": 0.0, "enemy": 0.0},
		"first_fire": {"player": 9999.0, "enemy": 9999.0},
	}

	for seed in runs:
		var sim := BattleSim.make_battle(6, seed, Model.default_loadout())
		var steps := 0
		while not sim.over and steps < 6000:
			sim.step(0.05)
			steps += 1
			if sim.t < 20.0:
				for e in sim.events:
					if e["kind"] == "hit":
						var tm: String = e["team"]
						acc["first_fire"][tm] = minf(acc["first_fire"][tm], e["t"])
		for team in ["player", "enemy"]:
			acc["shots"][team] += sim.stat_shots[team]
			acc["hits"][team] += sim.stat_hits[team]
			acc["damage"][team] += sim.stat_damage[team]
		var s: Dictionary = sim.summary()
		print("seed %d: winner=%s  t=%.1f  P死%d E死%d" % [
			seed, s["winner"], s["time"], s["player"]["lost"], s["enemy"]["lost"]])

	print("")
	print("=== 汇总（%d 场）===" % runs)
	for team in ["player", "enemy"]:
		var shots: int = acc["shots"][team]
		var hits: int = acc["hits"][team]
		var dmg: float = acc["damage"][team]
		var rate := 0.0 if shots == 0 else float(hits) * 100.0 / float(shots)
		print("%s: 开火 %d  命中 %d (%.0f%%)  总伤害 %.0f  平均每击 %.1f  首次命中 %.1fs" % [
			team, shots, hits, rate, dmg, dmg / maxf(1.0, float(hits)),
			acc["first_fire"][team]])
	quit()
