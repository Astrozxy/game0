extends SceneTree
## 只创建不战斗：统计 80 局里双方舰长性格的分布是否均衡。
## 如果玩家总是抽到更多"谨慎"，那就是种子哈希与 uid 相关造成的偏差。

func _init() -> void:
	var n := 80
	var count := {
		"player": {"aggr": 0, "steady": 0, "cautious": 0},
		"enemy": {"aggr": 0, "steady": 0, "cautious": 0},
	}
	for seed in n:
		var sim := BattleSim.make_battle(6, seed, Model.default_loadout())
		for s in sim.ships:
			var p: int = s.captain.personality
			var key := "aggr"
			if p == Model.CapType.STEADY:
				key = "steady"
			elif p == Model.CapType.CAUTIOUS:
				key = "cautious"
			count[s.team][key] += 1
	for team in ["player", "enemy"]:
		var c: Dictionary = count[team]
		print("%-6s 激进 %3d  稳健 %3d  谨慎 %3d" % [team, c["aggr"], c["steady"], c["cautious"]])
	quit()
