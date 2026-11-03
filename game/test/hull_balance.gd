extends SceneTree
## 三种舰级各自的平衡检查：同舰级对战、默认装配。
## 运行：Godot --headless --path <project> --script res://test/hull_balance.gd

const RUNS := 14

func _run_class(cls: int) -> Dictionary:
	var pw := 0
	var ew := 0
	var dr := 0
	var total_t := 0.0
	var lost_p := 0.0
	var lost_e := 0.0
	for i in RUNS:
		var seed: int = 7000 + i * 13 + cls * 101
		var sim := BattleSim.make_battle(6, seed, Model.default_loadout(cls), {}, cls, cls)
		var steps := 0
		while not sim.over and steps < 8000:
			sim.step(0.05)
			steps += 1
		var s: Dictionary = sim.summary()
		total_t += float(s["time"])
		lost_p += float(s["player"]["lost"])
		lost_e += float(s["enemy"]["lost"])
		match s["winner"]:
			"player": pw += 1
			"enemy": ew += 1
			_: dr += 1
	return {
		"pw": pw, "ew": ew, "dr": dr,
		"t": total_t / float(RUNS),
		"lp": lost_p / float(RUNS),
		"le": lost_e / float(RUNS),
	}

func _init() -> void:
	print("=== 舰级平衡 ===")
	for cls in Model.HULLS.size():
		var r := _run_class(cls)
		print("%s（%d 硬点）: 玩家 %.0f%% / 敌方 %.0f%% / 平 %0.f%%  平均 %.1f 秒  损失 %.1f vs %.1f" % [
			Model.hull_name(cls), Model.slot_count(cls),
			float(r["pw"]) * 100.0 / RUNS, float(r["ew"]) * 100.0 / RUNS,
			float(r["dr"]) * 100.0 / RUNS, float(r["t"]), float(r["lp"]), float(r["le"])])
	quit()
