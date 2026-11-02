extends SceneTree
## 长样本平衡测试（80 场），用来判断 37/57 是噪声还是真偏差。

func _init() -> void:
	var runs := 40
	var pw := 0
	var ew := 0
	var dr := 0
	var times := 0.0
	for seed in runs:
		var sim := BattleSim.make_battle(6, seed + 1000, Model.default_loadout())
		var steps := 0
		while not sim.over and steps < 6000:
			sim.step(0.05)
			steps += 1
		match sim.winner:
			"player": pw += 1
			"enemy": ew += 1
			_: dr += 1
		times += sim.t
	print("runs=%d  player=%d  enemy=%d  draw=%d" % [runs, pw, ew, dr])
	print("avg duration=%.1f" % (times / runs))
	print("player win rate=%.1f%%" % (pw * 100.0 / runs))
	quit()
