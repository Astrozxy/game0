extends SceneTree
## 判决性实验：把两队标签互换。
## 如果"玩家"仍然是 70% 胜率 → 偏差在代码里（跟标签走）。
## 如果胜率翻转 → 偏差在几何/位置（跟阵型走）。

func _init() -> void:
	for swap in [false, true]:
		var pw := 0
		var ew := 0
		var dr := 0
		var runs := 20
		for seed in runs:
			var sim := BattleSim.make_battle(6, seed, Model.default_loadout())
			if swap:
				for s in sim.ships:
					s.team = "enemy" if s.team == "player" else "player"
			var steps := 0
			while not sim.over and steps < 6000:
				sim.step(0.05)
				steps += 1
			var s: Dictionary = sim.summary()
			match s["winner"]:
				"player": pw += 1
				"enemy": ew += 1
				_: dr += 1
		print("swap=%s  ->  player %d  enemy %d  draw %d" % [str(swap), pw, ew, dr])
	quit()
