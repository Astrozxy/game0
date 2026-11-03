extends SceneTree
## 探针：统计战斗过程中每帧有多少光束
func _init() -> void:
	var sim := BattleSim.make_battle(6, 4242, Model.default_loadout(0), {}, 0, 0)
	var t := 0.0
	var frames_with_beams := 0
	var total_beams := 0
	var steps := 0
	while not sim.over and steps < 3000:
		sim.step(0.05)
		t += 0.05
		steps += 1
		if sim.beams.size() > 0:
			frames_with_beams += 1
			total_beams += sim.beams.size()
		if steps % 200 == 0:
			print("t=%.1f  beams_now=%d  frames_with_beams=%d  total=%d" % [
				t, sim.beams.size(), frames_with_beams, total_beams])
	print("结束 t=%.1f  有光束的帧 %d/%d  总光束 %d" % [t, frames_with_beams, steps, total_beams])
	quit()
