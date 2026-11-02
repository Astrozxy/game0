extends SceneTree
## 验证战报归因：损失来源、头号战果、舰长名单。

func _init() -> void:
	var sim := BattleSim.make_battle(6, 42, Model.default_loadout())
	var steps := 0
	while not sim.over and steps < 6000:
		sim.step(0.05)
		steps += 1
	var s: Dictionary = sim.summary()
	print("winner=%s  t=%.1f" % [s["winner"], s["time"]])
	for team in ["player", "enemy"]:
		var d: Dictionary = s[team]
		print("")
		print("[%s] 存活 %d/%d  船员损失 %d" % [team, d["survived"], d["total"], d["crew_lost"]])
		print("  舰长: %s" % ", ".join(d["captains"]))
		print("  头号战果: %s (%d 杀)" % [d["top_killer"], d["top_kills"]])
		var dmgc: Dictionary = d["dmg_by_comp"]
		var total := 0.0
		for v in dmgc.values():
			total += float(v)
		var keys: Array = dmgc.keys()
		keys.sort_custom(func(a, b): return float(dmgc[a]) > float(dmgc[b]))
		var parts: Array = []
		for i in mini(4, keys.size()):
			parts.append("%s %.0f%%" % [keys[i], float(dmgc[keys[i]]) * 100.0 / maxf(1.0, total)])
		print("  损失来源: %s" % ", ".join(parts))
	quit()
