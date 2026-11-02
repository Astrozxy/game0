extends SceneTree
## 对照实验：把敌方阵型完全镜像（z 与 y 取反），看是否变成 50/50。
## 如果镜像后公平，说明代码没有阵营偏袒，之前的偏差来自阵型本身不对称。

func _init() -> void:
	for mirrored in [false, true]:
		var pw := 0
		var ew := 0
		var dr := 0
		var runs := 20
		for seed in runs:
			var sim := BattleSim.make_battle(6, seed, Model.default_loadout())
			if mirrored:
				for s in sim.ships:
					if s.team == "enemy":
						s.pos = Vector3(s.pos.x, -s.pos.y, -s.pos.z)
			var steps := 0
			while not sim.over and steps < 6000:
				sim.step(0.05)
				steps += 1
			var s2: Dictionary = sim.summary()
			match s2["winner"]:
				"player": pw += 1
				"enemy": ew += 1
				_: dr += 1
		print("mirrored=%s -> player %d  enemy %d  draw %d" % [str(mirrored), pw, ew, dr])
	quit()
