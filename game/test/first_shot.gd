extends SceneTree
## 1v1 先手实验：谁先命中，谁赢？先手本身公平吗？

func _init() -> void:
	var first_p := 0
	var first_e := 0
	var first_win := 0
	var first_lose := 0
	var runs := 40
	var p_wins := 0

	for seed in runs:
		var sim := BattleSim.make_battle(1, seed, Model.default_loadout())
		var steps := 0
		while not sim.over and steps < 6000:
			sim.step(0.05)
			steps += 1
		var s: Dictionary = sim.summary()
		if s["winner"] == "player":
			p_wins += 1

		# 第一条命中事件属于谁
		var first_team := ""
		for e in sim.events:
			if e["kind"] == "hit":
				first_team = e["team"]
				break
		if first_team == "player":
			first_p += 1
		elif first_team == "enemy":
			first_e += 1

		if first_team != "":
			if first_team == s["winner"]:
				first_win += 1
			else:
				first_lose += 1

	print("runs=%d" % runs)
	print("先命中：player %d / enemy %d" % [first_p, first_e])
	print("先命中者获胜：%d 次；先命中者失败：%d 次" % [first_win, first_lose])
	print("player 总胜场：%d" % p_wins)
	quit()
