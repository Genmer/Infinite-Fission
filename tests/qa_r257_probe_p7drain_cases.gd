extends RefCounted
# R257 QA-257-3 探针 cases：溢出批消化三因子量化。
# 因子A：_merged_overflow_budget_ms() 每帧抽卡预算（桌面 35ms / mobile 8ms——若
#         headless 落 8ms 档则帧数×4 膨胀=挂起主因）
# 因子B：每 200 物理帧 merged 递减速率（若每帧仅 1-2 张=递减回归/让渡阀频触发）
# 因子C：单帧墙钟均值（若 ≈预算+全帧成本=正常；若超=别处回归）

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const MAX_FRAMES := 2400          # 200 帧打点 ×12 采样（最坏 84s 帽内）


func run(p_tree: SceneTree) -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	var gl = scene.instantiate()
	gl.name = "P7DrainProbeLoop"
	p_tree.get_root().add_child(gl)
	await p_tree.process_frame
	await p_tree.process_frame
	# 常规局（r188 §P 同款前置）
	gl.call(&"start_run")
	await p_tree.process_frame
	print("[pre] state=%d" % int(gl.get("state")))
	# P7 连升：巨额经验（r188 :1151-1155 同款）
	gl.set("pending_level_ups", 0)
	gl.set("merged_overflow_level_ups", 0)
	gl.player.gain_xp(1e12)
	gl.call(&"_consume_deferred_level_open")
	var merged0: int = int(gl.get("merged_overflow_level_ups"))
	var pending0: int = int(gl.get("pending_level_ups"))
	print("[P7] 连升后 pending=%d merged=%d" % [pending0, merged0])
	# 收口首窗（真实批恰 1 窗）
	var ui = gl.get("card_select_ui")
	if bool(ui.get("is_open")):
		ui.call(&"choose", 0)
	# 消化态就位（r188 :1195-1198 同款）
	gl.player.set("max_hp", 1000000.0)
	gl.player.set("hp", 1000000.0)
	gl.player.set("invuln_left", 9999.0)
	Meta.set_setting("auto_select_on", true)
	# 因子A：预算档直读
	var budget: float = float(gl.call(&"_merged_overflow_budget_ms"))
	print("[A] 每帧抽卡预算 = %.1f ms（桌面 35 / mobile 8）" % budget)
	# 因子D：抽卡链微基准（pick 单张 / apply 单张 / tick 单帧消化）——定位成本在哪一环
	var cg = gl.get("card_generator")
	var t_p := Time.get_ticks_usec()
	var card_d: Dictionary = {}
	for i in 20:
		card_d = gl.call(&"_pick_merged_card")
	var pick_us: int = (Time.get_ticks_usec() - t_p) / 20
	var t_a := Time.get_ticks_usec()
	for i in 20:
		cg.call(&"apply_choice", gl.call(&"_pick_merged_card"), gl.player)
	var apply_us: int = (Time.get_ticks_usec() - t_a) / 20
	var m_before: int = int(gl.get("merged_overflow_level_ups"))
	var t_t := Time.get_ticks_usec()
	gl.call(&"_tick_merged_overflow")
	var tick_us: int = Time.get_ticks_usec() - t_t
	print("[D] pick=%.2fms apply=%.2fms（pick+apply 单张）| tick 单帧消化=%.1fms 消化张数=%d"
		% [float(pick_us) / 1000.0, float(apply_us) / 1000.0, float(tick_us) / 1000.0,
			m_before - int(gl.get("merged_overflow_level_ups"))])
	# 打点循环（二分实验：只直驱 _tick_merged_overflow——绕开全物理帧。若递减速率
	# 恢复 ~16 张/帧（35ms÷2.2ms）=慢在全帧别处；若仍 2-3 张/帧=慢在 tick 内部）
	# 前置：先收口真实批窗链（draining 置位在收口链 :2414——直驱跳过物理帧则永不动）
	for i in 50:
		if int(gl.get("state")) != 4 or not bool(ui.get("is_open")):
			break
		ui.call(&"choose", 0)
	print("[pre2] 收口后 state=%d pending=%d draining=%s"
		% [int(gl.get("state")), int(gl.get("pending_level_ups")),
			str(gl.get("_merged_overflow_draining"))])
	var t_all := Time.get_ticks_usec()
	var last_merged: int = merged0
	var frames := 0
	while frames < MAX_FRAMES:
		var t_frame := Time.get_ticks_usec()
		gl.call(&"_tick_merged_overflow")
		var frame_us: int = Time.get_ticks_usec() - t_frame
		frames += 1
		if frames % 200 == 0:
			var m: int = int(gl.get("merged_overflow_level_ups"))
			var el_s := float(Time.get_ticks_usec() - t_all) / 1e6
			var sp = gl.get("spawner")
			var wd = gl.get("wave_director")
			print("[B/C] f%-5d merged=%-6d Δ=%-5d 本帧=%.2fms 累计=%.1fs 敌=%d wave=%d state=%d"
				% [frames, m, last_merged - m, float(frame_us) / 1000.0, el_s,
					int(sp.call(&"active_count")), int(wd.get("current_wave")),
					int(gl.get("state"))])
			var seg: Dictionary = gl.get("stage_probe_us")
			var pairs: Array = []
			for k in seg.keys():
				pairs.append([float(seg[k]) / 1000.0, String(k)])
			pairs.sort_custom(func(a, b) -> bool: return a[0] > b[0])
			var seg_line := ""
			for i in range(mini(6, pairs.size())):
				seg_line += " %s=%.1fms" % [pairs[i][1], pairs[i][0]]
			print("       本帧段TOP6:%s" % seg_line)
			last_merged = m
			if m <= 0:
				break
	var m_end: int = int(gl.get("merged_overflow_level_ups"))
	var total_s := float(Time.get_ticks_usec() - t_all) / 1e6
	var done_s := "清零✓" if m_end <= 0 else "未清零（外推剩余 %.0fs）" % (
		total_s * float(m_end) / maxf(float(merged0 - m_end), 1.0))
	print("[end] %d 帧后 merged=%d 累计 %.1fs %s" % [frames, m_end, total_s, done_s])
	Meta.set_setting("auto_select_on", false)
	gl.free()
	print("══ p7drain probe done ══")
