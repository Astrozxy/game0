extends SceneTree
## 逐舰诊断：一场 6v6，打印每艘船的开火数、造成伤害、承受伤害、最终状态。

func _init() -> void:
	var sim := BattleSim.make_battle(6, 7, Model.default_loadout())
	var steps := 0
	var snapshots := []
	while not sim.over and steps < 6000:
		sim.step(0.05)
		steps += 1
		if steps % 200 == 0 and snapshots.size() < 6:
			var row := []
			for s in sim.ships:
				row.append("%s hp%.0f%%" % [s.ship_name, s.hull_integrity() * 100.0])
			snapshots.append("t=%.0f  %s" % [sim.t, " | ".join(row)])

	print("winner=%s t=%.1f" % [sim.winner, sim.t])
	for row in snapshots:
		print(row)

	print("")
	print("%-6s %-6s %8s %10s %10s %8s" % ["ship", "team", "shots", "dealt", "taken", "hull%"])
	for s in sim.ships:
		print("%-6s %-6s %8d %10.0f %10.0f %8.0f" % [
			s.ship_name, s.team,
			sim.ship_shots.get(s.uid, 0),
			sim.ship_dmg_dealt.get(s.uid, 0.0),
			sim.ship_dmg_taken.get(s.uid, 0.0),
			s.hull_integrity() * 100.0])

	print("")
	print("按武器类型开火数:")
	for k in sim.shots_by_kind.keys():
		print("  %s: %d" % [k, sim.shots_by_kind[k]])
	quit()
