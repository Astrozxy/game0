extends SceneTree
## 定位：1v1 是否公平。若 1v1 公平而 6v6 不公平，则偏差来自多舰交互。

func _init() -> void:
	for n in [1, 2, 3, 6]:
		var pw := 0
		var ew := 0
		var dr := 0
		var runs := 30
		for seed in runs:
			var sim := BattleSim.make_battle(n, seed, Model.default_loadout())
			var steps := 0
			while not sim.over and steps < 6000:
				sim.step(0.05)
				steps += 1
			var s: Dictionary = sim.summary()
			match s["winner"]:
				"player": pw += 1
				"enemy": ew += 1
				_: dr += 1
		print("n=%d -> player %d  enemy %d  draw %d" % [n, pw, ew, dr])
	quit()
